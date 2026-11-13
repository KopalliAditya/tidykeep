"""photo-triage: real personal-photo series with human best-shot preferences.

Source: Princeton Adobe Photo Triage dataset (Chang, Yu, Wang, Ashley, Finkelstein,
"Automatic Triage for a Photo Series", SIGGRAPH 2016). The project site
phototriage.cs.princeton.edu no longer resolves; the same package (train_val/ and test/
folders with the original README files) is mirrored on Kaggle as ericwolter/triage
(13.6 GB zip). Only the needed members are read, with HTTP Range requests.

Subset (reproducible):
  - every validation series (195 series, 503 images): these have human preferences
  - plus N_TEST test series drawn with random.Random(SEED) from the 967 test series
    (test series have no released preferences; they add groups only)

Ground truth:
  - groups = series (every image belongs to its series; there are no singles)
  - preferences = validation pairs whose preference ratio (val_pairlist.txt column 4,
    P(photo1 preferred over photo2) from the dataset's Bradley-Terry fit of crowd votes)
    is >= 0.7 or <= 0.3, the threshold the dataset's own test.m uses for its pair accuracy
  - best = the rank-1 photo of each validation series (train_val_series.mat RANK)
  - times are SYNTHESIZED: photos in a series 1-4 s apart, series 2-8 h apart, in series-id
    order. The real capture times are not in the release.

    bench/.venv/bin/python bench/datasets/build_photo_triage.py [--force]
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
import urllib.error
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import scipy.io as sio

from common import DATA, pair_key, write_dataset
from remotezip import HTTPRangeFile

KAGGLE = "https://www.kaggle.com/api/v1/datasets/download/ericwolter/triage"
RAW = DATA / "_raw" / "phototriage"
SEED = 2016
N_TEST = 85
PREF_THRESHOLD = 0.7
START = 1_740_787_200  # 2025-03-01T00:00:00Z


def signed_url() -> str:
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None

    try:
        urllib.request.build_opener(NoRedirect).open(KAGGLE, timeout=60)
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307):
            return e.headers["Location"]
        raise
    raise RuntimeError("expected a redirect to the archive")


META = [
    "test/README.txt",
    "test/test_pairlist.txt",
    "train_val/README.txt",
    "train_val/test.m",
    "train_val/train_pairlist.txt",
    "train_val/val_pairlist.txt",
    "train_val/train_val_series.mat",
]


def fetch_meta(url: str) -> list[str]:
    RAW.mkdir(parents=True, exist_ok=True)
    names_path = RAW / "namelist.json"
    missing = [m for m in META if not (RAW / m).exists()]
    if missing or not names_path.exists():
        z = zipfile.ZipFile(HTTPRangeFile(url))
        for m in META:
            (RAW / m).parent.mkdir(parents=True, exist_ok=True)
            (RAW / m).write_bytes(z.read(m))
        names_path.write_text(json.dumps(z.namelist()))
    return json.loads(names_path.read_text())


def fetch_images(url: str, members: list[tuple[str, Path]], threads: int = 8) -> None:
    todo = [(m, d) for m, d in members if not d.exists()]
    if not todo:
        return
    chunks = [todo[i::threads] for i in range(threads)]

    def work(chunk):
        z = zipfile.ZipFile(HTTPRangeFile(url))
        for m, d in chunk:
            tmp = d.with_suffix(".part")
            tmp.write_bytes(z.read(m))
            tmp.rename(d)
        return len(chunk)

    with ThreadPoolExecutor(threads) as ex:
        done = sum(ex.map(work, chunks))
    print(f"fetched {done} images")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    root = DATA / "photo-triage"
    if root.exists() and (root / "truth.json").exists() and not args.force:
        print(f"{root} exists; use --force to rebuild")
        return
    url = signed_url()
    names = fetch_meta(url)

    # Series membership from the image names: SERIES(%06d)-PHOTO(%02d).JPG
    members: dict[tuple[str, int], list[int]] = {}
    for n in names:
        if n.lower().endswith(".jpg"):
            split = "test" if n.startswith("test/") else "train_val"
            sid, idx = n.rsplit("/", 1)[1].split(".")[0].split("-")
            members.setdefault((split, int(sid)), []).append(int(idx))
    val_rows = [l.split() for l in (RAW / "train_val/val_pairlist.txt").read_text().splitlines() if l.strip()]
    val_ids = sorted({int(r[0]) for r in val_rows})
    test_ids = sorted({int(l.split()[0]) for l in (RAW / "test/test_pairlist.txt").read_text().splitlines() if l.strip()})
    picked_test = sorted(random.Random(SEED).sample(test_ids, N_TEST))

    mat = sio.loadmat(RAW / "train_val/train_val_series.mat", squeeze_me=True, struct_as_record=False)["train_val_series"]
    rank = {int(e.SERIES_ID): [int(r) for r in (e.RANK if hasattr(e.RANK, "__len__") else [e.RANK])] for e in mat}

    def fname(sid: int, idx: int) -> str:
        return f"pt{sid:06d}-{idx:02d}.jpg"

    series = [("train_val", s) for s in val_ids] + [("test", s) for s in picked_test]
    series.sort(key=lambda t: t[1])
    if root.exists() and args.force:
        for p in (root / "images").glob("*"):
            if p.name in ("truth.json", "manifest.json"):
                p.unlink()
    img_dir = root / "images"
    img_dir.mkdir(parents=True, exist_ok=True)
    jobs = []
    for split, sid in series:
        sub = "test/test_imgs" if split == "test" else "train_val/train_val_imgs"
        for idx in sorted(members[(split, sid)]):
            jobs.append((f"{sub}/{sid:06d}-{idx:02d}.JPG", img_dir / fname(sid, idx)))
    keep = {d.name for _, d in jobs}
    for p in img_dir.glob("*.jpg"):
        if p.name not in keep:
            p.unlink()
    fetch_images(url, jobs)

    rng = random.Random(SEED + 1)
    groups, best, times, split_of = [], {}, {}, {}
    clock = float(START)
    for gi, (split, sid) in enumerate(series):
        files = [fname(sid, i) for i in sorted(members[(split, sid)])]
        groups.append(files)
        split_of[str(gi)] = "val" if split == "train_val" else "test"
        if split == "train_val":
            r = rank[sid]
            assert len(r) == len(files), (sid, r, files)
            best[str(gi)] = files[r.index(1)]
        for f in files:
            times[f] = clock
            clock += rng.randint(1, 4)
        clock += rng.randint(2 * 3600, 8 * 3600)

    preferences, ratio = [], {}
    for sid, p1, p2, pref, *_ in val_rows:
        a, b, pr = fname(int(sid), int(p1)), fname(int(sid), int(p2)), float(pref)
        ratio[pair_key(a, b)] = pr if a < b else 1 - pr
        if pr >= PREF_THRESHOLD:
            preferences.append([a, b])
        elif pr <= 1 - PREF_THRESHOLD:
            preferences.append([b, a])

    images = sorted(d.name for _, d in jobs)
    summary = write_dataset(
        root,
        name="photo-triage",
        kind="series",
        source=(
            "Princeton Adobe Photo Triage dataset: H. Chang, F. Yu, J. Wang, D. Ashley, A. Finkelstein, "
            "'Automatic Triage for a Photo Series', ACM TOG (SIGGRAPH) 35(4), 2016. "
            "Site phototriage.cs.princeton.edu (offline); package mirrored at https://www.kaggle.com/datasets/ericwolter/triage"
        ),
        license="Research use; images (c) their original owners / dataset authors (no open license stated). Cite the paper. Do not redistribute.",
        notes=(
            f"All {len(val_ids)} validation series plus {N_TEST} test series sampled with random.Random({SEED}). "
            "Groups = series exactly as released (real consecutive shots from personal albums, 2-8 photos, "
            "images resized by the authors to about 0.6 MP: their README says 800x800 but the long side is 774-1200 px, median 894). No singles. "
            f"preferences = validation pairs with official preference ratio >= {PREF_THRESHOLD} (or <= {1 - PREF_THRESHOLD:.1f}, "
            "flipped); the ratio is the dataset's Bradley-Terry-modelled P(photo1 preferred over photo2) from "
            "val_pairlist.txt, and 0.7 is the threshold of the dataset's own test.m. preference_ratio holds the ratio "
            "for every validation pair as P(first name in key preferred). best = rank-1 photo of each validation "
            "series. Test series have no preferences and no best. The raw per-vote review JSONs in the mirror do not "
            "agree with the released ratios (r=0.26 on 2-photo series), so they are not used. TIMES ARE SYNTHESIZED: "
            "photos 1-4 s apart within a series, series 2-8 h apart, ordered by series id. Different series come "
            "from different albums or moments but a few may still look alike (same trip), so a small number of "
            "'negative' pairs may be true near-duplicates."
        ),
        images=images,
        groups=groups,
        times=times,
        best=best,
        preferences=preferences,
        extra={"preference_ratio": ratio, "preference_threshold": PREF_THRESHOLD, "group_split": split_of},
    )
    print(json.dumps(summary, indent=1), "preferences", len(preferences))


if __name__ == "__main__":
    main()
