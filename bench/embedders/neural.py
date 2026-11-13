"""Learned image embeddings run with PyTorch (MPS on Apple silicon, else CPU).

Each model uses its own standard preprocessing and is compared by cosine similarity on
L2-normalized vectors. Timing: preprocessing plus forward pass on an already decoded image,
batch 1, after warm-up, median over the first `timing_images` images. Embeddings for the
whole dataset are computed in batches where the preprocessing gives a fixed size.
"""

from __future__ import annotations

import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable

import numpy as np

from .common import MODELS, Context, Method, Result, Stopwatch, l2_normalize, load_rgb, median_ms

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)
SSCD_URL = "https://dl.fbaipublicfiles.com/sscd-copy-detection/sscd_disc_mixup.torchscript.pt"


@dataclass
class Loaded:
    forward: Callable  # batch [b,3,h,w] on device -> [b,d]
    transform: Callable  # PIL RGB image -> [3,h,w] float tensor
    modules: list  # what an app would ship, for model_mb
    fixed_size: bool = True
    notes: str = ""


def pick_device(pref: str) -> str:
    import torch

    if pref in ("cpu", "mps"):
        return pref
    return "mps" if torch.backends.mps.is_available() else "cpu"


def fp32_mb(modules) -> float:
    n = 0
    for m in modules:
        n += sum(p.numel() for p in m.parameters()) + sum(b.numel() for b in m.buffers())
    return n * 4 / 1e6


def _run_on(ctx: Context, loader: Callable[[str], Loaded], device: str) -> Result:
    import torch

    torch.set_grad_enabled(False)
    m = loader(device)
    sync = torch.mps.synchronize if device == "mps" else None

    def embed(batch):
        return m.forward(batch.to(device)).float().cpu()

    with torch.inference_mode():
        # Timing, batch 1, on decoded images.
        sample = [load_rgb(p) for p in ctx.paths[: max(1, min(len(ctx.paths), ctx.timing_images))]]
        for _ in range(3):
            embed(m.transform(sample[0])[None])
        times = []
        for im in sample:
            with Stopwatch(sync) as sw:
                embed(m.transform(im)[None])
            times.append(sw.ms)

        def prep(p):
            return m.transform(load_rgb(p))

        out = []
        batch = ctx.batch if m.fixed_size else 1
        chunk = max(batch * 4, 32)
        with ThreadPoolExecutor(8) as ex:
            for i in range(0, len(ctx.paths), chunk):
                tensors = list(ex.map(prep, ctx.paths[i : i + chunk]))
                for j in range(0, len(tensors), batch):
                    out.append(embed(torch.stack(tensors[j : j + batch])))
    X = l2_normalize(torch.cat(out).numpy())
    return Result(X=X, ms_per_image=median_ms(times), device=device, model_mb=fp32_mb(m.modules), notes=m.notes)


def torch_method(loader: Callable[[str], Loaded]) -> Callable[[Context], Result]:
    def run(ctx: Context) -> Result:
        device = pick_device(ctx.device)
        try:
            return _run_on(ctx, loader, device)
        except (RuntimeError, NotImplementedError) as e:
            if device != "mps":
                raise
            res = _run_on(ctx, loader, "cpu")
            res.notes = (res.notes + f" MPS failed ({str(e)[:120]}), ran on CPU.").strip()
            return res

    return run


# ---- loaders ---------------------------------------------------------------------------


def _imagededup_cnn(device: str) -> Loaded:
    # imagededup.utils.models.MobilenetV3: torchvision MobileNetV3-small ImageNet weights,
    # cut at global average pooling (576-d); Resize((256,256)) + CenterCrop(224) + ImageNet norm.
    import torch
    import torchvision
    from torchvision import transforms as T

    net = torchvision.models.mobilenet_v3_small(weights="MobileNet_V3_Small_Weights.IMAGENET1K_V1").eval()
    body = torch.nn.Sequential(net.features, net.avgpool).eval().to(device)
    tf = T.Compose([T.Resize((256, 256)), T.CenterCrop(224), T.ToTensor(), T.Normalize(IMAGENET_MEAN, IMAGENET_STD)])
    return Loaded(lambda x: body(x).flatten(1), tf, [body],
                  notes="reimplemented from imagededup 0.3 CNN (no imagededup install); imagededup's default "
                        "duplicate threshold is cosine similarity 0.9")


