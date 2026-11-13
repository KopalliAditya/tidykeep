"""california-nd: near-duplicates in a real personal travel collection, judged by 10 people.

Source: A. Jinda-Apiraksa, V. Vonikakis, S. Winkler, "California-ND: An annotated dataset for
near-duplicate detection in personal photo collections", QoMEX 2013. 701 photos (1024x768,
EXIF kept, faces of the two main people blurred), 10 observers (subject 0 = the photographer).

Getting it: the official californiaND.zip (http://vintage.winklerbros.net/californiaND.zip,
80 MB, also in the Wayback Machine) is ENCRYPTED; the authors give the password by email.
The annotations alone are public (e.g. github.com/NetJagaimo/image_match,
comparative_data/californiaND). This script:
  1. downloads the annotation matrices to bench/data/_raw/californiaND/ if missing
  2. needs the photos at bench/data/_raw/californiaND/Photos/001.jpg ... 701.jpg
     (unzip the official archive with the password into bench/data/_raw/californiaND/)

Ground truth:
  - Each observer grouped the photos; "Correlation matrices/gt_subject<k>.npy" is the 701x701
    0/1 matrix of that observer's groups (it matches the text files in "Individual annotations").
  - votes(a, b) = number of observers (0..10) who put a and b in one group.
  - positives = pairs with votes >= MAJORITY (6 of 10, a strict majority).
  - groups = connected components of the positive-pair graph (components can contain pairs with
    fewer than 6 votes; the count of such non-transitive components is written to notes).
  - pair_agreement = votes / 10 for every pair with at least one vote.
  - times = EXIF DateTimeOriginal (falls back to file order if missing).

    bench/.venv/bin/python bench/datasets/build_california_nd.py [--force]
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.sparse.csgraph import connected_components

from common import DATA, link_or_copy, write_dataset

RAW = DATA / "_raw" / "californiaND"
MIRROR = "https://raw.githubusercontent.com/NetJagaimo/image_match/main/comparative_data/californiaND"
MAJORITY = 6
N = 701


def fetch_annotations() -> None:
    files = ["README.txt", "LICENSE.txt"] + [f"Correlation matrices/gt_subject{i}.npy" for i in range(10)]
    for f in files:
        dst = RAW / f
        if dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(f"{MIRROR}/{f.replace(' ', '%20')}", timeout=120) as r:
            dst.write_bytes(r.read())


def exif_time(path: Path) -> float | None:
    try:
        exif = Image.open(path).getexif()
        text = exif.get_ifd(0x8769).get(36867) or exif.get(306)
        if not text:
            return None
        # Local camera time without zone: treat as UTC so relative gaps are kept.
        return datetime.strptime(text.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    root = DATA / "california-nd"
    if (root / "truth.json").exists() and not args.force:
        print(f"{root} exists; use --force to rebuild")
        return
    fetch_annotations()
    photos = RAW / "Photos"
    missing = [i for i in range(1, N + 1) if not (photos / f"{i:03d}.jpg").exists()]
    if missing:
        sys.exit(
            f"California-ND photos missing ({len(missing)} of {N}) in {photos}.\n"
            "The official zip is password-protected: download http://vintage.winklerbros.net/californiaND.zip "
            "(or its Wayback Machine copy), get the password from the authors, and unzip it into "
            f"{RAW} so that Photos/001.jpg ... Photos/701.jpg exist. Then rerun."
        )

    subj = [np.load(RAW / f"Correlation matrices/gt_subject{i}.npy").astype(np.int32) for i in range(10)]
    votes = sum(subj)
    assert votes.shape == (N, N) and (votes == votes.T).all()
    np.fill_diagonal(votes, 0)
    names = [f"cnd{i:03d}.jpg" for i in range(1, N + 1)]

    pos = votes >= MAJORITY
    n_comp, label = connected_components(pos.astype(np.int8), directed=False)
    groups, nontransitive, weak_pairs = [], 0, 0
    for c in range(n_comp):
        idx = np.where(label == c)[0]
        if len(idx) < 2:
            continue
        groups.append([names[i] for i in idx])
        sub = pos[np.ix_(idx, idx)] | np.eye(len(idx), dtype=bool)
        if not sub.all():
            nontransitive += 1
            weak_pairs += int((~sub).sum() // 2)
    agreement = {}
    iu = np.triu_indices(N, 1)
    for a, b in zip(*iu):
        if votes[a, b] > 0:
            agreement[f"{names[a]}|{names[b]}"] = round(float(votes[a, b]) / 10, 1)

    img_dir = root / "images"
    if img_dir.exists() and args.force:
        shutil.rmtree(img_dir)
    img_dir.mkdir(parents=True, exist_ok=True)
    times, synthesized = {}, 0
    last = None
    for i, name in enumerate(names, start=1):
        src = photos / f"{i:03d}.jpg"
        link_or_copy(src, img_dir / name)
        t = exif_time(src)
        if t is None:
            synthesized += 1
            t = (last or 1_262_304_000) + 10
        times[name] = t
        last = t

    majority_pairs = int(pos[iu].sum())
    summary = write_dataset(
        root,
        name="california-nd",
        kind="near-duplicate",
        source=(
            "A. Jinda-Apiraksa, V. Vonikakis, S. Winkler, 'California-ND: An annotated dataset for near-duplicate "
            "detection in personal photo collections', QoMEX 2013. http://vintage.winklerbros.net/californiaND.html"
        ),
        license="CC BY-NC-ND 3.0 (non-commercial, no derivatives). Local evaluation only; do not redistribute.",
        notes=(
            f"Positives = pairs judged near-duplicate (same group) by >= {MAJORITY} of the 10 observers "
            f"({majority_pairs} pairs). Groups = connected components of those pairs: {len(groups)} groups; "
            f"{nontransitive} components are non-transitive (they contain {weak_pairs} pairs with fewer than "
            f"{MAJORITY} votes that the group still counts as positive). pair_agreement = votes/10 for all "
            f"{len(agreement)} pairs with >= 1 vote. best = first file of each group (no best-shot labels). "
            f"Times from EXIF DateTimeOriginal (camera local time stored as UTC); {synthesized} synthesized."
        ),
        images=names,
        groups=groups,
        times=times,
        pair_agreement=agreement,
        extra={"majority_votes": MAJORITY, "observers": 10},
    )
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
