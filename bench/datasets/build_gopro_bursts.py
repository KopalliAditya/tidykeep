"""gopro-bursts: real camera-shake and motion blur, held out from every threshold choice.

Source: the GoPro deblurring dataset (S. Nah, T. H. Kim, K. M. Lee, "Deep Multi-scale
Convolutional Neural Network for Dynamic Scene Deblurring", CVPR 2017), GOPRO_Large.zip as
mirrored at https://huggingface.co/datasets/snah/GOPRO_Large (CC-BY-4.0). Handheld GoPro
video at 240 fps; each "blur" frame is the average of 7-13 consecutive frames (real camera
shake and subject motion, like a slow shutter) and each "sharp" frame is the middle one.
Only the needed members are read, with HTTP Range requests.

Every one of the 33 clips (train and test) gives two moments, early and late in the clip:
  moment = sharp frame i + blur frames i, i+3, i+6   (one keeper, three shaky frames)
so a group is a sharp shot and blurred shots of the same instant, the case the app's
softening is for. best = the sharp frame. Frames are saved as JPEG q92 at 1280x720 under
neutral names (gopro.json maps them back).

Pairs from the two moments of one clip are NOT scored (truth "unscored_same"): they are the
same scene a few seconds later, which some people would call one series and others not.
Evaluation reports them separately (how often a method links them). Pairs from different
clips are negatives; clips of one recording (GOPR0384_11_00 ... _05) show the same place,
so those are hard negatives.

Times are SYNTHESIZED: frames of a moment 1-2 s apart in random order, the second moment
3-8 s after the first, clips of one recording 30-120 s apart, recordings 1-6 h apart.

    bench/.venv/bin/python bench/datasets/build_gopro_bursts.py [--force]
"""

from __future__ import annotations

import argparse
import io
import json
import random
import shutil
import zipfile
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image

from common import DATA, write_dataset, write_json
from remotezip import HTTPRangeFile

URL = "https://huggingface.co/datasets/snah/GOPRO_Large/resolve/main/GOPRO_Large.zip"
SEED = 240
START = 1_746_057_600  # 2025-05-01T00:00:00Z
OFFSETS = (0, 3, 6)  # blur frames i, i+3, i+6 next to sharp frame i
POSITIONS = (0.15, 0.80)  # where in the clip the two moments are


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    root = DATA / "gopro-bursts"
    if (root / "truth.json").exists() and not args.force:
        print(f"{root} exists; use --force to rebuild")
        return
    rng = random.Random(SEED)
    raw = DATA / "_raw" / "gopro"
    raw.mkdir(parents=True, exist_ok=True)

    z = zipfile.ZipFile(HTTPRangeFile(URL))
    frames: dict[str, dict[str, set[int]]] = defaultdict(lambda: defaultdict(set))
    for n in z.namelist():
        parts = n.split("/")
        if len(parts) == 4 and parts[3].endswith(".png") and parts[2] in ("sharp", "blur"):
            frames[f"{parts[0]}/{parts[1]}"][parts[2]].add(int(parts[3][:-4]))
    clips = sorted(frames, key=lambda c: c.split("/")[1])
    print(f"{len(clips)} clips")

    # Pick the frames.
    moments = []  # (clip, moment index, [(kind, frame)])
    for clip in clips:
        sharp, blur = sorted(frames[clip]["sharp"]), frames[clip]["blur"]
        assert set(sharp) == blur, clip
        first, last = sharp[0], sharp[-1]
        for k, pos in enumerate(POSITIONS):
            i = first + round(pos * (last - first - max(OFFSETS)))
            members = [("sharp", i)] + [("blur", i + o) for o in OFFSETS]
            assert all(f in blur for _, f in members), (clip, i)
            moments.append((clip, k, members))

    # Fetch (cached as the original PNGs in data/_raw/gopro).
    jobs = sorted({(f"{clip}/{kind}/{f:06d}.png", raw / f"{clip.replace('/', '_')}_{kind}_{f:06d}.png")
                   for clip, _, members in moments for kind, f in members})
    todo = [j for j in jobs if not j[1].exists()]
    if todo:
        threads = 8

        def work(chunk):
            zz = zipfile.ZipFile(HTTPRangeFile(URL))
            for m, d in chunk:
                d.with_suffix(".part").write_bytes(zz.read(m))
                d.with_suffix(".part").rename(d)

        with ThreadPoolExecutor(threads) as ex:
            list(ex.map(work, [todo[i::threads] for i in range(threads)]))
        print(f"fetched {len(todo)} frames")

    if root.exists():
        shutil.rmtree(root)
    img_dir = root / "images"
    img_dir.mkdir(parents=True)
    ids = iter(rng.sample(range(100000, 999999), 4 * len(moments)))
    groups, best, times, meta, clip_of = [], {}, {}, {}, {}
    clock = float(START)
    last_recording = None
    by_clip = defaultdict(list)
    for m in moments:
        by_clip[m[0]].append(m)
    for clip in clips:
        recording = clip.split("/")[1].split("_")[0]
        if last_recording is not None:
            clock += rng.uniform(30, 120) if recording == last_recording else rng.uniform(3600, 6 * 3600)
        last_recording = recording
        for k, (_, mi, members) in enumerate(by_clip[clip]):
            if k:
                clock += rng.uniform(3, 8)
            names = []
            order = list(members)
            rng.shuffle(order)
            for j, (kind, f) in enumerate(order):
                name = f"gp{next(ids)}.jpg"
                src = raw / f"{clip.replace('/', '_')}_{kind}_{f:06d}.png"
                with Image.open(src) as im:
                    buf = io.BytesIO()
                    im.convert("RGB").save(buf, "JPEG", quality=92)
                (img_dir / name).write_bytes(buf.getvalue())
                if j:
                    clock += rng.uniform(1, 2)
                times[name] = clock
                meta[name] = {"clip": clip, "moment": mi, "kind": kind, "frame": f,
                              "zip_member": f"{clip}/{kind}/{f:06d}.png"}
                clip_of[name] = clip
                names.append(name)
                if kind == "sharp":
                    best[str(len(groups))] = name
            groups.append(sorted(names, key=lambda n: times[n]))
    write_json(root / "gopro.json", {"frames": meta, "clips": clips})
    images = sorted(times)
    summary = write_dataset(
        root,
        name="gopro-bursts",
        kind="series",
        source=("GoPro deblurring dataset (S. Nah, T. H. Kim, K. M. Lee, 'Deep Multi-scale Convolutional Neural Network "
                "for Dynamic Scene Deblurring', CVPR 2017), GOPRO_Large.zip from https://huggingface.co/datasets/snah/GOPRO_Large"),
        license="CC-BY-4.0 (as tagged on the Hugging Face mirror); cite the paper",
        notes=(
            f"{len(clips)} clips x 2 moments (at {POSITIONS[0]:.0%} and {POSITIONS[1]:.0%} of the clip). Each moment = the "
            f"sharp frame i plus the blurred frames i, i+3, i+6 (each an average of 7-13 consecutive 240 fps frames: real "
            "camera shake and subject motion). best = the sharp frame. JPEG q92, 1280x720, neutral names (gopro.json). "
            "Pairs from the two moments of one clip are unscored (unscored_same: same scene a few seconds later, "
            "ambiguous). Never used to pick any threshold. TIMES ARE SYNTHESIZED: frames of a moment 1-2 s apart in "
            "random order, second moment 3-8 s later, clips of one recording 30-120 s apart, recordings 1-6 h apart."
        ),
        images=images,
        groups=groups,
        times=times,
        best=best,
        extra={"unscored_same": {"label": "clip", "of": clip_of}},
    )
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
