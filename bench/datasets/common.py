"""Shared helpers for building benchmark datasets in the bench format.

A dataset is a folder bench/data/<name>/ with:
  images/              flat folder of every image (unique names)
  truth.json           the shared ground truth (see README.md)
  images/truth.json    gtscan-compatible truth (series/best/singles)
  images/manifest.json gtscan-compatible capture dates
"""

from __future__ import annotations

import itertools
import json
import os
from datetime import datetime, timezone
from pathlib import Path

BENCH = Path(__file__).resolve().parent.parent
DATA = BENCH / "data"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic"}


def iso(ts: float) -> str:
    """Unix seconds -> ISO 8601 accepted by Swift's JSONDecoder .iso8601 (no fractional seconds)."""
    return datetime.fromtimestamp(int(round(ts)), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path: Path, obj) -> None:
    path.write_text(json.dumps(obj, indent=1, sort_keys=False) + "\n")


def write_dataset(
    root: Path,
    *,
    name: str,
    kind: str,
    source: str,
    license: str,
    notes: str,
    images: list[str],
    groups: list[list[str]],
    times: dict[str, float] | None = None,
    best: dict[str, str] | None = None,
    preferences: list[list[str]] | None = None,
    pair_agreement: dict[str, float] | None = None,
    extra: dict | None = None,
    write_gtscan: bool = True,
) -> dict:
    """Validate and write root/truth.json (and the gtscan copies in root/images/)."""
    img_dir = root / "images"
    on_disk = {p.name for p in img_dir.iterdir() if p.suffix.lower() in IMAGE_EXTS}
    images = sorted(images)
    assert len(set(images)) == len(images), "duplicate image names"
    missing = set(images) - on_disk
    assert not missing, f"images missing on disk: {sorted(missing)[:5]}"
    extra_files = on_disk - set(images)
    assert not extra_files, f"unlisted images on disk: {sorted(extra_files)[:5]}"
    seen: set[str] = set()
    for g in groups:
        assert len(g) >= 2, f"group of size {len(g)}"
        for f in g:
            assert f in on_disk, f
            assert f not in seen, f"{f} in two groups"
            seen.add(f)
    if times is not None:
        assert set(times) == set(images), "times must cover every image"
    best = best or {}
    for k, f in best.items():
        assert f in groups[int(k)], (k, f)
    truth = {
        "name": name,
        "kind": kind,
        "source": source,
        "license": license,
        "notes": notes,
        "images": images,
        "groups": groups,
    }
    if times is not None:
        truth["times"] = {f: float(times[f]) for f in images}
    if best:
        truth["best"] = best
    if preferences:
        truth["preferences"] = preferences
    if pair_agreement:
        truth["pair_agreement"] = pair_agreement
    if extra:
        truth.update(extra)
    write_json(root / "truth.json", truth)

    if write_gtscan:
        assert times is not None, "gtscan needs capture times"
        series = [{"files": g, "best": best.get(str(i), g[0])} for i, g in enumerate(groups)]
        singles = sorted(set(images) - seen)
        write_json(img_dir / "truth.json", {"series": series, "singles": singles})
        write_json(img_dir / "manifest.json", {"files": {f: {"date": iso(times[f])} for f in images}})
    return summarize(truth)


def summarize(truth: dict) -> dict:
    groups = truth["groups"]
    pos = sum(len(g) * (len(g) - 1) // 2 for g in groups)
    n = len(truth["images"])
    return {
        "name": truth["name"],
        "images": n,
        "groups": len(groups),
        "grouped_images": sum(len(g) for g in groups),
        "positive_pairs": pos,
        "negative_pairs": n * (n - 1) // 2 - pos,
        "has_times": "times" in truth,
        "has_preferences": bool(truth.get("preferences")),
    }


def pairs(group: list[str]):
    return itertools.combinations(sorted(group), 2)


def pair_key(a: str, b: str) -> str:
    a, b = sorted((a, b))
    return f"{a}|{b}"


def safe_name(s: str) -> str:
    keep = []
    for ch in s:
        keep.append(ch if (ch.isalnum() or ch in "-_.") else "-")
    return "".join(keep)


def link_or_copy(src: Path, dst: Path) -> None:
    if dst.exists():
        dst.unlink()
    try:
        os.link(src, dst)
    except OSError:
        import shutil

        shutil.copy2(src, dst)
