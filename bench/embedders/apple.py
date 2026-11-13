"""The app's own analysis: Vision feature print revision 2 through `tkscan features`.

tkscan reads each image like the app's FolderPhotoSource (CGImageSource thumbnail with the
EXIF transform, 1024 px on the long side) and runs VisionFrameAnalyzer, so the vectors are
the app's, after its int8 quantization. GT_SOFTEN=0 turns the softening off.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile

import numpy as np

from .common import TKSCAN, Context, Method, Result, median_ms


def _available() -> str | None:
    if not TKSCAN.exists():
        return f"tkscan not built: cd TidykeepKit && swift build -c release --product tkscan ({TKSCAN})"
    return None


def _run(ctx: Context, soften: str | None) -> Result:
    env = dict(os.environ)
    if soften is not None:
        env["GT_SOFTEN"] = soften
    else:
        env.pop("GT_SOFTEN", None)
    with tempfile.TemporaryDirectory() as tmp:
        lst = os.path.join(tmp, "images.txt")
        with open(lst, "w") as f:
            f.writelines(str(p.resolve()) + "\n" for p in ctx.paths)
        out = os.path.join(tmp, "features.jsonl")
        proc = subprocess.run([str(TKSCAN), "features", lst, out], env=env, capture_output=True, text=True)
        rows = {}
        if os.path.exists(out):
            for line in open(out):
                d = json.loads(line)
                rows[d["id"]] = d
    if proc.returncode != 0 or len(rows) != len(ctx.paths):
        missing = [p.name for p in ctx.paths if p.name not in rows][:5]
        raise RuntimeError(f"tkscan features failed (exit {proc.returncode}), missing {missing}: {proc.stderr[-800:]}")
    analyzer = proc.stderr.strip().splitlines()[-1].split("(")[-1].rstrip(")")
    order = [rows[p.name] for p in ctx.paths]
    X = np.array([r["embedding"] for r in order], dtype=np.float32)
    # Skip the first few: Vision loads its models on first use.
    times = [r["ms"] for r in order[3:]] or [r["ms"] for r in order]
    signals = {
        r["id"]: {k: r.get(k) for k in ("sharpness", "aesthetics", "isUtility", "faceQualities")} for r in order
    }
    # Kept out of out/<dataset>/*.json, where every file is a method's sidecar.
    signals_path = ctx.out_dir / "signals" / f"{'apple-fp2-raw' if soften == '0' else 'apple-fp2-soft'}.json"
    signals_path.parent.mkdir(parents=True, exist_ok=True)
    signals_path.write_text(json.dumps({"analyzer": analyzer, "signals": signals}, indent=0) + "\n")
    return Result(
        X=X,
        ms_per_image=median_ms(times),
        device="vision",
        model_mb=None,
        notes=(
            f"analyzer {analyzer}; ms is the whole VisionFrameAnalyzer.analyze() call (softening, feature "
            "print, aesthetics, face quality, focus measure) on the 1024 px image, so it overstates the "
            "embedding alone; model ships with iOS/macOS (0 MB in the app); ranking signals in "
            f"signals/{signals_path.name}"
        ),
    )


METHODS = [
    Method(
        name="apple-fp2-soft",
        metric="l2",
        what="The app's grouping signal: Vision VNGenerateImageFeaturePrintRequest rev 2 (768-d) on a Gaussian-"
        "softened (sigma 0.8% of long side) 1024 px copy, int8-quantized as the app stores it",
        license_code="Apache-2.0 (Tidykeep); Vision is an Apple OS framework",
        license_weights="Apple OS component (ships with iOS/macOS, no separate weights)",
        run=lambda ctx: _run(ctx, None),
        available=_available,
    ),
    Method(
        name="apple-fp2-raw",
        metric="l2",
        what="Vision feature print rev 2 as in the app but without the softening (GT_SOFTEN=0)",
        license_code="Apache-2.0 (Tidykeep); Vision is an Apple OS framework",
        license_weights="Apple OS component (ships with iOS/macOS, no separate weights)",
        run=lambda ctx: _run(ctx, "0"),
        available=_available,
    ),
]
