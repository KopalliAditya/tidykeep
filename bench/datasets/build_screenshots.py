"""screenshots: real app screenshots, where screenshots of different screens must not match.

Source: Rico (B. Deka et al., "Rico: A Mobile App Dataset for Building Data-Driven Design
Applications", UIST 2017), Android app screens at 1080x1920, via the Screen2Words release
mirrored at https://huggingface.co/datasets/bevaya/RICO-Screen2Words (tagged CC-BY-4.0). One
parquet shard (data/test-00000-of-00002.parquet, 2,155 screens of 653 apps) is downloaded.

N_APPS apps with at least two screens are drawn with a fixed seed and up to 3 screens of each
are kept, so many unrelated pairs are two screens of the same app (same bars, colors and
layout, different content): the hard negatives a copy detector must keep apart. N_COPIES of the
screenshots get one copy each, so there are true duplicates too:
  resave        JPEG q70 at 60% size (sent through a messaging app)
  heic          format round trip with macOS sips (JPEG -> HEIC q80)
  crop_bars     status bar and navigation bar cropped off (top 63 px, bottom 126 px)
  rescreenshot  a screenshot of the screenshot shown full-screen on an iPhone: letterboxed into
                1179x2556 on black with a status-bar strip and a toolbar, PNG
Groups = screenshot + its copy; best = the screenshot. app_of maps every file to its app.

Times are SYNTHESIZED: the screens of one app 5-40 s apart (one session), sessions 1-48 h
apart, each copy 1 h - 21 days after its screenshot.

    bench/.venv/bin/python bench/datasets/build_screenshots.py [--force]
"""

from __future__ import annotations

import argparse
import io
import json
import math
import random
import shutil
import subprocess
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

from PIL import Image, ImageDraw

from common import DATA, pair_key, write_dataset, write_json

URL = "https://huggingface.co/datasets/bevaya/RICO-Screen2Words/resolve/main/data/test-00000-of-00002.parquet"
SEED = 1080
N_APPS = 120
PER_APP = 3
N_COPIES = 100
START = 1_751_328_000  # 2025-07-01T00:00:00Z
TRANSFORMS = ["resave", "heic", "crop_bars", "rescreenshot"]


