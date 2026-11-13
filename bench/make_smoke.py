"""smoke: a tiny dataset for checking that every embedding method runs and makes sense.

12 macOS account pictures (/Library/User Pictures, two per category), 3 transformed copies
of three of them (JPEG re-encode at low quality, a center crop, a mirror image), and one
two-frame near-duplicate made from a 13th picture (a small reframe, then the second frame is
a little brighter and softer). 17 images, 4 groups. Capture times are synthesized: sources an
hour apart, each copy 2 s after its original, the two frames 1 s apart.

    bench/.venv/bin/python bench/make_smoke.py [--force]
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent / "datasets"))
from common import DATA, safe_name, write_dataset  # noqa: E402

import pillow_heif  # noqa: E402

pillow_heif.register_heif_opener()

SOURCES = Path("/Library/User Pictures")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    root = DATA / "smoke"
    if root.exists():
        if not args.force:
            print(f"{root} exists; use --force to rebuild")
            return
        shutil.rmtree(root)
    images = root / "images"
    images.mkdir(parents=True)

    cats = sorted(p for p in SOURCES.iterdir() if p.is_dir())
    picks = [f for c in cats for f in sorted(c.glob("*.heic"))[:2]]
    assert len(picks) == 12, picks
    extra = sorted((SOURCES / "Nature").glob("*.heic"))[2]  # not among the 12

    t0 = 1_767_225_600.0  # 2026-01-01
    names, times, groups, best = [], {}, [], {}

    def add(name: str, t: float) -> str:
        names.append(name)
        times[name] = t
        return name

    for i, src in enumerate(picks):
        name = safe_name(f"{src.parent.name}-{src.stem}.heic")
        shutil.copyfile(src.resolve(), images / name)
        add(name, t0 + i * 3600)

    def copy_of(orig: str, suffix: str, im: Image.Image, **save) -> None:
        name = orig.rsplit(".", 1)[0] + f"_{suffix}.jpg"
        im.convert("RGB").save(images / name, "JPEG", **save)
        add(name, times[orig] + 2)
        best[str(len(groups))] = orig
        groups.append([orig, name])

    def load(name: str) -> Image.Image:
        return ImageOps.exif_transpose(Image.open(images / name)).convert("RGB")

    a, b, c = names[0], names[2], names[6]
    copy_of(a, "reencode", load(a), quality=35)
    im = load(b)
    w, h = im.size
    copy_of(b, "crop", im.crop((int(w * 0.12), int(h * 0.12), int(w * 0.88), int(h * 0.88))), quality=92)
    copy_of(c, "mirror", ImageOps.mirror(load(c)), quality=92)

    im = ImageOps.exif_transpose(Image.open(extra)).convert("RGB")
    w, h = im.size
    f1 = im.crop((0, 0, int(w * 0.94), int(h * 0.94)))
    f2 = im.crop((int(w * 0.04), int(h * 0.03), int(w * 0.98), int(h * 0.97)))
    f2 = ImageEnhance.Brightness(f2).enhance(1.06).filter(ImageFilter.GaussianBlur(1.2))
    stem = safe_name(f"{extra.parent.name}-{extra.stem}")
    n1, n2 = f"{stem}_frame1.jpg", f"{stem}_frame2.jpg"
    f1.save(images / n1, "JPEG", quality=92)
    f2.save(images / n2, "JPEG", quality=92)
    add(n1, t0 + len(picks) * 3600)
    add(n2, t0 + len(picks) * 3600 + 1)
    best[str(len(groups))] = n1
    groups.append([n1, n2])

    summary = write_dataset(
        root,
        name="smoke",
        kind="copies",
        source="macOS account pictures, /Library/User Pictures (system images shipped with macOS)",
        license="Apple macOS system images; local benchmarking only, do not redistribute",
        notes="Smoke test for bench/embed.py: 3 transformed copies (re-encode q35, 76% center crop, "
        "mirror) and one synthetic two-frame near-duplicate (reframe, +6% brightness, blur 1.2 px). "
        "Times synthesized. Built by bench/make_smoke.py.",
        images=names,
        groups=groups,
        times=times,
        best=best,
    )
    print(summary)


if __name__ == "__main__":
    main()
