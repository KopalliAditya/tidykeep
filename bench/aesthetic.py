"""LAION aesthetic score (improved-aesthetic-predictor) as a best-shot baseline.

    bench/.venv/bin/python bench/aesthetic.py [--dataset all|a,b] [--force] [--device auto|mps|cpu]

The "sac+logos+ava1-l14-linearMSE" MLP from github.com/christophschuhmann/improved-aesthetic-predictor
(Apache-2.0, code and weights) on the L2-normalized OpenAI CLIP ViT-L/14 image embedding,
exactly as that repo's simple_inference.py does it. CLIP ViT-L/14 comes through open_clip
('ViT-L-14', 'openai', quick GELU), with its standard 224 px bicubic center-crop preprocessing.

Writes bench/out/<dataset>/signals/laion-aesthetic.json: {"model", "license", "ms_per_image",
"scores": {file: score}} (score is on the AVA 1-10 scale; higher is better). Used only to rank
photos within a group, never for grouping.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from embedders.common import DATA, MODELS, OUT, load_rgb, median_ms  # noqa: E402

MLP_URL = ("https://github.com/christophschuhmann/improved-aesthetic-predictor/raw/main/"
           "sac+logos+ava1-l14-linearMSE.pth")
MLP_PATH = MODELS / "laion-aesthetic" / "sac+logos+ava1-l14-linearMSE.pth"
LICENSE = ("MLP: Apache-2.0 (christophschuhmann/improved-aesthetic-predictor, code and weights); "
           "CLIP ViT-L/14: MIT (OpenAI CLIP release), loaded with open_clip (MIT)")


def mlp():
    import torch.nn as nn

    # The repo's MLP (no activations between the linear layers, as released).
    return nn.Sequential(
        nn.Linear(768, 1024), nn.Dropout(0.2), nn.Linear(1024, 128), nn.Dropout(0.2),
        nn.Linear(128, 64), nn.Dropout(0.1), nn.Linear(64, 16), nn.Linear(16, 1),
    )


def load(device: str):
    import open_clip
    import torch

    if not MLP_PATH.exists():
        MLP_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = MLP_PATH.with_suffix(".part")
        urllib.request.urlretrieve(MLP_URL, tmp)
        tmp.replace(MLP_PATH)
    head = mlp()
    state = torch.load(MLP_PATH, map_location="cpu")
    # The checkpoint was saved from a LightningModule holding the Sequential as `layers`.
    head.load_state_dict({k.removeprefix("layers."): v for k, v in state.items()})
    head = head.eval().to(device)
    model, _, preprocess = open_clip.create_model_and_transforms(
        "ViT-L-14", pretrained="openai", force_quick_gelu=True, cache_dir=str(MODELS / "open_clip"))
    visual = model.visual.eval().to(device)
    return visual, head, preprocess


def main() -> int:
    import torch

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", default="all")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--device", default="auto", choices=["auto", "mps", "cpu"])
    args = ap.parse_args()
    have = sorted(p.parent.name for p in DATA.glob("*/truth.json"))
    names = have if args.dataset == "all" else args.dataset.split(",")
    device = args.device if args.device != "auto" else ("mps" if torch.backends.mps.is_available() else "cpu")
    loaded = None
    for ds in names:
        out = OUT / ds / "signals" / "laion-aesthetic.json"
        if out.exists() and not args.force:
            print(f"[{ds}] exists, skipping (use --force)")
            continue
        loaded = loaded or load(device)
        visual, head, preprocess = loaded
        sync = torch.mps.synchronize if device == "mps" else (lambda: None)
        files = json.loads((DATA / ds / "truth.json").read_text())["images"]
        scores, times = {}, []
        with torch.inference_mode():
            for i, f in enumerate(files):
                im = load_rgb(DATA / ds / "images" / f)
                sync()
                t = time.perf_counter()
                emb = visual(preprocess(im)[None].to(device)).float()
                emb = emb / emb.norm(dim=-1, keepdim=True).clamp_min(1e-12)
                score = float(head(emb).item())
                sync()
                if i >= 3:  # warm-up
                    times.append((time.perf_counter() - t) * 1000)
                scores[f] = round(score, 4)
        out.parent.mkdir(parents=True, exist_ok=True)
        meta = {"model": "LAION improved-aesthetic-predictor sac+logos+ava1-l14-linearMSE on OpenAI CLIP ViT-L/14",
                "license": LICENSE, "device": device, "ms_per_image": median_ms(times),
                "model_mb": round(sum(p.numel() for p in [*visual.parameters(), *head.parameters()]) * 4 / 1e6, 1),
                "scores": scores}
        out.write_text(json.dumps(meta, indent=0) + "\n")
        v = np.array(list(scores.values()))
        print(f"[{ds}] {len(scores)} images, score mean {v.mean():.2f} (min {v.min():.2f}, max {v.max():.2f}), "
              f"{meta['ms_per_image']} ms/img on {device}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