def _open_clip(name: str, pretrained: str, reparameterize: bool = False, **kw) -> Callable[[str], Loaded]:
    def load(device: str) -> Loaded:
        import open_clip

        model, _, preprocess = open_clip.create_model_and_transforms(
            name, pretrained=pretrained, cache_dir=str(MODELS / "open_clip"), **kw
        )
        visual = model.visual.eval()
        if reparameterize:
            from timm.utils.model import reparameterize_model

            visual = reparameterize_model(visual)  # MobileOne/FastViT branches folded; same outputs, faster
        visual = visual.to(device)
        return Loaded(visual, preprocess, [visual],
                      notes=f"open_clip {open_clip.__version__} {name} '{pretrained}', image tower only, val preprocess")

    return load


def _siglip2(device: str) -> Loaded:
    from transformers import AutoImageProcessor, AutoModel

    rid = "google/siglip2-base-patch16-224"
    model = AutoModel.from_pretrained(rid).eval()
    vision = model.vision_model.eval().to(device)  # get_image_features == vision_model(...).pooler_output
    proc = AutoImageProcessor.from_pretrained(rid)
    return Loaded(lambda x: vision(pixel_values=x).pooler_output,
                  lambda im: proc(images=im, return_tensors="pt")["pixel_values"][0], [vision],
                  notes=f"{rid} via transformers AutoModel, vision tower pooled output (MAP head), "
                        "processor: resize 224x224, mean/std 0.5")


