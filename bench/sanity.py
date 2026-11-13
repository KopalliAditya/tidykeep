"""Quick check of embeddings against truth.json: are duplicates closer than unrelated pairs?

    bench/.venv/bin/python bench/sanity.py [--dataset smoke] [--method all] [--pairs]

Per method: pair AUC (chance that a duplicate pair is closer than a non-duplicate pair),
how many grouped images have their nearest neighbor in their own group, the farthest duplicate pair and the
closest non-duplicate pair. Distances: cosine distance (1 - cos), Euclidean, or Hamming bits.
This is a sanity check, not the benchmark's scoring.
"""

from __future__ import annotations

import argparse
import itertools
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from embedders.common import DATA, OUT  # noqa: E402


def distances(X: np.ndarray, metric: str) -> np.ndarray:
    if metric == "cosine":
        X = X / np.maximum(np.linalg.norm(X, axis=1, keepdims=True), 1e-12)
        return 1 - X @ X.T
    if metric == "l2":
        sq = (X * X).sum(1)
        return np.sqrt(np.maximum(sq[:, None] + sq[None, :] - 2 * X @ X.T, 0))
    if metric == "hamming":
        B = X.astype(np.int32)
        return (B[:, None, :] != B[None, :, :]).sum(-1).astype(np.float64)
    raise ValueError(metric)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="smoke")
    ap.add_argument("--method", default="all")
    ap.add_argument("--pairs", action="store_true", help="print every duplicate pair's distance")
    args = ap.parse_args()
    truth = json.loads((DATA / args.dataset / "truth.json").read_text())
    ids = truth["images"]
    index = {f: i for i, f in enumerate(ids)}
    pos = [(index[a], index[b]) for files in truth["groups"] for a, b in itertools.combinations(files, 2)]
    group = {index[f]: g for g, files in enumerate(truth["groups"]) for f in files}
    pos_set = set(pos) | {(b, a) for a, b in pos}
    neg = [(i, j) for i, j in itertools.combinations(range(len(ids)), 2) if (i, j) not in pos_set]

    sides = [s for s in sorted((OUT / args.dataset).glob("*.json")) if s.with_suffix(".npz").exists()]
    if args.method != "all":
        wanted = set(args.method.split(","))
        sides = [s for s in sides if s.stem in wanted]
    print(f"{args.dataset}: {len(ids)} images, {len(pos)} duplicate pairs, {len(neg)} other pairs")
    print(f"{'method':20s} {'metric':7s} {'AUC':>6s} {'NN ok':>6s} {'max dup':>8s} {'min other':>9s}  separated")
    for side in sides:
        meta = json.loads(side.read_text())
        z = np.load(side.with_suffix(".npz"), allow_pickle=False)
        assert list(z["ids"]) == ids, f"{side.stem}: ids differ from truth.json images"
        D = distances(z["X"], meta["metric"])
        dp = np.array([D[i, j] for i, j in pos])
        dn = np.array([D[i, j] for i, j in neg])
        auc = ((dp[:, None] < dn[None, :]).sum() + 0.5 * (dp[:, None] == dn[None, :]).sum()) / (len(dp) * len(dn))
        Dn = D + np.diag(np.full(len(ids), np.inf))
        nn_ok = sum(int(group.get(int(np.argmin(Dn[i]))) == g) for i, g in group.items())
        sep = "yes" if dp.max() < dn.min() else "no"
        print(f"{side.stem:20s} {meta['metric']:7s} {auc:6.3f} {nn_ok:3d}/{len(group):<3d} {dp.max():8.3f} {dn.min():9.3f}  {sep}")
        if args.pairs:
            for (i, j), d in zip(pos, dp):
                closer = int((dn < d).sum())
                print(f"    {d:7.3f}  {ids[i]} ~ {ids[j]}  ({closer} other pairs closer)")


if __name__ == "__main__":
    main()
