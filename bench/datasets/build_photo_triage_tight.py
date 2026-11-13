"""photo-triage-tight: photo-triage with the series packed close in time.

The same 731 images and groups as photo-triage (hard links into data/photo-triage/images), but
the next series starts 10-60 s after the previous one ends instead of 2-8 h later, so every
series has other series inside the app's time window. That is the hard case for the app's
linking step: real look-alike shots of different moments taken minutes apart (photo-triage
series ids are consecutive within an album). Within a series the gaps are photo-triage's.

For time-window evaluation only: pair metrics that ignore time are those of photo-triage, so
truth.json has variant_of = "photo-triage" and evaluate.py reads that dataset's embeddings.
No best/preferences (photo-triage scores those).

    bench/.venv/bin/python bench/datasets/build_photo_triage_tight.py [--force]
"""

from __future__ import annotations

import argparse
import json
import random
import shutil

from common import DATA, link_or_copy, write_dataset

SEED = 60
GAP = (10, 60)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    root = DATA / "photo-triage-tight"
    if (root / "truth.json").exists() and not args.force:
        print(f"{root} exists; use --force to rebuild")
        return
    base = json.loads((DATA / "photo-triage" / "truth.json").read_text())
    if root.exists():
        shutil.rmtree(root)
    img_dir = root / "images"
    img_dir.mkdir(parents=True)
    for f in base["images"]:
        link_or_copy(DATA / "photo-triage" / "images" / f, img_dir / f)

    rng = random.Random(SEED)
    old = base["times"]
    groups = sorted(base["groups"], key=lambda g: min(old[f] for f in g))
    times = {}
    clock = min(old.values())
    for k, g in enumerate(groups):
        g = sorted(g, key=lambda f: (old[f], f))
        if k:
            clock += rng.uniform(*GAP)
        t0 = old[g[0]]
        for f in g:
            times[f] = clock + (old[f] - t0)
        clock = times[g[-1]]
    summary = write_dataset(
        root,
        name="photo-triage-tight",
        kind="series",
        source="photo-triage (same images and groups), re-timed; see data/photo-triage/truth.json for the source",
        license=base["license"],
        notes=(
            f"photo-triage with each series starting {GAP[0]}-{GAP[1]} s after the previous one ends (seed {SEED}), in "
            "series-id order; gaps within a series as in photo-triage (1-4 s). Images are hard links to photo-triage's. "
            "For time-window evaluation only (variant_of). TIMES ARE SYNTHESIZED."
        ),
        images=base["images"],
        groups=base["groups"],
        times=times,
        extra={"variant_of": "photo-triage"},
    )
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
