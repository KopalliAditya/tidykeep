"""bursts-profile: the app's own calibration set, built by `tkscan bursts`.

Every image under /Library/User Pictures/*/ (the macOS account pictures) is copied into a flat
temp folder, then `tkscan bursts` turns each source into a handheld burst (reframing, tilt,
exposure drift; every frame but one gets motion or focus blur) and keeps every third source
as a one-off single. Its truth.json/manifest.json are converted to the shared format.

    bench/.venv/bin/python bench/datasets/build_bursts_profile.py [--force]
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

from common import BENCH, DATA, IMAGE_EXTS, safe_name, write_dataset

TKSCAN = BENCH.parent / "TidykeepKit/.build/release/tkscan"
SOURCES = Path("/Library/User Pictures")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    root = DATA / "bursts-profile"
    if root.exists():
        if not args.force:
            print(f"{root} exists; use --force to rebuild")
            return
        shutil.rmtree(root)
    assert TKSCAN.exists(), f"build tkscan first: {TKSCAN}"

    with tempfile.TemporaryDirectory() as tmp:
        flat = Path(tmp) / "sources"
        flat.mkdir()
        n = 0
        for cat in sorted(p for p in SOURCES.iterdir() if p.is_dir()):
            for f in sorted(cat.iterdir()):
                if f.suffix.lower() not in IMAGE_EXTS:
                    continue
                dst = flat / safe_name(f"{cat.name}-{f.stem}{f.suffix.lower()}")
                assert not dst.exists(), dst
                shutil.copyfile(f.resolve(), dst)
                n += 1
        print(f"{n} sources")
        images = root / "images"
        subprocess.run([str(TKSCAN), "bursts", str(images), str(flat)], check=True)

    gt = json.loads((images / "truth.json").read_text())
    manifest = json.loads((images / "manifest.json").read_text())["files"]
    times = {f: datetime.fromisoformat(e["date"].replace("Z", "+00:00")).timestamp() for f, e in manifest.items()}
    files = sorted(p.name for p in images.iterdir() if p.suffix.lower() in IMAGE_EXTS)
    groups = [s["files"] for s in gt["series"] if len(s["files"]) >= 2]
    best = {str(i): s["best"] for i, s in enumerate(s for s in gt["series"] if len(s["files"]) >= 2)}
    summary = write_dataset(
        root,
        name="bursts-profile",
        kind="series",
        source="tkscan bursts over the macOS account pictures in /Library/User Pictures (Apple system images)",
        license="Apple system images shipped with macOS; for local evaluation only, do not redistribute",
        notes=(
            "Synthetic handheld bursts made by TidykeepKit BurstLibrary (seed 7): each source becomes 2-5 frames "
            "with 90-96% reframing, +-1.5 deg tilt, +-0.3 EV exposure drift; every frame but the best gets motion "
            "blur (radius 4-12 px at 1024) or Gaussian focus blur (sigma 1.5-3.5). Every 3rd source is a single "
            "(one handheld frame). Frames 1-3 s apart, moments 6-40 s apart. best = the one unblurred frame. "
            "images/truth.json and images/manifest.json are exactly as tkscan wrote them."
        ),
        images=files,
        groups=groups,
        times=times,
        best=best,
        write_tkscan=False,  # keep tkscan's own files
    )
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
