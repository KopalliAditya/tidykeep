"""Compute embeddings for benchmark datasets.

    bench/.venv/bin/python bench/embed.py --dataset <name|all|a,b> --method <name|all|a,b> [--force]
    bench/.venv/bin/python bench/embed.py --list

For each dataset bench/data/<name>/ (with truth.json) and method, writes
bench/out/<name>/<method>.npz (ids, X) and <method>.json (metric, dim, timing, licenses).
Datasets whose truth.json has variant_of (same images, other times) are skipped: evaluate.py
reads the embeddings of the dataset they are a variant of.
Existing outputs are kept unless --force. A failing method is reported and the rest carry on.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from embedders import METHODS, SKIPPED  # noqa: E402
from embedders.common import DATA, OUT, Context, output_paths, write_output  # noqa: E402


def variant_of(name: str) -> str | None:
    """Datasets that re-use another dataset's images (variant_of in truth.json) use its embeddings."""
    return json.loads((DATA / name / "truth.json").read_text()).get("variant_of")


def datasets(arg: str) -> list[str]:
    have = sorted(p.parent.name for p in DATA.glob("*/truth.json"))
    if arg == "all":
        return [d for d in have if not variant_of(d)]
    names = [a.strip() for a in arg.split(",") if a.strip()]
    unknown = [n for n in names if n not in have]
    if unknown:
        sys.exit(f"unknown dataset(s) {unknown}; have {have}")
    for n in names:
        if variant_of(n):
            sys.exit(f"{n} re-uses the images of {variant_of(n)}; embed that dataset instead")
    return names


def methods(arg: str) -> list[str]:
    if arg == "all":
        return list(METHODS)
    names = [a.strip() for a in arg.split(",") if a.strip()]
    unknown = [n for n in names if n not in METHODS and n not in SKIPPED]
    if unknown:
        sys.exit(f"unknown method(s) {unknown}; have {list(METHODS)}")
    return names


def list_methods() -> None:
    have = sorted(p.parent.name for p in DATA.glob("*/truth.json"))
    for name, m in METHODS.items():
        reason = m.available()
        done = [d for d in have if all(p.exists() for p in output_paths(d, name))]
        status = f"UNAVAILABLE: {reason}" if reason else f"done on {done}" if done else "not run"
        print(f"{name:20s} {m.metric:8s} {status}")
        print(f"{'':20s} {m.what}")
    for name, why in SKIPPED.items():
        print(f"{name:20s} SKIPPED: {why}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", default="all")
    ap.add_argument("--method", default="all")
    ap.add_argument("--force", action="store_true", help="recompute even if outputs exist")
    ap.add_argument("--device", default="auto", choices=["auto", "mps", "cpu"], help="for PyTorch methods")
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--timing-images", type=int, default=30, help="images timed at batch 1")
    ap.add_argument("--list", action="store_true", help="list methods and what has been run")
    args = ap.parse_args()
    if args.list:
        list_methods()
        return 0

    failures = []
    for ds in datasets(args.dataset):
        truth = json.loads((DATA / ds / "truth.json").read_text())
        paths = [DATA / ds / "images" / f for f in truth["images"]]
        missing = [p.name for p in paths if not p.exists()]
        if missing:
            print(f"[{ds}] images missing on disk: {missing[:5]}; skipping dataset", file=sys.stderr)
            failures.append((ds, "*"))
            continue
        for name in methods(args.method):
            if name in SKIPPED:
                print(f"[{ds}] {name}: skipped ({SKIPPED[name]})")
                continue
            m = METHODS[name]
            npz, side = output_paths(ds, name)
            if npz.exists() and side.exists() and not args.force:
                print(f"[{ds}] {name}: exists, skipping (use --force)")
                continue
            reason = m.available()
            if reason:
                print(f"[{ds}] {name}: unavailable ({reason})")
                failures.append((ds, name))
                continue
            ctx = Context(dataset=ds, paths=paths, out_dir=OUT / ds, device=args.device, batch=args.batch,
                          timing_images=args.timing_images)
            t = time.perf_counter()
            try:
                res = m.run(ctx)
                write_output(ctx, m, res)
            except Exception as e:
                traceback.print_exc()
                print(f"[{ds}] {name}: FAILED: {e}", file=sys.stderr)
                failures.append((ds, name))
                continue
            print(f"[{ds}] {name}: {len(paths)} images, dim {res.X.shape[1]}, {res.ms_per_image:.2f} ms/img "
                  f"on {res.device}, {time.perf_counter() - t:.1f}s total")
    if failures:
        print(f"failed: {failures}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
