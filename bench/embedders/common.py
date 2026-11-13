"""Shared pieces for the embedding methods: paths, image loading, timing, output files."""

from __future__ import annotations

import json
import os
import statistics
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np

BENCH = Path(__file__).resolve().parent.parent
DATA = BENCH / "data"
OUT = BENCH / "out"
MODELS = BENCH / "models"
GTSCAN = BENCH.parent / "GoodTakeKit" / ".build" / "release" / "gtscan"

# Every download lands in bench/models (gitignored). Set before torch / transformers import.
os.environ.setdefault("HF_HOME", str(MODELS / "hf"))
os.environ.setdefault("TORCH_HOME", str(MODELS / "torch"))
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


@dataclass
class Context:
    """What a method needs to run on one dataset."""

    dataset: str
    paths: list[Path]  # in truth.json "images" order
    out_dir: Path
    device: str = "auto"  # auto | mps | cpu
    batch: int = 32
    timing_images: int = 30


@dataclass
class Result:
    X: np.ndarray  # float32 [n, d] or uint8 0/1 bits [n, bits]
    ms_per_image: float
    device: str
    model_mb: float | None = None
    notes: str = ""
    extra_arrays: dict[str, np.ndarray] = field(default_factory=dict)


@dataclass
class Method:
    name: str
    metric: str  # cosine | l2 | hamming
    what: str
    license_code: str
    license_weights: str
    run: Callable[[Context], Result]
    available: Callable[[], str | None] = lambda: None  # a reason when it can't run here


def load_rgb(path: Path):
    """The image upright (EXIF orientation applied, as Photos and the app show it), in RGB."""
    from PIL import Image, ImageOps

    import pillow_heif

    pillow_heif.register_heif_opener()
    Image.MAX_IMAGE_PIXELS = None
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im)
        if im.mode in ("I;16", "I;16B", "I;16L", "I"):
            im = im.point(lambda v: v / 256).convert("L")
        if im.mode in ("RGBA", "LA", "P", "PA"):
            # Transparent pixels count as white, not as whatever color they happen to hold.
            rgba = im.convert("RGBA")
            bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
            im = Image.alpha_composite(bg, rgba)
        return im.convert("RGB")


def median_ms(samples: list[float]) -> float:
    return round(statistics.median(samples), 3) if samples else float("nan")


class Stopwatch:
    def __init__(self, sync: Callable[[], None] | None = None):
        self.sync = sync or (lambda: None)

    def __enter__(self):
        self.sync()
        self.t = time.perf_counter()
        return self

    def __exit__(self, *exc):
        self.sync()
        self.ms = (time.perf_counter() - self.t) * 1000


def l2_normalize(X: np.ndarray) -> np.ndarray:
    X = X.astype(np.float32)
    n = np.linalg.norm(X, axis=1, keepdims=True)
    return X / np.maximum(n, 1e-12)


def output_paths(dataset: str, method: str) -> tuple[Path, Path]:
    d = OUT / dataset
    return d / f"{method}.npz", d / f"{method}.json"


def write_output(ctx: Context, method: Method, res: Result) -> None:
    npz, side = output_paths(ctx.dataset, method.name)
    npz.parent.mkdir(parents=True, exist_ok=True)
    ids = np.array([p.name for p in ctx.paths])
    X = res.X
    assert X.shape[0] == len(ids), (X.shape, len(ids))
    if method.metric == "hamming":
        assert X.dtype == np.uint8 and set(np.unique(X)) <= {0, 1}, "hash bits must be uint8 0/1"
    else:
        X = X.astype(np.float32)
        assert np.isfinite(X).all(), "non-finite embedding values"
    tmp = npz.with_name(npz.name + ".tmp")
    with open(tmp, "wb") as f:
        np.savez_compressed(f, ids=ids, X=X, **res.extra_arrays)
    tmp.replace(npz)
    meta = {
        "method": method.name,
        "metric": method.metric,
        "dim": int(X.shape[1]),
        "ms_per_image": res.ms_per_image,
        "device": res.device,
        "model_mb": None if res.model_mb is None else round(res.model_mb, 1),
        "license_code": method.license_code,
        "license_weights": method.license_weights,
        "notes": (method.what + ". " + res.notes).strip(),
        "n": int(len(ids)),
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    side.write_text(json.dumps(meta, indent=1) + "\n")