def fixed_input(size: int, mode: str, mean=IMAGENET_MEAN, std=IMAGENET_STD) -> Callable:
    """Whole-image fixed-size input, the kind a Core ML / Neural Engine model takes.

    squash: resize to size x size, ignoring the aspect ratio (nothing is cut off).
    pad:    letterbox: long side to `size`, centered on a square of the mean color (0 after
            normalization), so the aspect ratio is kept and nothing is cut off.
    """
    from PIL import Image
    from torchvision import transforms as T

    to_tensor = T.Compose([T.ToTensor(), T.Normalize(mean, std)])
    fill = tuple(round(255 * m) for m in mean)

    def tf(im):
        if mode == "squash":
            return to_tensor(im.resize((size, size), Image.BICUBIC))
        assert mode == "pad", mode
        w, h = im.size
        s = size / max(w, h)
        nw, nh = max(1, round(w * s)), max(1, round(h * s))
        canvas = Image.new("RGB", (size, size), fill)
        canvas.paste(im.resize((nw, nh), Image.BICUBIC), ((size - nw) // 2, (size - nh) // 2))
        return to_tensor(canvas)

    return tf


_FIXED_NOTE = {
    "squash": "resized to {s}x{s} ignoring aspect ratio (no crop)",
    "pad": "letterboxed: long side {s}, centered on a {s}x{s} mean-color square (no crop, aspect kept)",
}


def _dinov2(rid: str, pool: str, fixed: tuple[int, str] | None = None) -> Callable[[str], Loaded]:
    def load(device: str) -> Loaded:
        from transformers import AutoImageProcessor, AutoModel

        model = AutoModel.from_pretrained(rid).eval().to(device)
        if pool == "cls":
            fwd = lambda x: model(pixel_values=x).last_hidden_state[:, 0]  # noqa: E731
        else:
            fwd = lambda x: model(pixel_values=x).last_hidden_state[:, 1:].mean(1)  # noqa: E731
        what = f"{rid} via transformers, {'CLS token' if pool == 'cls' else 'mean of patch tokens'} after final layer norm; "
        if fixed:
            size, mode = fixed
            return Loaded(fwd, fixed_input(size, mode), [model],
                          notes=what + "input " + _FIXED_NOTE[mode].format(s=size) + ", bicubic, ImageNet norm")
        proc = AutoImageProcessor.from_pretrained(rid)
        return Loaded(fwd, lambda im: proc(images=im, return_tensors="pt")["pixel_values"][0], [model],
                      notes=what + "processor: resize short side 256, center crop 224, ImageNet norm")

    return load


def _sscd_model(device: str):
    import torch

    path = MODELS / "sscd" / "sscd_disc_mixup.torchscript.pt"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".part")
        urllib.request.urlretrieve(SSCD_URL, tmp)
        tmp.replace(path)
    return torch.jit.load(str(path), map_location="cpu").eval().to(device)


def _sscd(device: str) -> Loaded:
    from torchvision import transforms as T

    model = _sscd_model(device)
    tf = T.Compose([T.Resize(288), T.ToTensor(), T.Normalize(IMAGENET_MEAN, IMAGENET_STD)])
    return Loaded(model, tf, [model], fixed_size=False,
                  notes="sscd_disc_mixup TorchScript (ResNet-50, 512-d, outputs L2-normalized); README 'small_288' "
                        "preprocessing: Resize(288) short side, no crop, ImageNet norm; batch 1 (sizes vary). "
                        "Variable input size: not the form a fixed-shape Core ML model takes")


def _sscd_fixed(size: int, mode: str) -> Callable[[str], Loaded]:
    def load(device: str) -> Loaded:
        model = _sscd_model(device)
        return Loaded(model, fixed_input(size, mode), [model],
                      notes=f"sscd_disc_mixup TorchScript (ResNet-50, 512-d); input {_FIXED_NOTE[mode].format(s=size)}, "
                            "bicubic, ImageNet norm (fixed shape, as a Core ML model would take it)")

    return load


def _timm(name: str, fixed_mode: str | None = None, **kw) -> Callable[[str], Loaded]:
    def load(device: str) -> Loaded:
        import timm

        model = timm.create_model(name, pretrained=True, num_classes=0, **kw).eval()
        cfg = timm.data.resolve_data_config({}, model=model)
        model = model.to(device)
        if fixed_mode:
            size = cfg["input_size"][1]
            return Loaded(model, fixed_input(size, fixed_mode, cfg["mean"], cfg["std"]), [model],
                          notes=f"timm {timm.__version__} {name} {kw or ''}; input {_FIXED_NOTE[fixed_mode].format(s=size)}, "
                                "bicubic, the model's mean/std")
        tf = timm.data.create_transform(**cfg)
        return Loaded(model, tf, [model],
                      notes=f"timm {timm.__version__} {name} {kw or ''}, timm data config {cfg['input_size'][1:]} "
                            f"{cfg['interpolation']} crop_pct {cfg.get('crop_pct')} (resize short side, center crop)")

    return load


_MIT_OC = "MIT (open_clip)"
_HF = "Apache-2.0 (transformers)"
_SSCD_CODE = "MIT (facebookresearch/sscd-copy-detection, relicensed from CC-BY-NC to MIT on 2022-07-14)"
_SSCD_WEIGHTS = "MIT (weights published with the MIT-licensed repo; trained on DISC21 images)"
_DINOV3_LICENSE = ("DINOv3 License (Meta custom license; facebook/ repo is gated, timm/vit_small_patch16_dinov3.lvd1689m "
                   "mirror is not; read the license before shipping)")
METHODS = [
    Method("imagededup-cnn", "cosine",
           "imagededup's CNN method: MobileNetV3-small ImageNet, global-average-pooled 576-d features",
           "Apache-2.0 (imagededup recipe); BSD-3-Clause (torchvision)",
           "BSD-3-Clause (torchvision IMAGENET1K_V1); trained on ImageNet-1k, whose terms may apply",
           torch_method(_imagededup_cnn)),
    Method("clip-b32-openai", "cosine",
           "OpenCLIP ViT-B-32 'openai' image embedding, 512-d (Immich's default smart-search model)",
           _MIT_OC, "MIT (OpenAI CLIP release; HF mirror timm/vit_base_patch32_clip_224.openai is tagged apache-2.0)",
           torch_method(_open_clip("ViT-B-32", "openai", force_quick_gelu=True))),
    Method("mobileclip", "cosine",
           "Apple MobileCLIP2-S0 image embedding, 512-d (smallest MobileCLIP open_clip can load; MobileCLIP-S0 v1 "
           "is not in open_clip)",
           _MIT_OC + "; MIT (apple/ml-mobileclip code)",
           "Apple Machine Learning Research Model License (apple-amlr, LICENSE_MODELS): scientific research only, "
           "not usable in a shipping app",
           torch_method(_open_clip("MobileCLIP2-S0", "dfndr2b", reparameterize=True))),
    Method("siglip2-base", "cosine", "Google SigLIP 2 base/16 at 224 px image embedding, 768-d",
           _HF, "Apache-2.0", torch_method(_siglip2)),
    Method("dinov2-small", "cosine", "Meta DINOv2 ViT-S/14 CLS embedding, 384-d",
           _HF, "Apache-2.0", torch_method(_dinov2("facebook/dinov2-small", "cls"))),
    Method("dinov2-small-mean", "cosine", "Meta DINOv2 ViT-S/14 mean-pooled patch embedding, 384-d",
           _HF, "Apache-2.0", torch_method(_dinov2("facebook/dinov2-small", "mean"))),
    Method("dinov2-base", "cosine", "Meta DINOv2 ViT-B/14 CLS embedding, 768-d",
           _HF, "Apache-2.0", torch_method(_dinov2("facebook/dinov2-base", "cls"))),
    Method("sscd", "cosine", "Meta SSCD copy-detection descriptor (sscd_disc_mixup, ResNet-50), 512-d",
           _SSCD_CODE, _SSCD_WEIGHTS, torch_method(_sscd)),
    Method("dinov3-small", "cosine",
           "Meta DINOv3 ViT-S/16 (LVD-1689M) CLS embedding, 384-d, from timm's ungated mirror",
           "Apache-2.0 (timm)", _DINOV3_LICENSE,
           torch_method(_timm("vit_small_patch16_dinov3.lvd1689m", global_pool="token"))),
    # Whole-image, fixed-size inputs. The standard preprocessing above crops DINO's input to the
    # central square and feeds SSCD a variable size; an app would run a fixed-shape model on the
    # whole photo, so these are the deployable forms.
    Method("sscd-skew320", "cosine", "SSCD (sscd_disc_mixup) on the whole image squashed to 320x320, 512-d",
           _SSCD_CODE, _SSCD_WEIGHTS, torch_method(_sscd_fixed(320, "squash"))),
    Method("sscd-pad320", "cosine", "SSCD (sscd_disc_mixup) on the whole image letterboxed into 320x320, 512-d",
           _SSCD_CODE, _SSCD_WEIGHTS, torch_method(_sscd_fixed(320, "pad"))),
    Method("dinov2-small-squash", "cosine", "DINOv2 ViT-S/14 CLS on the whole image squashed to 224x224, 384-d",
           _HF, "Apache-2.0", torch_method(_dinov2("facebook/dinov2-small", "cls", (224, "squash")))),
    Method("dinov2-small-pad", "cosine", "DINOv2 ViT-S/14 CLS on the whole image letterboxed into 224x224, 384-d",
           _HF, "Apache-2.0", torch_method(_dinov2("facebook/dinov2-small", "cls", (224, "pad")))),
    Method("dinov3-small-squash", "cosine", "DINOv3 ViT-S/16 CLS on the whole image squashed to 256x256, 384-d",
           "Apache-2.0 (timm)", _DINOV3_LICENSE,
           torch_method(_timm("vit_small_patch16_dinov3.lvd1689m", "squash", global_pool="token"))),
]
