"""copies: the "same photo saved twice" duplicates phones accumulate (not bursts).

Originals are real personal photos: one photo from each of N_CANDIDATES random series of the
Photo Triage TRAIN split (Chang et al., SIGGRAPH 2016; Kaggle mirror ericwolter/triage). The
photo-triage benchmark uses the validation/test splits, so the two sets share no photos.
California-ND singles were the first choice but its photos are password-protected, and the
macOS system pictures are too few for 300 distinct originals (43 user pictures + 32 desktop
image files, many of them abstract wallpapers).

Half of the originals get 1-3 copies, each made with a different transform picked at random
(fixed seed) from transforms that model real sources:
  reencode    JPEG q70, long side capped at 1600 px (messaging apps; the sources here are about
              0.6 MP with a long side of 614-1200 px, so in practice this only re-encodes)
  heic_jpeg   format round trip with macOS sips: JPEG original -> HEIC copy, HEIC original ->
              JPEG copy (about a third of the originals are stored as HEIC, like iPhone captures)
  screenshot  photo letterboxed into a 1179x2556 portrait canvas with a plain status-bar strip
              and bottom toolbar, light or dark, saved as PNG
  crop        5-15% cut off the edges (straighten/crop in the editor)
  color       saturation +30% and a warm white balance shift
  downscale   long side 640 px (or 75% of the original if it is already <= 640 px)
  rotate      2-3 degrees either way, cropped to the largest upright rectangle
  mirror      horizontal flip (front-camera selfie)
The other half are distractors with no copies. Candidates whose 64-bit DCT perceptual hash is
within DEDUP_BITS of another candidate are dropped first, so distractors are not accidental
near-duplicates of each other.

Times: originals and distractors spread over 6 months; each copy is made 1 hour to 3 weeks
(log-uniform) after its original, so a capture-time window cannot pair them.
Every copy's original, transform and parameters are in copies.json, plus pair_transforms: for
each positive pair, the copy's transform (original|copy) or "t1+t2" (copy|copy).

    bench/.venv/bin/python bench/datasets/build_copies.py [--force]
"""

from __future__ import annotations

import argparse
import json
import math
import random
import shutil
import subprocess
import zipfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import imagehash
import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageOps

from build_photo_triage import RAW as PT_RAW, fetch_meta, signed_url
from common import DATA, pair_key, write_dataset, write_json
from remotezip import HTTPRangeFile

SEED = 1729
N_ORIG = 150
N_DISTRACT = 150
N_CANDIDATES = 380
DEDUP_BITS = 14
HEIC_ORIG_SHARE = 1 / 3
START = 1_735_689_600  # 2025-01-01T00:00:00Z
SPREAD = 182 * 86400
TRANSFORMS = ["reencode", "heic_jpeg", "screenshot", "crop", "color", "downscale", "rotate", "mirror"]


# ---------------------------------------------------------------- transforms


def save_jpeg(im: Image.Image, path: Path, q: int) -> None:
    im.convert("RGB").save(path, "JPEG", quality=q, optimize=True)


def t_reencode(im, rng):
    w, h = im.size
    s = min(1.0, 1600 / max(w, h))
    if s < 1:
        im = im.resize((round(w * s), round(h * s)), Image.LANCZOS)
    return im, {"quality": 70, "max_side": 1600}, ("jpg", 70)


