"""Convert DINOv2-small (Apache-2.0) into the Core ML image encoder the app ships.

Why this model: in the benchmark (bench/RESULTS.md) DINOv2-small is the best Apache-2.0
embedding for copies across the whole library and for real photo series. SSCD and CLIP score
as well or better but are MIT, so they can't ship.

What the model takes and gives:

- Input `image`: one 224x224 RGB picture, cut from the photo the way the transformers
  processor does it (the bench's `dinov2-small`): resize so the short side is 256 with
  torchvision's antialiased bicubic (the app reproduces it bit for bit in
  TidykeepVision/BicubicResampler.swift), then take the center 224x224. The engine's series and copy
  thresholds were fitted on this input (bench/rules.py); squashing or letterboxing the photo
  instead makes them wrong (the squashed patch mean fails held-out series precision and the
  squashed CLS finds 139 of 150 copy sets instead of 150). The graph itself only sees a fixed
  224x224 square, which is what runs best on the Neural Engine, so the framing is the caller's
  choice and changing it needs no reconversion.
- ImageNet normalization is inside the model, so the caller hands over plain 8-bit pixels.
  Core ML's image input can only apply one scale for all channels plus a bias per channel, so
  the mean is subtracted there (scale 1/255, bias -mean) and the per-channel 1/std is folded
  into the patch-embedding convolution. Both are exact, not an approximation.
- Outputs `cls_embedding` and `mean_embedding`: the CLS token and the mean of the 256 patch
  tokens after the final layer norm, each L2-normalized, float32 [1, 384]. Cosine similarity is
  then a dot product. The bench measured CLS; both are exported so the app can choose.

The position embeddings are resampled from the 518 px training grid to the 16x16 grid once,
here, exactly as transformers does it at run time (bicubic in float32), and stored as a
constant. That keeps the bicubic resampling out of the Core ML graph.

Precision: an ML Program in float16, except the patch-embedding convolution, which stays in
float32 (see `convert`). That one op then runs on the CPU while the rest runs on the Neural
Engine; on an M3 Max that is no slower than all-float16 (2.7 ms vs 3.2 ms per image).

Weight variants (`VARIANTS`): `pal8g` (8-bit k-means palettes per group of 16 output channels,
about 23 MB, needs iOS 18) is the one to ship; `fp16` (about 44 MB) is the uncompressed
reference. The 6- and 4-bit palettes lose too much on screenshots. `lin8b` is the most accurate
8-bit form, but the Neural Engine doesn't run per-block int8 weights, so it falls back to the
GPU at about twice the latency.

Environment (separate from bench/.venv, whose torch is newer than coremltools supports):

    uv venv <venv> --python 3.12
    VIRTUAL_ENV=<venv> uv pip install -r bench/coreml/requirements.txt
    <venv>/bin/python bench/coreml/convert_dinov2.py --out <dir> --variants fp16,pal8g

Weights come from the bench cache (bench/models/hf); they download only if missing. The
output folder gets one DINOv2Small-<variant>.mlpackage per variant. Nothing large belongs in
the repo.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

BENCH = Path(__file__).resolve().parent.parent
os.environ.setdefault("HF_HOME", str(BENCH / "models" / "hf"))
os.environ.setdefault("TORCH_HOME", str(BENCH / "models" / "torch"))

import numpy as np  # noqa: E402
import torch  # noqa: E402

REPO_ID = "facebook/dinov2-small"
REVISION = "ed25f3a31f01632728cabb09d1542f84ab7b0056"  # the snapshot the benchmark used
SIZE = 224
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)

# Weight compression, all applied after conversion with coremltools.optimize.coreml.
# Tensors under 2048 elements (biases, norms, layer scales) stay fp16 in every variant.
VARIANTS = {
    "fp16": None,
    "lin8": ("linear", dict(mode="linear_symmetric", dtype="int8", granularity="per_channel")),
    "lin8b": ("linear", dict(mode="linear_symmetric", dtype="int8", granularity="per_block", block_size=32)),
    "pal8":("palettize", dict(mode="kmeans", nbits=8, granularity="per_tensor")),
    "pal8g": ("palettize", dict(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=16)),
    "pal6g": ("palettize", dict(mode="kmeans", nbits=6, granularity="per_grouped_channel", group_size=16)),
    "pal4g": ("palettize", dict(mode="kmeans", nbits=4, granularity="per_grouped_channel", group_size=16)),
}


def load_reference(attn: str = "sdpa"):
    """The transformers model the benchmark ran (eval mode, float32).

    Pinned to a commit, so a cached copy is used without asking the network.
    """
    from transformers import AutoModel

    return AutoModel.from_pretrained(REPO_ID, revision=REVISION, attn_implementation=attn).eval()


def reference_embed(model, rgb01: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """What the bench computes: ImageNet-normalize, run, take CLS and patch mean, L2-normalize."""
    mean = torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1)
    std = torch.tensor(IMAGENET_STD).view(1, 3, 1, 1)
    h = model(pixel_values=(rgb01 - mean) / std).last_hidden_state
    f = torch.nn.functional.normalize
    return f(h[:, 0], dim=-1), f(h[:, 1:].mean(1), dim=-1)


class Encoder(torch.nn.Module):
    """DINOv2-small with the input normalization folded in and fixed 224x224 position embeddings.

    Expects `x = pixels / 255 - mean` (what the Core ML image input produces).
    """

    def __init__(self, ref) -> None:
        super().__init__()
        emb = ref.embeddings
        conv = emb.patch_embeddings.projection
        with torch.no_grad():
            self.patch = torch.nn.Conv2d(3, conv.out_channels, conv.kernel_size, conv.stride)
            std = torch.tensor(IMAGENET_STD).view(1, 3, 1, 1)
            self.patch.weight.copy_(conv.weight / std)  # (x - m) / s through a linear conv
            self.patch.bias.copy_(conv.bias)
            n = (SIZE // conv.stride[0]) ** 2
            pos = emb.interpolate_pos_encoding(torch.zeros(1, n + 1, conv.out_channels), SIZE, SIZE)
            self.register_buffer("cls_pos", emb.cls_token + pos[:, :1])
            self.register_buffer("patch_pos", pos[:, 1:].clone())
        self.layers = ref.encoder.layer
        self.norm = ref.layernorm

    @staticmethod
    def unit(v: torch.Tensor) -> torch.Tensor:
        # Scaled first so the sum of squares can't overflow float16 (token norms are ~50).
        v = v * (1.0 / 16.0)
        return v / torch.sqrt((v * v).sum(-1, keepdim=True) + 1e-6)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        p = self.patch(x).flatten(2).transpose(1, 2) + self.patch_pos
        h = torch.cat((self.cls_pos.expand(x.shape[0], -1, -1), p), dim=1)
        for layer in self.layers:
            h = layer(h)
        h = self.norm(h)
        return self.unit(h[:, 0]), self.unit(h[:, 1:].mean(1))


def check_wrapper(ref, enc) -> float:
    """The folded encoder must match the reference to float32 rounding."""
    g = torch.Generator().manual_seed(0)
    rgb01 = torch.randint(0, 256, (2, 3, SIZE, SIZE), generator=g).float() / 255
    with torch.no_grad():
        a = reference_embed(ref, rgb01)
        b = enc(rgb01 - torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1))
    err = max(float((x - y).abs().max()) for x, y in zip(a, b))
    assert err < 1e-4, f"wrapper differs from the reference by {err}"
    return err


def convert(enc, target: str, fp32_conv: bool = True):
    import coremltools as ct

    example = torch.zeros(1, 3, SIZE, SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(enc, example)
    image = ct.ImageType(name="image", shape=example.shape, color_layout=ct.colorlayout.RGB,
                         scale=1 / 255, bias=[-m for m in IMAGENET_MEAN])
    # Everything runs in float16 except the patch-embedding convolution (0.4% of the work).
    # On the CPU, Core ML's float16 convolution lost enough precision on flat screenshots that
    # the embedding drifted to cosine 0.9925 from PyTorch; in float32 the worst case is 0.9988,
    # and the Neural Engine path is as fast as before.
    precision = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type != "conv") if fp32_conv \
        else ct.precision.FLOAT16
    return ct.convert(
        traced,
        inputs=[image],
        # float32 outputs: the math runs in float16, but Swift reads plain Floats.
        outputs=[ct.TensorType(name="cls_embedding", dtype=np.float32),
                 ct.TensorType(name="mean_embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=getattr(ct.target, target),
    )


def compress(mlmodel, variant: str):
    import coremltools.optimize.coreml as cto

    spec = VARIANTS[variant]
    if spec is None:
        return mlmodel
    kind, kw = spec
    if kind == "linear":
        cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(**kw))
        return cto.linear_quantize_weights(mlmodel, cfg)
    # coremltools 9.0 closes its shared k-means worker pool after one model but keeps the closed
    # pool, so a second palettization in the same process fails. Drop it first.
    from coremltools.optimize.coreml import _quantization_passes as qp

    pool = qp.palettize_weights._compress_pool
    if pool is not None:
        pool.terminate()
        qp.palettize_weights._compress_pool = None
    cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(num_kmeans_workers=8, **kw))
    return cto.palettize_weights(mlmodel, cfg)


def describe(mlmodel, variant: str, target: str) -> None:
    mlmodel.author = "Meta AI (DINOv2 ViT-S/14); converted to Core ML for Tidykeep"
    mlmodel.license = "Apache-2.0 (DINOv2 code and weights, Copyright (c) Meta Platforms, Inc. and affiliates)"
    mlmodel.short_description = (
        "DINOv2-small image encoder for finding duplicate and similar photos. Feed the center "
        "224x224 of the photo resized to a 256 px short side; compare embeddings by dot product.")
    mlmodel.version = "1.0"
    mlmodel.input_description["image"] = "Photo resized to a 256 px short side, center 224x224, sRGB"
    mlmodel.output_description["cls_embedding"] = "CLS token after the final layer norm, L2-normalized, 384-d"
    mlmodel.output_description["mean_embedding"] = "Mean of the 256 patch tokens after the final layer norm, L2-normalized, 384-d"
    meta = mlmodel.user_defined_metadata
    meta["source"] = f"huggingface.co/{REPO_ID}@{REVISION}"
    meta["weights"] = variant
    meta["minimum_deployment_target"] = target
    meta["preprocessing"] = ("short side to 256 (antialiased bicubic), center crop 224x224; "
                            "ImageNet mean/std inside the model")


def smoke(mlmodel, ref) -> tuple[float, float]:
    """One deterministic picture through Core ML and PyTorch: cosine of each output."""
    from PIL import Image

    y, x = np.mgrid[0:SIZE, 0:SIZE]
    rgb = np.stack([(x * 255 // SIZE), (y * 255 // SIZE), ((x ^ y) & 255)], -1).astype(np.uint8)
    out = mlmodel.predict({"image": Image.fromarray(rgb)})
    with torch.no_grad():
        a = reference_embed(ref, torch.from_numpy(rgb).permute(2, 0, 1)[None].float() / 255)
    return tuple(float(np.dot(out[k].reshape(-1), v[0].numpy()))
                 for k, v in zip(("cls_embedding", "mean_embedding"), a))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", type=Path, required=True, help="folder for the .mlpackage files (outside the repo)")
    ap.add_argument("--variants", default="pal8g", help=f"comma-separated, from: {', '.join(VARIANTS)}")
    ap.add_argument("--target", default="iOS18", help="minimum deployment target (iOS17, iOS18, iOS26)")
    ap.add_argument("--attn", default="sdpa", choices=("sdpa", "eager"), help="attention as traced")
    ap.add_argument("--all-fp16", action="store_true", help="run the patch convolution in float16 too")
    args = ap.parse_args()

    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    unknown = [v for v in variants if v not in VARIANTS]
    if unknown:
        ap.error(f"unknown variants {unknown}")
    torch.set_grad_enabled(False)
    ref = load_reference(args.attn)
    enc = Encoder(ref).eval()
    print(f"wrapper vs reference, max abs difference: {check_wrapper(ref, enc):.2e}")
    base = convert(enc, args.target, fp32_conv=not args.all_fp16)
    args.out.mkdir(parents=True, exist_ok=True)
    for v in variants:
        m = compress(base, v)
        describe(m, v, args.target)
        path = args.out / f"DINOv2Small-{v}.mlpackage"
        m.save(str(path))
        mb = sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 1e6
        line = f"{path.name}: {mb:.1f} MB"
        if sys.platform == "darwin":
            line += ", smoke cosine cls %.5f mean %.5f" % smoke(m, ref)
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