def rescreenshot(im: Image.Image) -> Image.Image:
    W, H = 1179, 2556
    canvas = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(canvas)
    top, bottom = 162, 249
    d.rectangle([0, 0, W, top], fill=(18, 18, 18))
    d.rectangle([0, H - bottom, W, H], fill=(18, 18, 18))
    fg = (255, 255, 255)
    d.rounded_rectangle([90, 62, 230, 104], 10, fill=fg)
    d.rounded_rectangle([W - 160, 64, W - 80, 102], 10, outline=fg, width=5)
    for k in range(4):
        cx = int(W * (k + 0.5) / 4)
        d.rounded_rectangle([cx - 30, H - bottom + 40, cx + 30, H - bottom + 100], 12, outline=fg, width=6)
    area_h = H - top - bottom
    w, h = im.size
    s = min(W / w, area_h / h)
    nw, nh = round(w * s), round(h * s)
    canvas.paste(im.convert("RGB").resize((nw, nh), Image.LANCZOS), ((W - nw) // 2, top + (area_h - nh) // 2))
    return canvas


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    root = DATA / "screenshots"
    if (root / "truth.json").exists() and not args.force:
        print(f"{root} exists; use --force to rebuild")
        return
    import pyarrow.parquet as pq

    raw = DATA / "_raw" / "rico"
    raw.mkdir(parents=True, exist_ok=True)
    shard = raw / URL.rsplit("/", 1)[1]
    if not shard.exists():
        urllib.request.urlretrieve(URL, shard.with_suffix(".part"))
        shard.with_suffix(".part").rename(shard)
    t = pq.read_table(shard, columns=["screenId", "app_package_name", "category", "image"])
    rows = defaultdict(list)
    for sid, app, cat, img in zip(*(t.column(c).to_pylist() for c in ("screenId", "app_package_name", "category", "image"))):
        rows[app].append((sid, cat, img["bytes"]))
    rng = random.Random(SEED)
    apps = sorted(a for a, v in rows.items() if len(v) >= 2)
    picked = sorted(rng.sample(apps, N_APPS))

    if root.exists():
        shutil.rmtree(root)
    img_dir = root / "images"
    img_dir.mkdir(parents=True)
    ids = iter(rng.sample(range(10000, 99999), 2 * N_APPS * PER_APP + N_COPIES))
    times, app_of, source, shots = {}, {}, {}, []
    clock = float(START)
    sizes = Counter()
    for app in picked:
        screens = sorted(rows[app])
        screens = sorted(rng.sample(screens, min(PER_APP, len(screens))))
        clock += rng.uniform(3600, 48 * 3600)
        for k, (sid, cat, data) in enumerate(screens):
            if k:
                clock += rng.uniform(5, 40)
            name = f"ss{next(ids)}.jpg"
            (img_dir / name).write_bytes(data)  # the release's JPEG bytes, untouched
            with Image.open(io.BytesIO(data)) as im:
                sizes[im.size] += 1
            times[name], app_of[name] = clock, app
            source[name] = {"rico_screen_id": sid, "app": app, "category": cat}
            shots.append(name)

    originals = sorted(rng.sample(shots, N_COPIES))
    kinds = [TRANSFORMS[i % len(TRANSFORMS)] for i in range(N_COPIES)]
    rng.shuffle(kinds)
    groups, best, copies = [], {}, {}
    for orig, kind in zip(originals, kinds):
        im = Image.open(img_dir / orig).convert("RGB")
        stem = f"ss{next(ids)}"
        if kind == "resave":
            name = stem + ".jpg"
            w, h = im.size
            im.resize((round(w * 0.6), round(h * 0.6)), Image.LANCZOS).save(img_dir / name, "JPEG", quality=70)
        elif kind == "heic":
            name = stem + ".heic"
            subprocess.run(["sips", "-s", "format", "heic", "-s", "formatOptions", "80", str(img_dir / orig),
                            "--out", str(img_dir / name)], check=True, capture_output=True)
        elif kind == "crop_bars":
            name = stem + ".jpg"
            w, h = im.size
            top, bottom = round(63 * h / 1920), round(126 * h / 1920)
            im.crop((0, top, w, h - bottom)).save(img_dir / name, "JPEG", quality=90)
        else:
            name = stem + ".png"
            rescreenshot(im).save(img_dir / name, "PNG", optimize=True)
        delay = math.exp(rng.uniform(math.log(3600), math.log(21 * 86400)))
        times[name] = times[orig] + delay
        app_of[name] = app_of[orig]
        copies[name] = {"original": orig, "transform": kind, "delay_hours": round(delay / 3600, 1)}
        best[str(len(groups))] = orig
        groups.append([orig, name])
    pair_transforms = {pair_key(g[0], g[1]): copies[g[1]]["transform"] for g in groups}
    write_json(root / "screenshots.json", {"screens": source, "copies": copies, "pair_transforms": pair_transforms,
                                           "transform_counts": dict(Counter(kinds)),
                                           "sizes": {f"{w}x{h}": n for (w, h), n in sizes.items()}})
    n_same_app = sum(v * (v - 1) // 2 for v in Counter(app_of.values()).values()) - len(groups)
    summary = write_dataset(
        root,
        name="screenshots",
        kind="copies",
        source=("Rico (B. Deka et al., UIST 2017) screens via the Screen2Words mirror "
                "https://huggingface.co/datasets/bevaya/RICO-Screen2Words (data/test-00000-of-00002.parquet)"),
        license="CC-BY-4.0 as tagged on the Hugging Face mirror (Rico / Screen2Words); app UIs (c) their developers",
        notes=(
            f"{len(shots)} real Android screenshots of {N_APPS} apps (up to {PER_APP} screens per app, seed {SEED}), "
            f"{N_COPIES} of them with one copy each ({dict(Counter(kinds))}): resave = JPEG q70 at 60%, heic = sips "
            "round trip, crop_bars = status and navigation bars cut off, rescreenshot = shown full-screen on an iPhone "
            f"and screenshotted (1179x2556 PNG on black). {n_same_app} unrelated pairs are two different screens of the "
            "same app (hard negatives; app_of). TIMES ARE SYNTHESIZED: an app's screens 5-40 s apart, sessions 1-48 h "
            "apart, copies 1 h - 21 days later."
        ),
        images=sorted(times),
        groups=groups,
        times=times,
        best=best,
        extra={"app_of": app_of},
    )
    print(json.dumps(summary, indent=1), dict(sizes))


if __name__ == "__main__":
    main()