def t_screenshot(im, rng):
    W, H = 1179, 2556
    dark = rng.random() < 0.6
    bg = (0, 0, 0) if dark else (255, 255, 255)
    fg = (255, 255, 255) if dark else (0, 0, 0)
    bar = (18, 18, 18) if dark else (246, 246, 246)
    canvas = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(canvas)
    top, bottom = 162, 249
    d.rectangle([0, 0, W, top], fill=bar)
    d.rectangle([0, H - bottom, W, H], fill=bar)
    # status bar: a clock block on the left, signal/battery blocks on the right
    d.rounded_rectangle([90, 62, 230, 104], 10, fill=fg)
    d.rounded_rectangle([W - 250, 66, W - 190, 100], 6, fill=fg)
    d.rounded_rectangle([W - 160, 64, W - 80, 102], 10, outline=fg, width=5)
    d.rectangle([W - 152, 72, W - 100, 94], fill=fg)
    # toolbar: four icon blocks and a home indicator
    for k in range(4):
        cx = int(W * (k + 0.5) / 4)
        d.rounded_rectangle([cx - 30, H - bottom + 40, cx + 30, H - bottom + 100], 12, outline=fg, width=6)
    d.rounded_rectangle([W // 2 - 200, H - 30, W // 2 + 200, H - 18], 6, fill=fg)
    area_h = H - top - bottom
    w, h = im.size
    s = min(W / w, area_h / h)
    nw, nh = round(w * s), round(h * s)
    canvas.paste(im.convert("RGB").resize((nw, nh), Image.LANCZOS), ((W - nw) // 2, top + (area_h - nh) // 2))
    return canvas, {"canvas": [W, H], "dark": dark, "photo_box": [(W - nw) // 2, top + (area_h - nh) // 2, nw, nh]}, ("png", None)


def t_crop(im, rng):
    w, h = im.size
    fx, fy = rng.uniform(0.05, 0.15), rng.uniform(0.05, 0.15)
    lx, ty = rng.uniform(0, 1), rng.uniform(0, 1)
    left, top = round(w * fx * lx), round(h * fy * ty)
    right, bot = w - round(w * fx * (1 - lx)), h - round(h * fy * (1 - ty))
    return im.crop((left, top, right, bot)), {"cut_x": round(fx, 3), "cut_y": round(fy, 3), "box": [left, top, right, bot]}, ("jpg", 90)


def t_color(im, rng):
    im = ImageEnhance.Color(im.convert("RGB")).enhance(1.3)
    a = np.asarray(im).astype(np.float32)
    warm = rng.uniform(0.06, 0.10)
    a[..., 0] *= 1 + warm
    a[..., 1] *= 1 + warm / 3
    a[..., 2] *= 1 - warm
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    return im, {"saturation": 1.3, "warmth": round(warm, 3)}, ("jpg", 92)


def t_downscale(im, rng):
    w, h = im.size
    side = 640 if max(w, h) > 640 else round(0.75 * max(w, h))  # never upscale
    s = side / max(w, h)
    return im.resize((round(w * s), round(h * s)), Image.LANCZOS), {"max_side": side}, ("jpg", 85)


def largest_rotated_rect(w: float, h: float, angle: float) -> tuple[float, float]:
    """Largest axis-aligned rectangle inside a w x h rectangle rotated by angle (radians)."""
    if w <= 0 or h <= 0:
        return 0, 0
    long, short = (w, h) if w >= h else (h, w)
    s, c = abs(math.sin(angle)), abs(math.cos(angle))
    if short <= 2 * s * c * long or abs(s - c) < 1e-10:
        x = 0.5 * short
        wr, hr = (x / s, x / c) if w >= h else (x / c, x / s)
    else:
        cos2 = c * c - s * s
        wr, hr = (w * c - h * s) / cos2, (h * c - w * s) / cos2
    return wr, hr


def t_rotate(im, rng):
    deg = rng.uniform(2, 3) * rng.choice([-1, 1])
    w, h = im.size
    r = im.convert("RGB").rotate(deg, resample=Image.BICUBIC, expand=True)
    wr, hr = largest_rotated_rect(w, h, math.radians(deg))
    cx, cy = r.size[0] / 2, r.size[1] / 2
    box = (round(cx - wr / 2), round(cy - hr / 2), round(cx + wr / 2), round(cy + hr / 2))
    return r.crop(box), {"degrees": round(deg, 2)}, ("jpg", 90)


def t_mirror(im, rng):
    return ImageOps.mirror(im), {}, ("jpg", 92)


PIXEL_T = {
    "reencode": t_reencode,
    "screenshot": t_screenshot,
    "crop": t_crop,
    "color": t_color,
    "downscale": t_downscale,
    "rotate": t_rotate,
    "mirror": t_mirror,
}


def sips_convert(src: Path, dst: Path, fmt: str) -> None:
    cmd = ["sips", "-s", "format", fmt]
    if fmt in ("heic", "jpeg"):
        cmd += ["-s", "formatOptions", "80" if fmt == "heic" else "85"]
    subprocess.run(cmd + [str(src), "--out", str(dst)], check=True, capture_output=True)


# ---------------------------------------------------------------- build


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    root = DATA / "copies"
    if (root / "truth.json").exists() and not args.force:
        print(f"{root} exists; use --force to rebuild")
        return
    rng = random.Random(SEED)

    # 1. candidate originals: one photo from each of N_CANDIDATES random train series
    url = signed_url()
    names = fetch_meta(url)
    train_ids = sorted({int(l.split()[0]) for l in (PT_RAW / "train_val/train_pairlist.txt").read_text().splitlines() if l.strip()})
    by_series: dict[int, list[str]] = {}
    for n in names:
        if n.startswith("train_val/train_val_imgs/") and n.lower().endswith(".jpg"):
            by_series.setdefault(int(n.rsplit("/", 1)[1].split("-")[0]), []).append(n)
    picked = sorted(rng.sample(train_ids, N_CANDIDATES))
    cand_members = {sid: rng.choice(sorted(by_series[sid])) for sid in picked}
    cache = DATA / "_raw" / "copies-sources"
    cache.mkdir(parents=True, exist_ok=True)
    todo = [(m, cache / Path(m).name) for m in cand_members.values() if not (cache / Path(m).name).exists()]
    if todo:
        threads = 8
        chunks = [todo[i::threads] for i in range(threads)]

        def work(chunk):
            z = zipfile.ZipFile(HTTPRangeFile(url))
            for m, d in chunk:
                d.with_suffix(".part").write_bytes(z.read(m))
                d.with_suffix(".part").rename(d)

        with ThreadPoolExecutor(threads) as ex:
            list(ex.map(work, chunks))
        print(f"fetched {len(todo)} source photos")

    # 2. drop candidates that look like another candidate
    srcs = [cache / Path(cand_members[s]).name for s in picked]
    hashes = [imagehash.phash(ImageOps.exif_transpose(Image.open(p))) for p in srcs]
    kept, dropped = [], []
    for i, p in enumerate(srcs):
        if any(hashes[i] - hashes[j] <= DEDUP_BITS for j in kept):
            dropped.append(p.name)
        else:
            kept.append(i)
    need = N_ORIG + N_DISTRACT
    assert len(kept) >= need, f"only {len(kept)} distinct candidates"
    chosen = [srcs[i] for i in rng.sample(kept, need)]
    with_copies, distractors = chosen[:N_ORIG], chosen[N_ORIG:]
    print(f"{len(dropped)} candidates dropped as look-alikes")

    # 3. write images
    img_dir = root / "images"
    if root.exists():
        shutil.rmtree(root)
    img_dir.mkdir(parents=True)
    ids = rng.sample(range(10000, 99999), 4 * need)  # neutral names: transform not visible in the name
    next_id = iter(ids)
    times, groups, best, copies = {}, [], {}, {}
    transform_counts, n_copies_hist = Counter(), Counter()
    source_of = {}
    for role, sources in (("original", with_copies), ("distractor", distractors)):
        for src in sources:
            im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
            stem = f"cp{next(next_id)}"
            as_heic = rng.random() < HEIC_ORIG_SHARE
            t0 = START + rng.uniform(0, SPREAD)
            if as_heic:
                orig_name = stem + ".heic"
                sips_convert(src, img_dir / orig_name, "heic")
            else:
                orig_name = stem + ".jpg"
                shutil.copyfile(src, img_dir / orig_name)
            times[orig_name] = t0
            source_of[orig_name] = {"role": role, "photo_triage_file": "train_val/train_val_imgs/" + src.name}
            if role == "distractor":
                continue
            k = rng.choice([1, 2, 3])
            n_copies_hist[k] += 1
            members = [orig_name]
            for tname in rng.sample(TRANSFORMS, k):
                cstem = f"cp{next(next_id)}"
                if tname == "heic_jpeg":
                    if as_heic:
                        cname, params = cstem + ".jpg", {"from": "heic", "to": "jpeg", "quality": 85}
                        sips_convert(img_dir / orig_name, img_dir / cname, "jpeg")
                    else:
                        cname, params = cstem + ".heic", {"from": "jpeg", "to": "heic", "quality": 80}
                        sips_convert(img_dir / orig_name, img_dir / cname, "heic")
                else:
                    out, params, (ext, q) = PIXEL_T[tname](im, rng)
                    cname = f"{cstem}.{ext}"
                    if ext == "png":
                        out.convert("RGB").save(img_dir / cname, "PNG", optimize=True)
                    else:
                        save_jpeg(out, img_dir / cname, q)
                delay = math.exp(rng.uniform(math.log(3600), math.log(21 * 86400)))
                times[cname] = t0 + delay
                copies[cname] = {"original": orig_name, "transform": tname, "params": params,
                                 "delay_hours": round(delay / 3600, 1)}
                transform_counts[tname] += 1
                members.append(cname)
            best[str(len(groups))] = orig_name
            groups.append(members)

    # every positive pair labelled by what separates the two files: the copy's transform for
    # original|copy, "t1+t2" (sorted) for copy|copy
    pair_transforms = {}
    for g in groups:
        for i, a in enumerate(g):
            for b in g[i + 1:]:
                ts = sorted(copies[f]["transform"] for f in (a, b) if f in copies)
                pair_transforms[pair_key(a, b)] = "+".join(ts)
    write_json(root / "copies.json", {
        "copies": copies,
        "pair_transforms": pair_transforms,
        "originals": source_of,
        "transform_counts": dict(transform_counts),
        "copies_per_original": {str(k): v for k, v in sorted(n_copies_hist.items())},
        "dropped_lookalike_candidates": dropped,
    })
    images = sorted(times)
    summary = write_dataset(
        root,
        name="copies",
        kind="copies",
        source=(
            "Synthetic copies of real personal photos from the Photo Triage train split (Chang et al., SIGGRAPH 2016; "
            "https://www.kaggle.com/datasets/ericwolter/triage), built by bench/datasets/build_copies.py"
        ),
        license="Derived from Photo Triage images (research use, (c) original owners). Local evaluation only; do not redistribute.",
        notes=(
            f"{N_ORIG} originals with 1-3 copies each (one transform per copy, seed {SEED}; counts {dict(transform_counts)}) "
            f"and {N_DISTRACT} distractor originals with none. Groups = original + its copies; best = the original. "
            f"Transforms: reencode (JPEG q70, <=1600 px), heic_jpeg (sips format round trip), screenshot "
            "(1179x2556 PNG with status/tool bars), crop (5-15% per axis), color (saturation x1.3 + warm shift), "
            "downscale (640 px long side, never up), rotate (2-3 deg + crop), mirror (horizontal). About a third of the originals are "
            "HEIC. Times synthesized: originals over 6 months from 2025-01-01, copies 1 h - 21 days later "
            "(log-uniform). Sources are the dataset's ~0.6 MP JPEGs (long side 614-1200 px), so no copy is upscaled. Candidates within "
            f"{DEDUP_BITS} bits (pHash 64) of another candidate were dropped ({len(dropped)}). Per-copy details in copies.json."
        ),
        images=images,
        groups=groups,
        times=times,
        best=best,
    )
    print(json.dumps(summary, indent=1))
    print("copies per original", dict(n_copies_hist), "transforms", dict(transform_counts))


if __name__ == "__main__":
    main()
