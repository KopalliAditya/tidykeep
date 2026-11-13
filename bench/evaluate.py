"""Score the duplicate-photo benchmark: every method on every dataset, and the app itself.

    bench/.venv/bin/python bench/evaluate.py [--datasets a,b] [--methods a,b] [--boot 1000] [--force-app] [--skip-app]

Reads bench/data/<ds>/truth.json and bench/out/<ds>/<method>.npz + .json (written by embed.py).
Runs gtscan for the app pipeline and the best-shot ranking; its outputs are cached in
bench/out/<ds>/app/ (--force-app reruns them). Writes bench/out/results.json (everything) and
bench/out/tables.md (the tables in RESULTS.md).

1. Pair metrics, global: every pair of images in a dataset, capture time ignored. Distance is the
   duplicate score (smaller = more alike). Average precision (PR-AUC), ROC-AUC, recall at
   precision >= 0.99 and >= 0.95, and best F1. The last three pick their threshold on the dataset
   itself, so they are ORACLE numbers, for reference only. 95% bootstrap CIs resample groups
   (each single is a group of one), with the same resamples for every method so differences
   against the app's signal and against the top method are paired.
2. Threshold transfer (nothing tuned on what is reported): the groups and singles of
   bursts-profile and copies are split 50/50 with a fixed seed. One threshold per method is picked
   on the pooled dev halves (the largest distance with precision >= 0.99 there), then applied
   unchanged to the test halves and to every other dataset. Pair-level precision/recall, and
   group-level results after single-linkage clustering at that threshold. For copies, recall is
   broken down by transform.
3. Fusion: logistic regression on two methods' distances, fitted on the dev halves only, scored on
   the test halves and the other datasets.
4. App pipeline: `gtscan eval` and `gtscan scan --json` (capture-time window included) at strict and
   balanced (and loose for copies), with a breakdown of what the time window never looks at.
5. Best shot: `gtscan rank` (the app's ShotScorer) against human preferences and known best frames,
   compared with random, capture order, sharpness alone, Vision aesthetics alone and the LAION
   aesthetic predictor (bench/aesthetic.py).
6. Integrity: ids match truth.json, distance matrices are symmetric with a zero diagonal, cosine
   inputs are unit vectors, hashes are 0/1 bits, AP/AUC match scikit-learn, byte-identical and
   near-identical images across datasets.
7. Time window: every embedding put through the app's grouping step (series_port.py, a port of
   SeriesBuilder + Scanner.groups checked group for group against gtscan), with its link distance
   calibrated two ways (the transfer threshold; and a sweep on the dev half of photo-triage-tight,
   real series packed minutes apart), plus `gtscan eval --features` runs with other embeddings.
8. Copy pass: library-wide linking without the window, with single, complete and mutual-nearest-
   neighbour linkage and a separate threshold for screen-shaped pairs.

Datasets whose truth.json has variant_of (photo-triage-tight) share another dataset's images and
embeddings and differ only in capture times, so they enter the time-window sections only. Pairs
marked unscored_same (gopro-bursts: two moments of one clip) are left out of every pair metric and
counted separately.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

BENCH = Path(__file__).resolve().parent
DATA = BENCH / "data"
OUT = BENCH / "out"
GTSCAN = BENCH.parent / "GoodTakeKit" / ".build" / "release" / "gtscan"

DEFAULT_DATASETS = ("bursts-profile", "photo-triage", "copies", "gopro-bursts", "screenshots", "photo-triage-tight",
                    "california-nd")
DEV_DATASETS = ("bursts-profile", "copies")  # their dev halves pick the transfer threshold
SPLIT_SEED = 2026
BOOT_SEED = 1729
TARGET_PRECISION = 0.99
APP = "apple-fp2-soft"  # the app's grouping signal, the reference for paired differences
# The app's sensitivity presets (GoodTakeCore/Models.swift): maxGap s, maxSpan s, link, anchor.
SENSITIVITY = {"strict": (30, 120, 0.40, 0.50), "balanced": (60, 240, 0.55, 0.65), "loose": (180, 900, 0.70, 0.80)}
APP_RUNS = {"copies": ("strict", "balanced", "loose"), "screenshots": ("strict", "balanced", "loose")}  # others: 2
FPR_LEVELS = (1e-2, 1e-3, 1e-4)  # recall at these false-positive rates
# In the time window every embedding is stored and compared as the app does it: int8
# QuantizedEmbedding, Euclidean distance (unit vectors: L2 ~ sqrt(2 x cosine distance); 0/1 hashes:
# L2 = sqrt(differing bits), exactly). A cosine or bit threshold t becomes the link sqrt(2t) or
# sqrt(t), and the anchor is the balanced preset's anchor/link ratio times the link.
ANCHOR_RATIO_L2 = 0.65 / 0.55
WINDOW_TIMING = SENSITIVITY["balanced"][:2]  # maxGap, maxSpan used with every calibrated embedding
WINDOW_DEV = "photo-triage-tight"  # its dev half calibrates the in-window link
WINDOW_TARGET = 0.99  # in-window pair precision the in-window link is picked for
# Embeddings run through gtscan itself (--features) in the time window.
GTSCAN_FEATURE_METHODS = ["apple-fp2-soft", "apple-fp2-raw", "sscd", "sscd-pad320", "dinov2-small",
                          "dinov2-small-pad", "dinov3-small", "dinov3-small-squash", "siglip2-base"]
GTSCAN_FEATURE_DATASETS = ["bursts-profile", "photo-triage-tight", "gopro-bursts", "screenshots"]
# Copy pass: a pair is screen-shaped when both images are portrait with height/width >= this
# (16:10 or taller: phone screens are 16:9 to 19.5:9, 1.60 with the system bars cut off; photos are 4:3 or 3:2).
SCREEN_ASPECT = 1.6
FUSIONS = [
    ("apple-fp2-soft", "sscd"),
    ("apple-fp2-soft", "dinov2-small"),
    ("apple-fp2-soft", "dinov2-base"),
    ("apple-fp2-soft", "apple-fp2-raw"),
    ("apple-fp2-soft", "phash"),
    ("sscd", "dinov2-small"),
    ("sscd-pad320", "dinov2-small-pad"),
]
METHOD_ORDER = [
    "apple-fp2-soft", "apple-fp2-raw", "ahash", "phash", "dhash", "whash", "pdq", "imagededup-cnn",
    "clip-b32-openai", "mobileclip", "siglip2-base", "dinov2-small", "dinov2-small-mean", "dinov2-base",
    "sscd", "dinov3-small",
    # The same models with a fixed square input (what a fixed-shape Core ML model would take).
    "sscd-skew320", "sscd-pad320", "dinov2-small-squash", "dinov2-small-pad", "dinov3-small-squash",
]
BASE_METHODS = METHOD_ORDER[:16]
INPUT_FORMS = [  # (model, method, input form) for the input-form table
    ("SSCD", "sscd", "short side 288, aspect kept (variable size)"),
    ("SSCD", "sscd-skew320", "squashed to 320x320"),
    ("SSCD", "sscd-pad320", "padded to a 320x320 square"),
    ("DINOv2-small", "dinov2-small", "short side 256, center crop 224"),
    ("DINOv2-small", "dinov2-small-squash", "squashed to 224x224"),
    ("DINOv2-small", "dinov2-small-pad", "padded to a 224x224 square"),
    ("DINOv3-small", "dinov3-small", "short side 256, center crop 256"),
    ("DINOv3-small", "dinov3-small-squash", "squashed to 256x256"),
]
# For tables: what the weights' license means for shipping in a free app.
SHIP = {
    "apple-fp2-soft": ("in iOS", "yes"), "apple-fp2-raw": ("in iOS", "yes"),
    "ahash": ("none (BSD-2 code)", "yes"), "phash": ("none (BSD-2 code)", "yes"),
    "dhash": ("none (BSD-2 code)", "yes"), "whash": ("none (BSD-2 code)", "yes"),
    "pdq": ("none (BSD-3 code)", "yes"),
    "imagededup-cnn": ("BSD-3 (ImageNet-trained)", "check ImageNet terms"),
    "clip-b32-openai": ("MIT", "yes"), "mobileclip": ("Apple research-only", "no"),
    "siglip2-base": ("Apache-2.0", "yes"), "dinov2-small": ("Apache-2.0", "yes"),
    "dinov2-small-mean": ("Apache-2.0", "yes"), "dinov2-base": ("Apache-2.0", "yes"),
    "sscd": ("MIT", "yes"), "dinov3-small": ("DINOv3 License (custom)", "read license"),
    "sscd-skew320": ("MIT", "yes"), "sscd-pad320": ("MIT", "yes"),
    "dinov2-small-squash": ("Apache-2.0", "yes"), "dinov2-small-pad": ("Apache-2.0", "yes"),
    "dinov3-small-squash": ("DINOv3 License (custom)", "read license"),
}


# ---- data --------------------------------------------------------------------------------


@dataclass
class Truth:
    name: str
    raw: dict
    images: list[str]
    index: dict[str, int]
    groups: list[list[int]]
    unit: np.ndarray  # per image: its group, or n_groups + k for the k-th single
    I: np.ndarray  # scored pairs i < j (np.triu_indices order, unscored pairs left out)
    J: np.ndarray
    y: np.ndarray  # pair is a duplicate (same group)
    full2scored: np.ndarray | None = None  # position among all pairs -> position in I/J (-1: unscored)
    UI: np.ndarray | None = None  # unscored pairs (unscored_same: e.g. two moments of one clip)
    UJ: np.ndarray | None = None

    @property
    def n(self) -> int:
        return len(self.images)

    @property
    def variant_of(self) -> str | None:
        return self.raw.get("variant_of")

    @property
    def source(self) -> str:
        """The dataset whose embeddings this one uses (itself unless variant_of)."""
        return self.variant_of or self.name

    def full_pos(self, i, j):
        """Position of pair (i, j) among all pairs i < j (vectorized)."""
        i, j = np.minimum(i, j), np.maximum(i, j)
        return i * self.n - i * (i + 1) // 2 + (j - i - 1)

    def pair_pos(self, i: int, j: int) -> int:
        """Position of pair (i, j) in I/J."""
        k = int(self.full_pos(i, j))
        if self.full2scored is not None:
            k = int(self.full2scored[k])
            assert k >= 0, f"{self.name}: pair {self.images[i]}, {self.images[j]} is unscored"
        return k

    def is_unscored(self, i, j):
        if self.full2scored is None:
            return np.zeros(np.shape(i), bool)
        return self.full2scored[self.full_pos(i, j)] < 0

    def time(self, f: str) -> float:
        return float(self.raw["times"][f])


def load_truth(ds: str) -> Truth:
    raw = json.loads((DATA / ds / "truth.json").read_text())
    images = raw["images"]
    index = {f: i for i, f in enumerate(images)}
    assert len(index) == len(images), f"{ds}: duplicate names in images"
    groups = [[index[f] for f in g] for g in raw["groups"]]
    unit = np.full(len(images), -1, dtype=np.int64)
    for gi, g in enumerate(groups):
        assert len(g) >= 2, f"{ds}: group {gi} has fewer than 2 images"
        for i in g:
            assert unit[i] == -1, f"{ds}: {images[i]} is in two groups"
            unit[i] = gi
    singles = np.nonzero(unit < 0)[0]
    unit[singles] = len(groups) + np.arange(len(singles))
    I, J = np.triu_indices(len(images), 1)
    extra = {}
    if "unscored_same" in raw:  # pairs in different groups but with the same label: neither duplicate nor not
        of = raw["unscored_same"]["of"]
        lab = np.array([of.get(f, f"<unlabelled {k}>") for k, f in enumerate(images)], dtype=object)
        unscored = (lab[I] == lab[J]) & (unit[I] != unit[J])
        full2 = np.full(len(I), -1, dtype=np.int64)
        full2[~unscored] = np.arange(int((~unscored).sum()))
        extra = {"full2scored": full2, "UI": I[unscored], "UJ": J[unscored]}
        I, J = I[~unscored], J[~unscored]
    t = Truth(ds, raw, images, index, groups, unit, I, J, unit[I] == unit[J], **extra)
    k = np.r_[0, len(t.I) // 2, len(t.I) - 1]
    assert all(t.pair_pos(t.I[x], t.J[x]) == x for x in k)
    return t


def distance_matrix(X: np.ndarray, metric: str) -> tuple[np.ndarray, dict]:
    """Full distance matrix (float64) and facts for the integrity checks."""
    info: dict = {}
    if metric == "hamming":
        assert X.dtype == np.uint8 and set(np.unique(X).tolist()) <= {0, 1}, "hash must be unpacked 0/1 bits"
        B = X.astype(np.float64)
        D = B @ (1 - B).T + (1 - B) @ B.T  # bits that differ
        info["bits"] = int(X.shape[1])
    elif metric == "cosine":
        X = X.astype(np.float64)
        norms = np.linalg.norm(X, axis=1)
        info["max_norm_error"] = float(np.abs(norms - 1).max())
        Xn = X / np.maximum(norms[:, None], 1e-12)
        D = np.clip(1 - Xn @ Xn.T, 0, 2)  # cosine distance
    elif metric == "l2":
        X = X.astype(np.float64)
        norms = np.linalg.norm(X, axis=1)
        info["norm_min"], info["norm_max"] = float(norms.min()), float(norms.max())
        sq = (X * X).sum(1)
        D = np.sqrt(np.maximum(sq[:, None] + sq[None, :] - 2 * X @ X.T, 0))
    else:
        raise ValueError(metric)
    np.fill_diagonal(D, 0)
    info["asymmetry"] = float(np.abs(D - D.T).max())
    assert info["asymmetry"] < 1e-9
    return D, info


def load_method(ds: str, method: str, truth: Truth) -> tuple[dict, np.ndarray, np.ndarray, dict]:
    """Sidecar, full distance matrix, distances of the scored pairs, integrity facts."""
    side = json.loads((OUT / ds / f"{method}.json").read_text())
    z = np.load(OUT / ds / f"{method}.npz", allow_pickle=False)
    ids = [str(s) for s in z["ids"]]
    assert ids == truth.images, f"{ds}/{method}: ids differ from truth.json images"
    X = z["X"]
    assert X.shape == (truth.n, side["dim"]), (ds, method, X.shape)
    D, info = distance_matrix(X, side["metric"])
    return side, D, D[truth.I, truth.J], info


# ---- curves ---------------------------------------------------------------------------------


class Ranked:
    """Pairs sorted by distance with tie blocks, for exact (optionally weighted) PR and ROC curves.

    A threshold t calls every pair with distance <= t a duplicate, so pairs at the same distance
    are always called together (hash distances tie a lot).
    """

    def __init__(self, d: np.ndarray, y: np.ndarray):
        self.order = np.argsort(d, kind="stable")
        ds = d[self.order]
        self.ys = y[self.order].astype(np.float64)
        self.ends = np.r_[np.nonzero(np.diff(ds) > 0)[0], len(ds) - 1]
        self.thr = ds[self.ends]

    def counts(self, w: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray]:
        if w is None:
            tp = np.cumsum(self.ys)[self.ends]
            called = (self.ends + 1).astype(np.float64)
        else:
            ws = w[self.order]
            tp = np.cumsum(ws * self.ys)[self.ends]
            called = np.cumsum(ws)[self.ends]
        return tp, called - tp


def curve_metrics(tp: np.ndarray, fp: np.ndarray, thr: np.ndarray) -> dict:
    P, N = tp[-1], fp[-1]
    called = tp + fp
    prec = np.where(called > 0, tp / np.maximum(called, 1e-300), 1.0)
    rec = tp / P
    ap = float(np.sum(np.diff(np.r_[0.0, rec]) * prec))  # step-wise, as sklearn's average_precision_score
    auc = float(np.trapezoid(np.r_[0.0, rec], np.r_[0.0, fp / N]))
    out = {"ap": ap, "auc": auc, "positives": float(P), "negatives": float(N)}
    for p in (0.99, 0.95):
        ok = np.nonzero(prec >= p)[0]
        k = ok[np.argmax(rec[ok])] if len(ok) else None
        key = f"r{int(round(p * 100))}"
        out[key] = float(rec[k]) if k is not None else 0.0
        out[key + "_thr"] = float(thr[k]) if k is not None else None
    fpr = fp / N
    for f in FPR_LEVELS:  # recall at a fixed false-positive rate (the looser in-window regime)
        ok = np.nonzero(fpr <= f)[0]
        out[f"r_at_fpr_{f:g}"] = float(rec[ok].max()) if len(ok) else 0.0
    f1 = 2 * tp / (called + P)
    k = int(np.argmax(f1))
    out.update(f1=float(f1[k]), f1_thr=float(thr[k]), f1_precision=float(prec[k]), f1_recall=float(rec[k]))
    return out


def pick_threshold(d: np.ndarray, y: np.ndarray, target: float) -> float | None:
    """The largest distance whose calls have precision >= target (max recall); None if none does."""
    r = Ranked(d, y)
    tp, fp = r.counts()
    prec = tp / (tp + fp)
    ok = np.nonzero(prec >= target)[0]
    if not len(ok):
        return None
    return float(r.thr[ok[np.argmax((tp / tp[-1])[ok])]])


def clopper_pearson(k: float, n: float, alpha: float = 0.05) -> list[float] | None:
    """Exact two-sided binomial interval for k successes in n trials (pairs are not independent,
    so this is a floor on the uncertainty, not a full CI)."""
    from scipy.stats import beta

    k, n = int(round(k)), int(round(n))
    if n <= 0:
        return None
    lo = 0.0 if k == 0 else float(beta.ppf(alpha / 2, k, n - k + 1))
    hi = 1.0 if k == n else float(beta.ppf(1 - alpha / 2, k + 1, n - k))
    return [lo, hi]


def at_threshold(d: np.ndarray, y: np.ndarray, t: float | None, w: np.ndarray | None = None) -> dict:
    pred = d <= t if t is not None else np.zeros(len(d), bool)
    weighted = w is not None
    w = np.ones(len(d)) if w is None else w
    tp = float((w * (pred & y)).sum())
    fp = float((w * (pred & ~y)).sum())
    P, N = float((w * y).sum()), float((w * ~y).sum())
    out = {"tp": tp, "fp": fp, "fn": P - tp, "precision": tp / (tp + fp) if tp + fp else None,
           "recall": tp / P if P else None, "fp_per_million": 1e6 * fp / N if N else None,
           "positives": P, "negatives": N}
    if not weighted:
        out["precision_cp"], out["recall_cp"] = clopper_pearson(tp, tp + fp), clopper_pearson(tp, P)
    return out


def false_pairs(truth: Truth, d: np.ndarray, mask: np.ndarray, t: float | None, k: int = 12) -> list:
    """The k closest unrelated pairs called duplicates at t, for eyeballing."""
    if t is None:
        return []
    sel = np.nonzero(mask & ~truth.y & (d <= t))[0]
    sel = sel[np.argsort(d[sel], kind="stable")][:k]
    return [[truth.images[truth.I[x]], truth.images[truth.J[x]], float(d[x])] for x in sel]


def ci(values, lo=2.5, hi=97.5) -> list[float] | None:
    v = np.asarray([x for x in values if x is not None and np.isfinite(x)], dtype=np.float64)
    if not len(v):
        return None
    return [float(np.percentile(v, lo)), float(np.percentile(v, hi))]


def unit_weights(truth: Truth, mask: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Pair weights for one bootstrap resample of the units (groups and singles) inside `mask`.

    A unit drawn c times contributes its within-group pairs c times; pairs between units u and v
    count c_u * c_v times. Pairs between two copies of the same unit are left out (they would be
    an image paired with itself)."""
    units = np.unique(truth.unit[np.r_[truth.I[mask], truth.J[mask]]])
    draw = rng.choice(units, size=len(units), replace=True)
    c = np.bincount(draw, minlength=truth.unit.max() + 1).astype(np.float64)
    uI, uJ, y = truth.unit[truth.I[mask]], truth.unit[truth.J[mask]], truth.y[mask]
    return np.where(y, c[uI], c[uI] * c[uJ])


# ---- splits and clustering ---------------------------------------------------------------


def dev_mask(truth: Truth) -> np.ndarray:
    """Images in the dev half: half of the groups and half of the singles, by a fixed seed."""
    rng = random.Random(f"{SPLIT_SEED}:{truth.name}")
    groups = list(range(len(truth.groups)))
    rng.shuffle(groups)
    singles = sorted(set(range(truth.n)) - {i for g in truth.groups for i in g})
    rng.shuffle(singles)
    dev = np.zeros(truth.n, bool)
    for g in groups[: len(groups) // 2]:
        dev[truth.groups[g]] = True
    dev[singles[: len(singles) // 2]] = True
    return dev


def single_linkage(truth: Truth, d: np.ndarray, t: float | None, mask: np.ndarray) -> dict:
    """Connected components of 'distance <= t' among the pairs in mask, scored against the truth."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components

    edge = mask & (d <= t) if t is not None else np.zeros(len(d), bool)
    A = coo_matrix((np.ones(edge.sum()), (truth.I[edge], truth.J[edge])), shape=(truth.n, truth.n))
    _, comp = connected_components(A, directed=False)
    inside = np.unique(np.r_[truth.I[mask], truth.J[mask]])
    same = comp[truth.I] == comp[truth.J]
    pred, y = same & mask, truth.y & mask
    hit = int((pred & y).sum())
    sizes = np.bincount(comp[inside])
    clusters = sizes[sizes >= 2]
    groups_in = [g for g in truth.groups if np.isin(g, inside).all()]
    exact = sum(1 for g in groups_in if len(set(comp[g])) == 1 and sizes[comp[g[0]]] == len(g))
    return {"pair_precision": hit / int(pred.sum()) if pred.sum() else None,
            "pair_recall": hit / int(y.sum()) if y.sum() else None,
            "groups_exact": exact, "groups_total": len(groups_in),
            "clusters": int(len(clusters)), "largest_cluster": int(clusters.max()) if len(clusters) else 0}


def image_sizes(ds: str, images: list[str]) -> dict[str, list[int]]:
    """Pixel size of every image (cached in out/<ds>/sizes.json)."""
    path = OUT / ds / "sizes.json"
    if path.exists():
        sizes = json.loads(path.read_text())
        if set(sizes) >= set(images):
            return sizes
    from PIL import Image

    try:
        import pillow_heif

        pillow_heif.register_heif_opener()
    except ImportError:
        pass
    sizes = {}
    for f in images:
        with Image.open(DATA / ds / "images" / f) as im:
            sizes[f] = list(im.size)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(sizes) + "\n")
    return sizes


def screen_shaped(truth: Truth) -> np.ndarray:
    """Per image: portrait with height/width >= SCREEN_ASPECT (a screenshot's shape)."""
    sizes = image_sizes(truth.source, truth.images)
    return np.array([sizes[f][1] >= SCREEN_ASPECT * sizes[f][0] for f in truth.images])


def score_components(truth: Truth, S: np.ndarray, labels: np.ndarray) -> dict:
    """Clusters (a label per image) of the images in S, scored on the pairs inside S."""
    mask = S[truth.I] & S[truth.J]
    pred = mask & (labels[truth.I] == labels[truth.J])
    y = truth.y & mask
    hit = int((pred & y).sum())
    lab = labels[S]
    units = truth.unit[S]
    _, inv, sizes = np.unique(lab, return_inverse=True, return_counts=True)
    impure = sum(1 for c in np.nonzero(sizes >= 2)[0] if len(set(units[inv == c])) > 1)
    groups_in = [g for g in truth.groups if S[g].all()]
    size_of = dict(zip(*np.unique(lab, return_counts=True)))
    exact = sum(1 for g in groups_in if len(set(labels[g])) == 1 and size_of[labels[g[0]]] == len(g))
    return {"pair_precision": hit / int(pred.sum()) if pred.sum() else None,
            "pair_recall": hit / int(y.sum()) if y.sum() else None, "false_pairs": int((pred & ~y).sum()),
            "groups_exact": exact, "groups_total": len(groups_in), "clusters": int((sizes >= 2).sum()),
            "impure_clusters": impure, "largest_cluster": int(sizes.max()) if len(sizes) else 0}


def copy_pass(truth: Truth, D: np.ndarray, d: np.ndarray, S: np.ndarray, rule: str, t: float | None,
              t_screen: float | None = None, screen: np.ndarray | None = None) -> dict | None:
    """Library-wide linking of the images in S (no time window) by one rule, scored on pairs inside S."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components

    if t is None or (rule == "two-threshold" and t_screen is None):
        return None
    mask = S[truth.I] & S[truth.J]
    idx = np.nonzero(S)[0]
    labels = np.arange(truth.n) + truth.n  # images outside S stay alone
    if rule == "complete":
        from scipy.cluster.hierarchy import fcluster, linkage
        from scipy.spatial.distance import squareform

        Ds = D[np.ix_(idx, idx)].astype(np.float64)
        np.fill_diagonal(Ds, 0)
        labels[idx] = fcluster(linkage(squareform(Ds, checks=False), method="complete"), t, criterion="distance")
        return score_components(truth, S, labels)
    if rule == "single":
        edge = mask & (d <= t)
    elif rule == "two-threshold":
        both = screen[truth.I] & screen[truth.J]
        edge = mask & (d <= np.where(both, t_screen, t))
    elif rule.startswith("mutual-"):
        k = int(rule.split("-")[1].rstrip("nn"))
        Ds = D[np.ix_(idx, idx)].astype(np.float64)
        np.fill_diagonal(Ds, np.inf)
        nn = np.argsort(Ds, axis=1, kind="stable")[:, :k]
        near = np.zeros(Ds.shape, bool)
        near[np.repeat(np.arange(len(idx)), k), nn.ravel()] = True
        mutual = near & near.T
        pos = np.full(truth.n, -1)
        pos[idx] = np.arange(len(idx))
        edge = mask & (d <= t)
        edge[edge] = mutual[pos[truth.I[edge]], pos[truth.J[edge]]]
    else:
        raise ValueError(rule)
    A = coo_matrix((np.ones(int(edge.sum())), (truth.I[edge], truth.J[edge])), shape=(truth.n, truth.n))
    _, comp = connected_components(A, directed=False)
    labels[idx] = comp[idx]
    return score_components(truth, S, labels)


# ---- gtscan ------------------------------------------------------------------------------


def gtscan(args: list[str], cache: Path, force: bool) -> str:
    if cache.exists() and not force:
        return cache.read_text()
    if not GTSCAN.exists():
        raise RuntimeError(f"gtscan not built: {GTSCAN}")
    t = time.perf_counter()
    p = subprocess.run([str(GTSCAN), *args], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"gtscan {' '.join(args)} failed ({p.returncode}): {p.stderr[-600:]}")
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(p.stdout)
    print(f"  gtscan {args[0]} {Path(args[1]).parent.name} {' '.join(args[2:])}: {time.perf_counter() - t:.0f}s",
          file=sys.stderr)
    return p.stdout


def manifest_dates(ds: str) -> dict[str, float]:
    m = json.loads((DATA / ds / "images" / "manifest.json").read_text())["files"]
    return {f: datetime.fromisoformat(v["date"].replace("Z", "+00:00")).replace(tzinfo=timezone.utc).timestamp()
            for f, v in m.items()}


def app_candidates(dates: dict[str, float], max_gap: float) -> set[str]:
    """SeriesBuilder.candidates: photos with another photo within maxGap (no bursts in these sets)."""
    order = sorted(dates, key=lambda f: (dates[f], f))
    keep = set()
    for a, b in zip(order, order[1:]):
        if dates[b] - dates[a] <= max_gap:
            keep |= {a, b}
    return keep


def jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a | b else 0.0


def app_run(ds: str, truth: Truth, sens: str, force: bool, extra: tuple = (), tag: str = "") -> dict:
    """One `gtscan eval` + `gtscan scan --json` on the dataset's folder, scored two ways.

    extra: more gtscan arguments (--features, --link, --anchor); tag names the cached outputs."""
    folder = DATA / ds / "images"
    dates = manifest_dates(ds)
    true_pairs = {tuple(sorted((truth.images[i], truth.images[j]))) for g in truth.groups
                  for k, i in enumerate(g) for j in g[k + 1:]}
    unscored = set() if truth.UI is None else {
        tuple(sorted((truth.images[i], truth.images[j]))) for i, j in zip(truth.UI, truth.UJ)}
    best = {int(k): v for k, v in truth.raw.get("best", {}).items()}
    max_gap, max_span, link, anchor = SENSITIVITY[sens]
    text = gtscan(["eval", str(folder), "--sensitivity", sens, *extra], OUT / ds / "app" / f"eval-{sens}{tag}.txt", force)
    m = re.search(r"pair precision ([\d.]+)\s+pair recall ([\d.]+)\s+keeper accuracy ([\d.]+)\s+"
                  r"series found (\d+)/(\d+)", text)
    assert m, text[:300]
    official = {"pair_precision": float(m[1]), "pair_recall": float(m[2]), "keeper_accuracy": float(m[3]),
                "series_found": int(m[4]), "series_total": int(m[5])}
    scan = json.loads(gtscan(["scan", str(folder), "--sensitivity", sens, "--json", *extra],
                             OUT / ds / "app" / f"scan-{sens}{tag}.json", force))
    groups = [g["ranked"] for g in scan["groups"]]
    pred_pairs = {tuple(sorted((a, b))) for g in groups for k, a in enumerate(g) for b in g[k + 1:]}
    hit = pred_pairs & true_pairs
    found, right, known = 0, 0, 0
    for gi, g in enumerate(truth.groups):
        names = {truth.images[i] for i in g}
        match = max(groups, key=lambda p: jaccard(set(p), names), default=None)
        if match is None or jaccard(set(match), names) < 0.5:
            continue
        found += 1
        if gi in best:
            known += 1
            right += int(match[0] == best[gi])
    cand = app_candidates(dates, max_gap)
    miss = {"not_analyzed": 0, "beyond_max_span": 0, "visual_or_linking": 0}
    for a, b in true_pairs - pred_pairs:
        if a not in cand or b not in cand:
            miss["not_analyzed"] += 1
        elif abs(dates[a] - dates[b]) > max_span:
            miss["beyond_max_span"] += 1
        else:
            miss["visual_or_linking"] += 1
    mine = {"pair_precision": len(hit) / len(pred_pairs) if pred_pairs else 1.0,
            "pair_recall": len(hit) / len(true_pairs), "series_found": found,
            "keeper_accuracy_known_best": right / known if known else None, "keeper_known_n": known}
    # Our scoring of the scan must agree with the app's own GroupingEval (which counts every
    # grouped pair that is not a true pair as wrong, unscored ones included).
    assert abs(mine["pair_precision"] - official["pair_precision"]) < 2e-3, (ds, sens, tag, mine, official)
    assert abs(mine["pair_recall"] - official["pair_recall"]) < 2e-3, (ds, sens, tag, mine, official)
    assert mine["series_found"] == official["series_found"], (ds, sens, tag, mine, official)
    scored = pred_pairs - unscored
    mine["scored_pair_precision"] = len(scored & true_pairs) / len(scored) if scored else 1.0
    mine["unscored_pairs_grouped"] = len(pred_pairs & unscored)
    features = "--features" in extra
    out = {"config": scan.get("config") or {"max_gap_s": max_gap, "max_span_s": max_span, "link": link,
                                             "anchor": anchor},
           "official": official, **mine, "photos": scan["photos"], "analyzed": scan["analyzed"],
           "candidates_python": len(cand), "groups_found": len(groups), "true_pairs": len(true_pairs),
           "predicted_pairs": len(pred_pairs), "missed_pairs": miss, "features": features,
           "groups": [sorted(g) for g in groups],
           "wrong_keepers": [ln.strip() for ln in text.splitlines() if "wrong keeper" in ln]}
    if not features:  # with --features nothing is analyzed
        assert scan["analyzed"] == len(cand), (ds, sens, scan["analyzed"], len(cand))
    return out


def app_pipeline(ds: str, truth: Truth, force: bool) -> dict:
    return {sens: app_run(ds, truth, sens, force) for sens in APP_RUNS.get(ds, ("strict", "balanced"))}


def write_features(truth: Truth, method: str, path: Path) -> Path:
    """A --features file for gtscan: this embedding, with the app's own quality signals."""
    if path.exists():
        return path
    src = truth.source
    side = json.loads((OUT / src / f"{method}.json").read_text())
    z = np.load(OUT / src / f"{method}.npz", allow_pickle=False)
    assert [str(x) for x in z["ids"]] == truth.images
    X = z["X"].astype(np.float64)
    if side["metric"] == "cosine":
        X /= np.linalg.norm(X, axis=1, keepdims=True)
    elif side["metric"] != "l2":
        raise ValueError(f"{method}: gtscan compares embeddings by Euclidean distance")
    sig = json.loads((OUT / src / "signals" / f"{APP}.json").read_text())["signals"]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fh:
        for f, x in zip(truth.images, X):
            s = sig[f]
            fh.write(json.dumps({"id": f, "embedding": [float(v) for v in x.astype(np.float32)],
                                 "sharpness": s["sharpness"], "aesthetics": s["aesthetics"],
                                 "isUtility": s["isUtility"], "faceQualities": s["faceQualities"]}) + "\n")
    return path


# ---- time window -----------------------------------------------------------------------------


def window_matrix(truth: Truth, method: str, metric: str) -> np.ndarray:
    """Distances as the app's grouping step would see this embedding: int8-quantized, Euclidean."""
    import series_port as sp

    z = np.load(OUT / truth.source / f"{method}.npz", allow_pickle=False)
    X = z["X"].astype(np.float32)
    if metric == "cosine":
        X = X / np.linalg.norm(X, axis=1, keepdims=True)
    return sp.l2_matrix(sp.quantize(X)).astype(np.float32)


def link_from_threshold(t: float | None, metric: str) -> float | None:
    """A pair threshold in the method's own units, as a Euclidean link distance."""
    if t is None:
        return None
    return float(np.sqrt(2 * t)) if metric == "cosine" else float(np.sqrt(t)) if metric == "hamming" else float(t)


def score_window(truth: Truth, groups: list[list[int]], idx: np.ndarray) -> dict:
    """Pair precision/recall of the app's groups against the truth, for the photos in idx."""
    inside = np.zeros(truth.n, bool)
    inside[idx] = True
    P = sum(int(inside[g].sum()) * (int(inside[g].sum()) - 1) // 2 for g in truth.groups)
    tp = fp = un = 0
    for g in groups:
        g = np.asarray(g)
        a, b = np.triu_indices(len(g), 1)
        a, b = g[a], g[b]
        same = truth.unit[a] == truth.unit[b]
        uns = truth.is_unscored(a, b) & ~same
        tp += int(same.sum())
        un += int(uns.sum())
        fp += int((~same & ~uns).sum())
    sets = [set(int(x) for x in g) for g in groups]
    found, total = 0, 0
    for g in truth.groups:
        if not inside[g].all():
            continue
        total += 1
        gs = set(g)
        if any(len(gs & q) / len(gs | q) >= 0.5 for q in sets):
            found += 1
    return {"precision": tp / (tp + fp) if tp + fp else 1.0, "recall": tp / P if P else None, "tp": tp, "fp": fp,
            "positives": P, "unscored_grouped": un, "series_found": found, "series_total": total,
            "groups": len(groups), "largest_group": max((len(g) for g in groups), default=0)}


def window_grid(truth: Truth, idx: np.ndarray, dates: np.ndarray, Dw: np.ndarray, max_span: float) -> np.ndarray:
    """Link distances to sweep: quantiles of the in-window distances of duplicates and of the
    closest unrelated pairs (pairs at most maxSpan apart in time)."""
    a, b = np.triu_indices(len(idx), 1)
    a, b = idx[a], idx[b]
    near = np.abs(dates[a] - dates[b]) <= max_span
    a, b = a[near], b[near]
    keep = ~(truth.is_unscored(a, b) & (truth.unit[a] != truth.unit[b]))
    a, b = a[keep], b[keep]
    d = Dw[a, b].astype(np.float64)
    same = truth.unit[a] == truth.unit[b]
    grid = [np.quantile(d[same], np.linspace(0, 1, 41))] if same.any() else []
    if (~same).any():
        grid.append(np.quantile(d[~same], [1e-3, 1e-2, 0.05, 0.1, 0.25, 0.5]))
    return np.unique(np.concatenate(grid)) if grid else np.array([])


def window_sweep(truth, idx, dates, names, Dw, utility, timing) -> dict:
    import series_port as sp

    rows = []
    for link in window_grid(truth, idx, dates, Dw, timing[1]):
        g = sp.app_groups(idx, dates, names, Dw, (*timing, link, link * ANCHOR_RATIO_L2), utility)
        r = score_window(truth, g, idx)
        rows.append({"link": float(link), "precision": r["precision"], "recall": r["recall"] or 0.0,
                     "fp": r["fp"], "unscored_grouped": r["unscored_grouped"]})
    out = {"points": rows}
    for target in (0.99, 0.95):
        ok = [r for r in rows if r["precision"] >= target]
        top = max(ok, key=lambda r: (r["recall"], -r["link"])) if ok else None
        out[f"r{int(target * 100)}"] = top["recall"] if top else 0.0
        out[f"r{int(target * 100)}_link"] = top["link"] if top else None
    f1 = [(2 * r["precision"] * r["recall"] / (r["precision"] + r["recall"]) if r["recall"] else 0.0, r) for r in rows]
    if f1:
        v, r = max(f1, key=lambda x: x[0])
        out.update(f1=v, f1_link=r["link"], f1_precision=r["precision"], f1_recall=r["recall"])
    return out


# ---- best shot ---------------------------------------------------------------------------


def best_shot(ds: str, truth: Truth, force: bool, boot: int) -> dict | None:
    best = {int(k): v for k, v in truth.raw.get("best", {}).items()}
    prefs = truth.raw.get("preferences", [])
    if not best and not prefs:
        return None
    group_of = {truth.images[i]: gi for gi, g in enumerate(truth.groups) for i in g}
    # The app builds groups in capture order and breaks exact ties by that order, so rank them that way.
    capture = [sorted((truth.images[i] for i in g), key=lambda f: (truth.time(f), f)) for g in truth.groups]
    gfile = OUT / ds / "app" / "groups-capture-order.json"
    gfile.parent.mkdir(parents=True, exist_ok=True)
    gfile.write_text(json.dumps({"groups": capture}) + "\n")
    rank_path = OUT / ds / "app" / "rank.json"
    if force or not rank_path.exists():
        gtscan(["rank", str(DATA / ds / "images"), str(gfile), str(rank_path)], OUT / ds / "app" / "rank.log", True)
    ranked = json.loads(rank_path.read_text())["groups"]
    assert len(ranked) == len(capture) and all(set(r["ranked"]) == set(c) for r, c in zip(ranked, capture))
    signals = json.loads((OUT / ds / "signals" / f"{APP}.json").read_text())["signals"]
    laion_path = OUT / ds / "signals" / "laion-aesthetic.json"
    laion = json.loads(laion_path.read_text())["scores"] if laion_path.exists() else None

    def vision_aesthetics(files):
        vals = [signals[f]["aesthetics"] for f in files]
        known = sorted(v for v in vals if v is not None)
        fallback = known[len(known) // 2] if known else 0.0  # as ShotScorer
        return [fallback if v is None else v for v in vals]

    rankers = {
        "app (ShotScorer)": lambda gi, files: [-ranked[gi]["ranked"].index(f) for f in files],
        "sharpness only": lambda gi, files: [signals[f]["sharpness"] for f in files],
        "Vision aesthetics only": lambda gi, files: vision_aesthetics(files),
        "first in capture order": lambda gi, files: [-capture[gi].index(f) for f in files],
        "last in capture order": lambda gi, files: [capture[gi].index(f) for f in files],
    }
    if laion:
        rankers["LAION aesthetic (CLIP ViT-L/14)"] = lambda gi, files: [laion[f] for f in files]

    # Tasks: pairwise [better, worse] within a group, and top-1 where the best frame is known.
    if prefs:
        pairs = [(group_of[a], a, b) for a, b in prefs]
        assert all(group_of[a] == group_of[b] for a, b in prefs)
        pair_kind = "human preference pairs (preference ratio >= 0.7 or <= 0.3)"
        ratio = truth.raw.get("preference_ratio", {})

        def strength(a, b):
            r = ratio.get(f"{a}|{b}", None)
            r = 1 - ratio[f"{b}|{a}"] if r is None and f"{b}|{a}" in ratio else r
            return r
        strong = [abs(strength(a, b) - 0.5) >= 0.3 if strength(a, b) is not None else False for _, a, b in pairs]
    else:
        pairs = [(gi, b, truth.images[i]) for gi, b in best.items() for i in truth.groups[gi] if truth.images[i] != b]
        pair_kind = "known best frame vs each other frame of its group"
        strong = None
    tops = sorted(best.items())

    def outcomes(fn):
        pair_out = []
        for gi, a, b in pairs:
            files = capture[gi]
            s = dict(zip(files, fn(gi, files)))
            pair_out.append(1.0 if s[a] > s[b] else 0.5 if s[a] == s[b] else 0.0)
        top_out = []
        for gi, b in tops:
            files = capture[gi]
            sc = np.array(fn(gi, files), dtype=np.float64)
            top = {f for f, v in zip(files, sc) if v == sc.max()}
            top_out.append(1.0 / len(top) if b in top else 0.0)
        return np.array(pair_out), np.array(top_out)

    rng = np.random.default_rng(BOOT_SEED)
    pair_groups = np.array([gi for gi, _, _ in pairs])
    top_groups = np.array([gi for gi, _ in tops])
    ug_pairs, ug_tops = np.unique(pair_groups), np.unique(top_groups)
    draws_p = [rng.choice(ug_pairs, len(ug_pairs)) for _ in range(boot)]
    draws_t = [rng.choice(ug_tops, len(ug_tops)) for _ in range(boot)] if len(ug_tops) else []

    def boot_mean(values, groups, draws):
        if not len(values):
            return []
        sums = np.bincount(groups, weights=values, minlength=len(truth.groups))
        cnts = np.bincount(groups, minlength=len(truth.groups)).astype(np.float64)
        return [sums[d].sum() / cnts[d].sum() for d in draws]

    res = {"pair_task": pair_kind, "n_pairs": len(pairs), "n_pair_groups": int(len(ug_pairs)),
           "n_top1_groups": len(tops), "rankers": {}}
    random_top1 = float(np.mean([1 / len(truth.groups[gi]) for gi, _ in tops])) if tops else None
    res["rankers"]["random"] = {"pairwise": 0.5, "pairwise_ci": None, "top1": random_top1, "top1_ci": None}
    app_p, app_t = outcomes(rankers["app (ShotScorer)"])
    app_bp, app_bt = boot_mean(app_p, pair_groups, draws_p), boot_mean(app_t, top_groups, draws_t)
    for name, fn in rankers.items():
        p, t = outcomes(fn)
        bp, bt = boot_mean(p, pair_groups, draws_p), boot_mean(t, top_groups, draws_t)
        row = {"pairwise": float(p.mean()), "pairwise_ci": ci(bp),
               "top1": float(t.mean()) if len(t) else None, "top1_ci": ci(bt) if len(t) else None}
        if strong is not None:
            row["pairwise_strong"] = float(p[np.array(strong)].mean())
            row["n_strong"] = int(sum(strong))
        if name != "app (ShotScorer)":
            row["app_minus_this_pairwise_ci"] = ci(np.array(app_bp) - np.array(bp))
            if len(t):
                row["app_minus_this_top1_ci"] = ci(np.array(app_bt) - np.array(bt))
        res["rankers"][name] = row
    res["laion"] = None if not laion else {k: v for k, v in json.loads(laion_path.read_text()).items() if k != "scores"}
    return res


# ---- integrity ---------------------------------------------------------------------------


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def duplicate_files(names: list[str]) -> dict:
    by_hash: dict[str, list[str]] = {}
    for ds in names:
        for f in json.loads((DATA / ds / "truth.json").read_text())["images"]:
            by_hash.setdefault(sha256(DATA / ds / "images" / f), []).append(f"{ds}/{f}")
    same = [v for v in by_hash.values() if len(v) > 1]
    cross = [v for v in same if len({x.split("/")[0] for x in v}) > 1]
    return {"files_hashed": sum(len(v) for v in by_hash.values()), "byte_identical_sets": same,
            "cross_dataset_byte_identical": cross}


def cross_dataset_near(names: list[str], method: str, threshold: float | None) -> dict:
    """Closest image pairs across datasets by one embedding (its own metric), against its transfer threshold."""
    X, owner, ids = [], [], []
    for ds in names:
        p = OUT / ds / f"{method}.npz"
        if not p.exists():
            continue
        z = np.load(p, allow_pickle=False)
        X.append(z["X"])
        owner += [ds] * len(z["ids"])
        ids += [str(s) for s in z["ids"]]
    metric = json.loads((OUT / names[0] / f"{method}.json").read_text())["metric"]
    D, _ = distance_matrix(np.vstack(X), metric)
    owner = np.array(owner)
    cross = owner[:, None] != owner[None, :]
    iu = np.triu_indices(len(ids), 1)
    m = cross[iu]
    d = D[iu][m]
    a, b = iu[0][m], iu[1][m]
    k = np.argsort(d)[:8]
    return {"method": method, "metric": metric, "threshold": threshold,
            "closest": [{"a": f"{owner[a[i]]}/{ids[a[i]]}", "b": f"{owner[b[i]]}/{ids[b[i]]}", "distance": float(d[i])}
                        for i in k],
            "pairs_within_threshold": int((d <= threshold).sum()) if threshold is not None else None}


# ---- tables ------------------------------------------------------------------------------


def f3(x, nd=3) -> str:
    return "n/a" if x is None else f"{x:.{nd}f}"


def fci(x, c, nd=3) -> str:
    if x is None:
        return "n/a"
    return f"{x:.{nd}f} [{c[0]:.{nd}f}, {c[1]:.{nd}f}]" if c else f"{x:.{nd}f}"


def pct(x) -> str:
    return "n/a" if x is None else f"{100 * x:.1f}%"


def md_table(header: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out)


def fmt_thr(t, metric) -> str:
    if t is None:
        return "none"
    return f"{t:.0f} bits" if metric == "hamming" else f"{t:.3f}"


# ---- main --------------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--datasets", default=",".join(DEFAULT_DATASETS))
    ap.add_argument("--methods", default="all")
    ap.add_argument("--boot", type=int, default=1000, help="bootstrap resamples")
    ap.add_argument("--force-app", action="store_true", help="rerun gtscan eval/scan/rank")
    ap.add_argument("--skip-app", action="store_true", help="skip every gtscan section (pipeline, best shot, --features)")
    args = ap.parse_args()
    t0 = time.perf_counter()
    sys.path.insert(0, str(BENCH))
    import series_port as sp

    names = [d for d in args.datasets.split(",") if (DATA / d / "truth.json").exists()]
    missing = [d for d in args.datasets.split(",") if d not in names]
    truths = {ds: load_truth(ds) for ds in names}
    # Datasets with variant_of reuse another dataset's images and embeddings (time-window sections only).
    pair_names = [ds for ds in names if not truths[ds].variant_of]
    names = pair_names + [ds for ds in names if truths[ds].variant_of in pair_names]
    window_only = [ds for ds in names if ds not in pair_names]
    avail = {ds: {p.stem for p in (OUT / ds).glob("*.npz") if (OUT / ds / f"{p.stem}.json").exists()}
             for ds in pair_names}
    common = set.intersection(*avail.values())
    methods = [m for m in METHOD_ORDER if m in common] + sorted(common - set(METHOD_ORDER))
    if args.methods != "all":
        methods = [m for m in methods if m in args.methods.split(",")]
    print(f"datasets {pair_names} + window-only {window_only} (missing: {missing}); {len(methods)} methods",
          file=sys.stderr)

    results: dict = {"created": time.strftime("%Y-%m-%dT%H:%M:%S"), "datasets": {}, "methods": {},
                     "missing_datasets": missing, "pair_datasets": pair_names, "window_only_datasets": window_only,
                     "settings": {
                         "target_precision": TARGET_PRECISION, "split_seed": SPLIT_SEED, "boot_seed": BOOT_SEED,
                         "bootstrap_resamples": args.boot, "dev_datasets": [d for d in DEV_DATASETS if d in names],
                         "fpr_levels": list(FPR_LEVELS), "anchor_ratio_l2": ANCHOR_RATIO_L2,
                         "window_timing_s": list(WINDOW_TIMING), "window_dev": WINDOW_DEV,
                         "window_target_precision": WINDOW_TARGET, "screen_aspect": SCREEN_ASPECT,
                         "distance": "cosine distance 1-cos (cosine), Euclidean (l2), differing bits (hamming); "
                                     "a pair is called a duplicate when distance <= threshold"}}
    integrity: dict = {"methods": {}, "sklearn_check": [], "wrong_direction": []}

    # Distances for every dataset x method (scored pairs, and the full matrix for clustering).
    dist: dict = {}
    full: dict = {}
    sides: dict = {}
    for ds in pair_names:
        tr = truths[ds]
        for m in methods:
            side, D, d, info = load_method(ds, m, tr)
            sides[(ds, m)] = side
            dist[(ds, m)] = d
            full[(ds, m)] = D
            pos, neg = d[tr.y], d[~tr.y]
            integrity["methods"].setdefault(m, {})[ds] = {
                **info, "metric": side["metric"], "mean_pos": float(pos.mean()), "mean_neg": float(neg.mean())}
            if pos.mean() >= neg.mean():
                integrity["wrong_direction"].append(f"{ds}/{m}")
    if integrity["wrong_direction"]:  # a learned embedding here would mean a bug (wrong sign)
        print(f"  WARNING duplicates not closer on average: {integrity['wrong_direction']}", file=sys.stderr)
    for ds in names:
        tr = truths[ds]
        results["datasets"][ds] = {
            "kind": tr.raw["kind"], "images": tr.n, "groups": len(tr.groups),
            "singles": int(tr.n - sum(len(g) for g in tr.groups)), "positive_pairs": int(tr.y.sum()),
            "negative_pairs": int((~tr.y).sum()), "unscored_pairs": 0 if tr.UI is None else int(len(tr.UI)),
            "variant_of": tr.variant_of, "license": tr.raw["license"], "source": tr.raw["source"]}

    # sklearn cross-check of the curve code, one method per metric type.
    from sklearn.metrics import average_precision_score, roc_auc_score

    for ds in pair_names:
        tr = truths[ds]
        for m in [x for x in ("apple-fp2-soft", "phash", "sscd") if x in methods]:
            d = dist[(ds, m)]
            r = Ranked(d, tr.y)
            mine = curve_metrics(*r.counts(), r.thr)
            sk_ap, sk_auc = average_precision_score(tr.y, -d), roc_auc_score(tr.y, -d)
            integrity["sklearn_check"].append({"dataset": ds, "method": m, "ap": mine["ap"], "sklearn_ap": sk_ap,
                                               "auc": mine["auc"], "sklearn_auc": sk_auc})
            assert abs(mine["ap"] - sk_ap) < 1e-9 and abs(mine["auc"] - sk_auc) < 1e-9, (ds, m, mine, sk_ap, sk_auc)
            w = np.ones(len(d))
            assert abs(curve_metrics(*r.counts(w), r.thr)["ap"] - sk_ap) < 1e-9

    # 1. Pair metrics with bootstrap CIs (same resamples for every method).
    print("pair metrics + bootstrap", file=sys.stderr)
    pair = {}
    for ds in pair_names:
        tr = truths[ds]
        ranked = {m: Ranked(dist[(ds, m)], tr.y) for m in methods}
        for m in methods:
            pair[(ds, m)] = curve_metrics(*ranked[m].counts(), ranked[m].thr)
        rng = np.random.default_rng(BOOT_SEED)
        allmask = np.ones(len(tr.y), bool)
        boots = {m: {"ap": [], "r99": [], "auc": []} for m in methods}
        for _ in range(args.boot):
            w = unit_weights(tr, allmask, rng)
            for m in methods:
                cm = curve_metrics(*ranked[m].counts(w), ranked[m].thr)
                for k in boots[m]:
                    boots[m][k].append(cm[k])
        top = max(methods, key=lambda m: pair[(ds, m)]["ap"])
        for m in methods:
            pm = pair[(ds, m)]
            pm["ap_ci"], pm["r99_ci"], pm["auc_ci"] = ci(boots[m]["ap"]), ci(boots[m]["r99"]), ci(boots[m]["auc"])
            if APP in methods and m != APP:
                pm["ap_minus_app_ci"] = ci(np.array(boots[m]["ap"]) - np.array(boots[APP]["ap"]))
                pm["ap_minus_app"] = pm["ap"] - pair[(ds, APP)]["ap"]
            # Paired difference to the top method on this dataset: is the gap real?
            pm["top_method"] = top
            if m != top:
                pm["ap_minus_top_ci"] = ci(np.array(boots[m]["ap"]) - np.array(boots[top]["ap"]))
                pm["ap_minus_top"] = pm["ap"] - pair[(ds, top)]["ap"]
        # California-ND style: AP against other definitions of a duplicate (annotator agreement).
        if "pair_agreement" in tr.raw:
            agree = np.zeros(len(tr.y))
            for key, v in tr.raw["pair_agreement"].items():
                a, b = key.split("|")
                agree[tr.pair_pos(tr.index[a], tr.index[b])] = v
            for m in methods:
                for thr in (0.5, 0.8):
                    y_alt = agree >= thr
                    r = Ranked(dist[(ds, m)], y_alt)
                    pair[(ds, m)][f"ap_agreement_ge_{thr}"] = curve_metrics(*r.counts(), r.thr)["ap"]
                    pair[(ds, m)][f"positives_agreement_ge_{thr}"] = int(y_alt.sum())
    for (ds, m), pm in pair.items():
        results["methods"].setdefault(m, {"pair": {}})["pair"][ds] = pm

    # 2. Threshold transfer.
    print("threshold transfer", file=sys.stderr)
    dev_names = [d for d in DEV_DATASETS if d in pair_names]
    split_names = dev_names + [d for d in ("screenshots", WINDOW_DEV) if d in names]
    devm = {ds: dev_mask(truths[ds]) for ds in split_names}
    pmask = {}
    for ds in names:
        tr = truths[ds]
        if ds in devm:
            dv = devm[ds]
            pmask[(ds, "dev")] = dv[tr.I] & dv[tr.J]
            pmask[(ds, "test")] = ~dv[tr.I] & ~dv[tr.J]
            pmask[(ds, "cross")] = dv[tr.I] != dv[tr.J]
        pmask[(ds, "all")] = np.ones(len(tr.y), bool)
    eval_sets = [(ds, "test") for ds in dev_names] + [(ds, "all") for ds in pair_names if ds not in dev_names]
    split_info = {ds: {"dev_images": int(devm[ds].sum()), "test_images": int((~devm[ds]).sum()),
                       "dev_positive_pairs": int(truths[ds].y[pmask[(ds, "dev")]].sum()),
                       "test_positive_pairs": int(truths[ds].y[pmask[(ds, "test")]].sum()),
                       "test_negative_pairs": int((~truths[ds].y[pmask[(ds, "test")]]).sum()),
                       "cross_pairs": int(pmask[(ds, "cross")].sum()),
                       "cross_positive_pairs": int(truths[ds].y[pmask[(ds, "cross")]].sum())} for ds in split_names}
    results["split"] = split_info

    def transfer(get_d, get_u=None):
        """Pick the threshold on the pooled dev halves; score it on every eval set.

        Dev datasets are also scored on all their pairs ("full") and on the pairs with one image in
        each half ("cross"), which the test half leaves out."""
        d_dev = np.concatenate([get_d(ds)[pmask[(ds, "dev")]] for ds in dev_names])
        y_dev = np.concatenate([truths[ds].y[pmask[(ds, "dev")]] for ds in dev_names])
        t = pick_threshold(d_dev, y_dev, TARGET_PRECISION)
        row = {"threshold": t, "dev_pooled": at_threshold(d_dev, y_dev, t), "dev": {}, "full": {}, "cross": {},
               "eval": {}}
        for ds in dev_names:
            tr = truths[ds]
            for part in ("dev", "full", "cross"):
                mk = pmask[(ds, "all" if part == "full" else part)]
                r = at_threshold(get_d(ds)[mk], tr.y[mk], t)
                if part != "dev":
                    r["false_pairs"] = false_pairs(tr, get_d(ds), mk, t)
                row[part][ds] = r
        rng = np.random.default_rng(BOOT_SEED)
        for ds, part in eval_sets:
            tr, mk = truths[ds], pmask[(ds, part)]
            d, y = get_d(ds)[mk], tr.y[mk]
            r = at_threshold(d, y, t)
            bp, br = [], []
            for _ in range(args.boot):
                rb = at_threshold(d, y, t, unit_weights(tr, mk, rng))
                bp.append(rb["precision"])
                br.append(rb["recall"])
            r["precision_ci"], r["recall_ci"] = ci(bp), ci(br)
            r["split"] = part
            r["groups"] = single_linkage(tr, get_d(ds), t, mk)
            r["false_pairs"] = false_pairs(tr, get_d(ds), mk, t)
            rk = Ranked(d, y)
            r["ap_split"] = curve_metrics(*rk.counts(), rk.thr)["ap"]
            if tr.UI is not None and get_u is not None:  # e.g. the other moment of the same clip
                du = get_u(ds)
                r["unscored_linked"] = float((du <= t).mean()) if t is not None else 0.0
                r["unscored_n"] = int(len(du))
            row["eval"][ds] = r
        return row

    def unscored_d(ds, m):
        tr = truths[ds]
        return full[(ds, m)][tr.UI, tr.UJ] if tr.UI is not None else None

    for m in methods:
        results["methods"][m]["transfer"] = transfer(lambda ds, m=m: dist[(ds, m)], lambda ds, m=m: unscored_d(ds, m))

    # The app's own fixed thresholds, applied globally (no time window).
    for m in [x for x in ("apple-fp2-soft", "apple-fp2-raw") if x in methods]:
        results["methods"][m]["app_thresholds_global"] = {
            sens: {ds: at_threshold(dist[(ds, m)], truths[ds].y, link) for ds in pair_names}
            for sens, (_, _, link, _) in SENSITIVITY.items()}

    # Copies and screenshots by transform (the eval split at the transfer threshold; threshold-free
    # AUC of that transform's pairs against all unrelated pairs of the whole set).
    def by_transform(ds: str, meta_file: str, part: str) -> dict:
        tr = truths[ds]
        meta = json.loads((DATA / ds / meta_file).read_text())
        label = np.array([""] * len(tr.y), dtype=object)
        for key, v in meta["pair_transforms"].items():
            a, b = key.split("|")
            label[tr.pair_pos(tr.index[a], tr.index[b])] = v
        assert (label[tr.y] != "").all() and (label[~tr.y] == "").all(), "every positive pair needs a transform"
        coarse = np.array([("copy vs copy" if "+" in v else v) if v else "" for v in label], dtype=object)
        shot = np.array(["screenshot" in v.split("+") and "+" in v for v in label])
        kinds = sorted({v for v in coarse if v and v != "copy vs copy"})
        kinds += ["copy vs copy"] if (coarse == "copy vs copy").any() else []
        extra = ["copy vs copy, one is a screenshot"] if shot.any() else []
        by = {"kinds": kinds + extra, "part": part, "test_n": {}, "all_n": {}, "methods": {}}
        tmask = pmask[(ds, part)]

        def sel_of(k):
            return (coarse == k) if k in kinds else shot

        for k in kinds + extra:
            by["test_n"][k] = int((sel_of(k) & tmask).sum())
            by["all_n"][k] = int(sel_of(k).sum())
        for m in methods:
            d = dist[(ds, m)]
            t = results["methods"][m]["transfer"]["threshold"]
            neg = np.sort(d[~tr.y])
            row = {}
            for k in kinds + extra:
                sel = sel_of(k)
                st = sel & tmask
                hits = int((d[st] <= t).sum()) if t is not None else 0
                rec = hits / int(st.sum()) if st.any() else None
                dp = d[sel]
                lo = np.searchsorted(neg, dp, side="left")
                hi = np.searchsorted(neg, dp, side="right")
                auc = float(((len(neg) - hi) + 0.5 * (hi - lo)).sum() / (len(dp) * len(neg)))
                row[k] = {"recall_test": rec, "recall_cp": clopper_pearson(hits, int(st.sum())), "auc_all": auc}
            by["methods"][m] = row
        return by

    if "copies" in pair_names and (DATA / "copies" / "copies.json").exists():
        results["copies_by_transform"] = by_transform("copies", "copies.json", "test" if "copies" in dev_names else "all")
    if "screenshots" in pair_names and (DATA / "screenshots" / "screenshots.json").exists():
        results["screenshots_by_transform"] = by_transform("screenshots", "screenshots.json", "all")
        # Unrelated pairs called duplicates at the transfer threshold: two screens of one app, or not.
        tr = truths["screenshots"]
        app_of = tr.raw["app_of"]
        apps = np.array([app_of[f] for f in tr.images], dtype=object)
        same_app = (apps[tr.I] == apps[tr.J]) & ~tr.y
        other = ~tr.y & ~same_app
        neg = {}
        for m in methods:
            d, t = dist[("screenshots", m)], results["methods"][m]["transfer"]["threshold"]
            called = d <= t if t is not None else np.zeros(len(d), bool)
            neg[m] = {"same_app_fp": int((called & same_app).sum()), "same_app_n": int(same_app.sum()),
                      "other_fp": int((called & other).sum()), "other_n": int(other.sum()),
                      "closest_same_app": float(d[same_app].min()), "closest_other": float(d[other].min()),
                      "farthest_duplicate": float(d[tr.y].max())}
        results["screenshots_negatives"] = neg

    # photo-triage by how near-identical a series' pairs are. Thirds of the duplicate pairs by a
    # low-level proxy, (pHash + dHash bits) / 2; AP of each third uses all unrelated pairs.
    if "photo-triage" in pair_names and {"phash", "dhash"} <= set(methods):
        tr = truths["photo-triage"]
        y = tr.y
        proxy = (dist[("photo-triage", "phash")] + dist[("photo-triage", "dhash")]) / 2
        cuts = np.quantile(proxy[y], [1 / 3, 2 / 3])
        strata = {"near-identical": y & (proxy <= cuts[0]), "middle": y & (proxy > cuts[0]) & (proxy <= cuts[1]),
                  "recomposed": y & (proxy > cuts[1])}
        th = {"proxy": "(pHash + dHash differing bits) / 2", "cuts": cuts.tolist(),
              "n": {k: int(v.sum()) for k, v in strata.items()}, "methods": {}}
        for m in methods:
            d, t = dist[("photo-triage", m)], results["methods"][m]["transfer"]["threshold"]
            row = {}
            for k, sel in strata.items():
                keep = ~y | sel
                rk = Ranked(d[keep], y[keep])
                row[k] = {"ap": curve_metrics(*rk.counts(), rk.thr)["ap"],
                          "transfer_recall": float((d[sel] <= t).mean()) if t is not None else 0.0}
            th["methods"][m] = row
        results["photo_triage_thirds"] = th

    # 3. Fusion fitted on dev halves.
    print("fusion", file=sys.stderr)
    from sklearn.linear_model import LogisticRegression

    def fit_fusion(feats, feats_u=None) -> dict:
        Xd = np.vstack([feats(ds)[pmask[(ds, "dev")]] for ds in dev_names])
        yd = np.concatenate([truths[ds].y[pmask[(ds, "dev")]] for ds in dev_names])
        mu, sd = Xd.mean(0), Xd.std(0)
        lr = LogisticRegression(C=1.0, max_iter=2000).fit((Xd - mu) / sd, yd)
        score = {ds: -lr.decision_function((feats(ds) - mu) / sd) for ds in pair_names}  # as a distance
        uscore = {ds: -lr.decision_function((feats_u(ds) - mu) / sd) for ds in pair_names
                  if feats_u is not None and truths[ds].UI is not None}
        return {"coef_std": lr.coef_[0].tolist(), "intercept": float(lr.intercept_[0]),
                "transfer": transfer(lambda ds: score[ds], lambda ds: uscore.get(ds))}

    fusion = {}
    for a, b in FUSIONS:
        if a not in methods or b not in methods or not dev_names:
            continue
        fusion[f"{a} + {b}"] = fit_fusion(
            lambda ds, a=a, b=b: np.column_stack([dist[(ds, a)], dist[(ds, b)]]),
            lambda ds, a=a, b=b: np.column_stack([unscored_d(ds, a), unscored_d(ds, b)]))
    # The raw print plus how different the two photos' sharpness is: a learned stand-in for
    # softening (a blurred frame of a burst is far from the sharp one in the raw print).
    if "apple-fp2-raw" in methods and dev_names:
        sharp = {}
        for ds in pair_names:
            sig = json.loads((OUT / ds / "signals" / f"{APP}.json").read_text())["signals"]
            sharp[ds] = np.array([sig[f]["sharpness"] for f in truths[ds].images], dtype=np.float64)

        def sharp_feats(d, s, I, J):
            gap = np.abs(s[I] - s[J])
            return np.column_stack([d, gap, d * gap])

        fusion["apple-fp2-raw + sharpness gap"] = fit_fusion(
            lambda ds: sharp_feats(dist[(ds, "apple-fp2-raw")], sharp[ds], truths[ds].I, truths[ds].J),
            lambda ds: sharp_feats(unscored_d(ds, "apple-fp2-raw"), sharp[ds], truths[ds].UI, truths[ds].UJ))
    results["fusion"] = fusion

    # AP of every single method on exactly the splits the fusions are scored on.
    results["split_ap"] = {f"{ds}:{part}": {m: results["methods"][m]["transfer"]["eval"][ds]["ap_split"]
                                             for m in methods} for ds, part in eval_sets}

    # 8. Copy pass: library-wide linking without the time window.
    print("copy pass", file=sys.stderr)
    cp_parts = [(ds, part) for ds, part in (("copies", "test"), ("copies", "full"), ("screenshots", "test"),
                                            ("screenshots", "all")) if ds in pair_names and
                (part in ("full", "all") or ds in devm)]
    rules = ["single", "complete", "mutual-1nn", "mutual-3nn", "two-threshold"]
    screen = {ds: screen_shaped(truths[ds]) for ds, _ in cp_parts}
    copy = {"rules": rules, "parts": [f"{ds}:{p}" for ds, p in cp_parts], "screen_pairs": {}, "methods": {}}
    for ds, part in cp_parts:
        tr = truths[ds]
        S = np.ones(tr.n, bool) if part in ("full", "all") else ~devm[ds]
        both = screen[ds][tr.I] & screen[ds][tr.J] & S[tr.I] & S[tr.J]
        copy["screen_pairs"][f"{ds}:{part}"] = {"pairs": int(both.sum()), "duplicates": int((both & tr.y).sum())}
    for m in methods:
        t = results["methods"][m]["transfer"]["threshold"]
        t_screen = None
        if ("screenshots", "dev") in pmask:  # the screen-shaped threshold: screenshots dev half, P >= 0.99
            tr, sc = truths["screenshots"], screen.get("screenshots")
            sel = pmask[("screenshots", "dev")] & sc[tr.I] & sc[tr.J]
            t_screen = pick_threshold(dist[("screenshots", m)][sel], tr.y[sel], TARGET_PRECISION)
        row = {"threshold": t, "screen_threshold": t_screen, "results": {}}
        for ds, part in cp_parts:
            tr = truths[ds]
            S = np.ones(tr.n, bool) if part in ("full", "all") else ~devm[ds]
            out = {}
            for rule in rules:
                if rule == "two-threshold" and (ds, part) == ("screenshots", "all"):
                    out[rule] = None  # its threshold comes from this set's dev half
                    continue
                out[rule] = copy_pass(tr, full[(ds, m)], dist[(ds, m)], S, rule, t, t_screen, screen[ds])
            row["results"][f"{ds}:{part}"] = out
        copy["methods"][m] = row
    results["copy_pass"] = copy

    # 7. Time window: the app's grouping (Python port) with every embedding.
    print("time window", file=sys.stderr)
    wdates = {ds: np.array([manifest_dates(ds)[f] for f in truths[ds].images]) for ds in names}
    utility = {}
    for ds in names:
        sig = json.loads((OUT / truths[ds].source / "signals" / f"{APP}.json").read_text())["signals"]
        utility[ds] = [bool(sig[f]["isUtility"]) for f in truths[ds].images]
    wparts = []  # (key, dataset, images, dates)
    for ds, part in (("bursts-profile", "test"), ("photo-triage", "all"), (WINDOW_DEV, "dev"), (WINDOW_DEV, "test"),
                     ("gopro-bursts", "all"), ("screenshots", "all")):
        if ds in names and (part == "all" or ds in devm):
            idx = np.arange(truths[ds].n) if part == "all" else np.nonzero(devm[ds] if part == "dev" else ~devm[ds])[0]
            wparts.append((f"{ds}:{part}", ds, idx, wdates[ds]))
    if "copies" in devm:  # what if a copy kept its original's date (as Photos' Duplicate does)?
        tr = truths["copies"]
        dd = wdates["copies"].copy()
        for c, v in json.loads((DATA / "copies" / "copies.json").read_text())["copies"].items():
            dd[tr.index[c]] = wdates["copies"][tr.index[v["original"]]]
        wparts.append(("copies:test, copies dated as their original", "copies", np.nonzero(~devm["copies"])[0], dd))
    sweep_keys = {k for k, ds, _, _ in wparts if not k.startswith(("photo-triage:", "copies:"))}
    calib_key = f"{WINDOW_DEV}:dev"
    window = {"parts": {k: {"dataset": ds, "images": int(len(idx))} for k, ds, idx, _ in wparts},
              "calibration_part": calib_key, "methods": {}, "gtscan_check": []}
    wcache: dict = {}

    def wmat(ds: str, m: str) -> np.ndarray:
        key = (truths[ds].source, m)
        if key not in wcache:
            wcache[key] = window_matrix(truths[truths[ds].source], m, sides[(pair_names[0], m)]["metric"])
        return wcache[key]

    for m in methods:
        metric = sides[(pair_names[0], m)]["metric"]
        Dw = lambda ds: wmat(ds, m)  # noqa: E731
        res = {"configs": {}, "results": {}, "sweeps": {}}
        for key, ds, idx, dd in wparts:
            if key in sweep_keys:
                res["sweeps"][key] = window_sweep(truths[ds], idx, dd, truths[ds].images, Dw(ds), utility[ds],
                                                  WINDOW_TIMING)
        link_a = link_from_threshold(results["methods"][m]["transfer"]["threshold"], metric)
        if link_a is not None:
            res["configs"]["transfer"] = [*WINDOW_TIMING, link_a, link_a * ANCHOR_RATIO_L2]
        link_b = res["sweeps"].get(calib_key, {}).get(f"r{int(WINDOW_TARGET * 100)}_link")
        if link_b is not None:
            res["configs"]["window-dev"] = [*WINDOW_TIMING, link_b, link_b * ANCHOR_RATIO_L2]
        if m.startswith("apple-fp2"):
            for sens in ("balanced", "strict"):
                res["configs"][f"app {sens}"] = list(SENSITIVITY[sens])
        for cname, cfg in res["configs"].items():
            res["results"][cname] = {}
            for key, ds, idx, dd in wparts:
                if key == calib_key:
                    continue
                g = sp.app_groups(idx, dd, truths[ds].images, Dw(ds), tuple(cfg), utility[ds])
                res["results"][cname][key] = score_window(truths[ds], g, idx)
        window["methods"][m] = res
    results["window"] = window

    # 4. App pipeline and 5. best shot.
    if not args.skip_app:
        print("app pipeline (gtscan)", file=sys.stderr)
        results["app_pipeline"] = {ds: app_pipeline(ds, truths[ds], args.force_app) for ds in names}
        for ds, runs in results["app_pipeline"].items():
            for sens, a in runs.items():  # the port must give the app's groups exactly
                cfg = SENSITIVITY[sens]
                g = sp.app_groups(np.arange(truths[ds].n), wdates[ds], truths[ds].images, wmat(ds, APP),
                                  (cfg[0], cfg[1], np.float32(cfg[2]), np.float32(cfg[3])), utility[ds])
                port = sorted(sorted(truths[ds].images[i] for i in x) for x in g)
                a["port_matches"] = port == sorted(a["groups"])
                window["gtscan_check"].append({"dataset": ds, "method": APP, "config": f"app {sens} (analyzer)",
                                               "match": a["port_matches"], "groups": len(port)})
        print("best shot", file=sys.stderr)
        results["best_shot"] = {ds: r for ds in pair_names
                                if (r := best_shot(ds, truths[ds], args.force_app, args.boot))}
        # Other embeddings inside the app itself: gtscan eval/scan --features, link/anchor as calibrated.
        print("gtscan --features", file=sys.stderr)
        feat_runs = {}
        for m in [x for x in GTSCAN_FEATURE_METHODS if x in methods]:
            for ds in [x for x in GTSCAN_FEATURE_DATASETS if x in names]:
                tr = truths[ds]
                feat = write_features(tr, m, OUT / ds / "app" / f"features-{m}.jsonl")
                for cname, cfg in window["methods"][m]["configs"].items():
                    if cname == "app strict":
                        continue
                    assert tuple(cfg[:2]) == SENSITIVITY["balanced"][:2]
                    L, A = float(f"{cfg[2]:.6f}"), float(f"{cfg[3]:.6f}")
                    r = app_run(ds, tr, "balanced", args.force_app,
                                ("--features", str(feat), "--link", f"{L:.6f}", "--anchor", f"{A:.6f}"),
                                f"-{m}-L{L:.6f}-A{A:.6f}")
                    g = sp.app_groups(np.arange(tr.n), wdates[ds], tr.images, wmat(ds, m),
                                      (cfg[0], cfg[1], np.float32(L), np.float32(A)), utility[ds])
                    port = sorted(sorted(tr.images[i] for i in x) for x in g)
                    r["port_matches"] = port == sorted(r["groups"])
                    window["gtscan_check"].append({"dataset": ds, "method": m, "config": cname,
                                                   "match": r["port_matches"], "groups": len(port)})
                    feat_runs.setdefault(m, {}).setdefault(cname, {})[ds] = {
                        k: v for k, v in r.items() if k not in ("groups",)}
        results["gtscan_features"] = feat_runs
        bad = [c for c in window["gtscan_check"] if not c["match"]]
        print(f"  port vs gtscan: {len(window['gtscan_check']) - len(bad)}/{len(window['gtscan_check'])} identical",
              file=sys.stderr)
        for runs in results["app_pipeline"].values():
            for a in runs.values():
                a.pop("groups", None)

    # 6. Integrity: duplicates across datasets.
    print("integrity", file=sys.stderr)
    integrity["duplicate_files"] = duplicate_files(pair_names)
    integrity["cross_dataset_near"] = [
        cross_dataset_near(pair_names, m, results["methods"][m]["transfer"]["threshold"])
        for m in ("sscd", "dinov2-base", "apple-fp2-soft") if m in methods]
    # Hardest negatives by consensus (mean rank of three strong signals), for eyeballing label noise.
    hard = {}
    for ds in pair_names:
        tr = truths[ds]
        consensus = [m for m in ("apple-fp2-soft", "sscd", "dinov2-base") if m in methods]
        rank = np.mean([np.argsort(np.argsort(dist[(ds, m)])) for m in consensus], axis=0)
        neg = np.nonzero(~tr.y)[0]
        top = neg[np.argsort(rank[neg])[:10]]
        posi = np.nonzero(tr.y)[0]
        worst = posi[np.argsort(-rank[posi])[:10]]
        hard[ds] = {"by": consensus,
                    "closest_negatives": [[tr.images[tr.I[k]], tr.images[tr.J[k]]] for k in top],
                    "farthest_positives": [[tr.images[tr.I[k]], tr.images[tr.J[k]]] for k in worst]}
    integrity["hard_pairs"] = hard
    results["integrity"] = integrity

    # Speed / size / license.
    speed = {}
    for m in methods:
        ms = {ds: sides[(ds, m)]["ms_per_image"] for ds in pair_names}
        s = sides[(pair_names[0], m)]
        speed[m] = {"ms_per_image": ms, "ms_median": float(np.median(list(ms.values()))), "device": s["device"],
                    "model_mb": s["model_mb"], "dim": s["dim"], "metric": s["metric"],
                    "license_code": s["license_code"], "license_weights": s["license_weights"]}
    results["speed"] = speed
    results["elapsed_s"] = round(time.perf_counter() - t0, 1)

    (OUT / "results.json").write_text(json.dumps(results, indent=1, default=float) + "\n")
    (OUT / "tables.md").write_text(tables(results, pair_names, methods) + "\n")
    print(f"wrote {OUT / 'results.json'} and {OUT / 'tables.md'} in {results['elapsed_s']}s", file=sys.stderr)
    return 0


def tables(R: dict, names: list[str], methods: list[str]) -> str:
    out = []
    M = R["methods"]
    dev = R["settings"]["dev_datasets"]
    evals = [(ds, "test" if ds in dev else "all") for ds in dev] + [(ds, "all") for ds in names if ds not in dev]
    base = [m for m in methods if m in BASE_METHODS]

    def label(ds, part):
        return f"{ds} ({'test half, held out, same generator' if part == 'test' else 'all'})"

    # Headline.
    hdr = ["Method"]
    for ds in names:
        hdr += [f"{ds} AP [95% CI]", f"{ds} R@P≥.99 transfer (P)"]
    hdr += ["ms/img (M3 Max)", "model MB", "weights", "ship?"]
    rows = []
    for m in methods:
        r = [f"`{m}`"]
        for ds in names:
            pm = M[m]["pair"][ds]
            ev = M[m]["transfer"]["eval"][ds]
            r += [fci(pm["ap"], pm["ap_ci"]), f"{f3(ev['recall'])} ({f3(ev['precision'], 2)})"]
        sp = R["speed"][m]
        r += [f"{sp['ms_median']:.1f}", "0 (in iOS)" if m.startswith("apple") else f"{sp['model_mb']:.0f}" if sp[
            "model_mb"] else "0", SHIP.get(m, ("?", "?"))[0], SHIP.get(m, ("?", "?"))[1]]
        rows.append(r)
    out.append("### Headline\n\nAP: all pairs of the whole dataset, no threshold, no time window. R@P≥.99 transfer: "
               "recall (and the precision actually reached) at the one threshold per method picked for precision ≥ 0.99 "
               "on the dev halves of bursts-profile + copies; reported on their test halves (held out, but from the same "
               "generator) and on all of photo-triage, gopro-bursts and screenshots (never used for any threshold). "
               "The last " + str(len(methods) - len(base)) + " rows are the same models with a fixed square input.\n")
    out.append(md_table(hdr, rows))

    # Input forms.
    have = [(a, m, f) for a, m, f in INPUT_FORMS if m in methods]
    if have:
        ct = R.get("copies_by_transform", {}).get("methods", {})
        tri = R.get("photo_triage_thirds", {}).get("methods", {})
        W = R.get("window", {}).get("methods", {})
        rows = []
        for model, m, form in have:
            r = [model, form, f"`{m}`"] + [f3(M[m]["pair"][ds]["ap"]) for ds in names]
            r.append(f3(ct.get(m, {}).get("screenshot", {}).get("recall_test"), 2) if ct else "n/a")
            r.append(f3(tri.get(m, {}).get("recomposed", {}).get("ap")) if tri else "n/a")
            wt = W.get(m, {}).get("results", {}).get("window-dev", {}).get(f"{WINDOW_DEV}:test")
            r.append(f"{f3(wt['precision'])} / {f3(wt['recall'])}" if wt else "n/a")
            rows.append(r)
        out.append("\n### Input form: the same weights, three ways of feeding the image\n\nA Core ML model on the phone "
                   "has a fixed input shape unless built with flexible shapes, so the aspect-kept SSCD input "
                   "(`sscd`) is not what a simple conversion would ship. AP per dataset; copies 'screenshot' = "
                   "recall of a photo vs its screenshot on the copies test half at the transfer threshold; "
                   "photo-triage recomposed = AP of the least alike third of its series (see below); window = pair "
                   f"P / R on the {WINDOW_DEV} test half inside the app's time window, link calibrated on its dev half.\n")
        out.append(md_table(["Model", "input", "method"] + [f"{ds} AP" for ds in names] +
                            ["copies: photo vs its screenshot, R", "photo-triage recomposed AP", "in-window P / R"],
                            rows))

    # Per dataset.
    for ds in names:
        info = R["datasets"][ds]
        rows = []
        for m in sorted(methods, key=lambda m: -M[m]["pair"][ds]["ap"]):
            pm = M[m]["pair"][ds]
            metric = R["speed"][m]["metric"]
            rows.append([f"`{m}`", fci(pm["ap"], pm["ap_ci"]),
                         "—" if m == APP else fci(pm.get("ap_minus_app"), pm.get("ap_minus_app_ci")),
                         "—" if m == pm["top_method"] else fci(pm.get("ap_minus_top"), pm.get("ap_minus_top_ci")),
                         f3(pm["auc"]), f3(pm.get("r_at_fpr_0.01")), f3(pm.get("r_at_fpr_0.001")),
                         f"{f3(pm['r99'])} @ {fmt_thr(pm['r99_thr'], metric)}",
                         f3(pm["r95"]), f"{f3(pm['f1'])} @ {fmt_thr(pm['f1_thr'], metric)}"])
        top = M[methods[0]]["pair"][ds]["top_method"]
        uns = f" {info['unscored_pairs']} pairs left unscored (two moments of one clip)." if info.get(
            "unscored_pairs") else ""
        out.append(f"\n### {ds}\n\n{info['images']} images, {info['groups']} groups, {info['singles']} singles, "
                   f"{info['positive_pairs']} duplicate pairs, {info['negative_pairs']} other pairs.{uns} Sorted by AP. "
                   f"Differences are paired (same group resamples); top = `{top}`. R@FPR = recall at a false-positive "
                   "rate of 1e-2 / 1e-3 (the looser regime inside a time window). R@P≥.99, R@P≥.95 and best F1 are "
                   "ORACLE numbers (threshold picked on this dataset).\n")
        out.append(md_table(["Method", "AP [95% CI]", f"AP − {APP} [95% CI]", "AP − top [95% CI]", "ROC-AUC",
                             "R@FPR 1e-2", "R@FPR 1e-3", "oracle R@P≥.99 @ thr", "oracle R@P≥.95",
                             "oracle best F1 @ thr"], rows))
        if any("ap_agreement_ge_0.5" in M[m]["pair"][ds] for m in methods):
            rows = [[f"`{m}`", f3(M[m]["pair"][ds]["ap"]), f3(M[m]["pair"][ds]["ap_agreement_ge_0.5"]),
                     f3(M[m]["pair"][ds]["ap_agreement_ge_0.8"])] for m in methods]
            out.append("\nAP against other definitions of a near-duplicate (share of annotators):\n")
            out.append(md_table(["Method", "AP (groups, ≥ 6/10)", "AP (≥ 0.5)", "AP (≥ 0.8)"], rows))

    # photo-triage thirds.
    if "photo_triage_thirds" in R:
        th = R["photo_triage_thirds"]
        ks = list(th["n"])
        rows = [[f"`{m}`"] + [f"{f3(th['methods'][m][k]['ap'])} / {f3(th['methods'][m][k]['transfer_recall'], 2)}"
                              for k in ks] for m in sorted(methods, key=lambda m: -th["methods"][m]["recomposed"]["ap"])]
        out.append("\n### photo-triage: series recall by how alike a series' frames are\n\nphoto-triage truth is "
                   "'same series' (shots of one moment, often recomposed), not 'same photo'. Its duplicate pairs are "
                   f"split into thirds by {th['proxy']} (cuts {th['cuts'][0]:g} and {th['cuts'][1]:g} bits); each "
                   "cell is AP of that third against all unrelated pairs / recall of that third at the transfer "
                   "threshold. Sorted by the recomposed third.\n")
        out.append(md_table(["Method"] + [f"{k} (n={th['n'][k]})" for k in ks], rows))

    # Transfer.
    hdr = ["Method", "threshold", "dev P / R"]
    for ds, part in evals:
        hdr += [f"{ds} ({part}) P [CI]", "R [CI]", "FP/M"]
    rows = []
    for m in methods:
        tf = M[m]["transfer"]
        metric = R["speed"][m]["metric"]
        r = [f"`{m}`", fmt_thr(tf["threshold"], metric),
             f"{f3(tf['dev_pooled']['precision'])} / {f3(tf['dev_pooled']['recall'])}"]
        for ds, _ in evals:
            ev = tf["eval"][ds]
            pcp = f" (CP ≥{ev['precision_cp'][0]:.3f})" if ev["precision"] == 1.0 and ev.get("precision_cp") else ""
            rcp = f" (CP ≥{ev['recall_cp'][0]:.3f})" if ev["recall"] == 1.0 and ev.get("recall_cp") else ""
            r += [fci(ev["precision"], ev["precision_ci"]) + pcp, fci(ev["recall"], ev["recall_ci"]) + rcp,
                  f"{ev['fp_per_million']:.0f}"]
        rows.append(r)
    out.append("\n### Threshold transfer (pair level)\n\nOne threshold per method, picked for precision ≥ 0.99 on the "
               "pooled dev halves, applied unchanged. FP/M = false duplicate calls per million unrelated pairs. "
               "Bootstrap CIs resample groups; where a score is perfect the bootstrap interval collapses, so the "
               "exact (Clopper-Pearson) 95% lower bound is given instead (pairs are not independent, so it is a "
               "floor on the uncertainty).\n")
    out.append(md_table(hdr, rows))

    # Full sets and cross-split pairs of the dev datasets; gopro unscored pairs.
    rows = []
    for m in methods:
        tf = M[m]["transfer"]
        r = [f"`{m}`"]
        for ds in dev:
            fu, cr = tf["full"][ds], tf["cross"][ds]
            r += [f"{f3(fu['precision'])} / {f3(fu['recall'])}", f"{cr['fp']:.0f} of {cr['negatives']:.0f}"]
        g = tf["eval"].get("gopro-bursts", {})
        r.append(f3(g.get("unscored_linked")) if "unscored_linked" in g else "n/a")
        rows.append(r)
    hdr = ["Method"]
    for ds in dev:
        hdr += [f"{ds} full set P / R", f"{ds} false calls on cross-split pairs"]
    hdr.append("gopro: share of other-moment pairs linked")
    out.append("\n### Transfer threshold on the whole dev datasets\n\nThe test half leaves out pairs with one image "
               "in each half; those are all unrelated pairs, so false calls between the halves only show here. Last "
               "column: of the unscored gopro pairs (the other moment of the same clip, seconds later), the share "
               "called duplicates.\n")
    out.append(md_table(hdr, rows))
    if "copies" in dev:
        lines = []
        for m in [x for x in ("sscd", "sscd-skew320", "dinov2-small", "dinov3-small", APP) if x in methods]:
            fps = M[m]["transfer"]["full"]["copies"]["false_pairs"]
            lines.append(f"- `{m}` false pairs on all of copies: " + (", ".join(
                f"{a} / {b} at {d:.3f}" for a, b, d in fps[:5]) or "none"))
        out.append("\n" + "\n".join(lines))

    # Group level.
    hdr = ["Method"] + [f"{ds} ({part}) pair P / R, exact groups, largest cluster" for ds, part in evals]
    rows = []
    for m in methods:
        r = [f"`{m}`"]
        for ds, _ in evals:
            g = M[m]["transfer"]["eval"][ds]["groups"]
            r.append(f"{f3(g['pair_precision'])} / {f3(g['pair_recall'])}, {g['groups_exact']}/{g['groups_total']}, "
                     f"{g['largest_cluster']}")
        rows.append(r)
    out.append("\n### Threshold transfer (group level: single-linkage clusters at the transfer threshold)\n")
    out.append(md_table(hdr, rows))

    # App thresholds, global.
    rows = []
    for m in [x for x in ("apple-fp2-soft", "apple-fp2-raw") if x in methods]:
        for sens, per in M[m]["app_thresholds_global"].items():
            rows.append([f"`{m}`", f"{sens} (link {SENSITIVITY[sens][2]:.2f})"] +
                        [f"{f3(per[ds]['precision'])} / {f3(per[ds]['recall'])}" for ds in names])
    out.append("\n### The app's fixed link thresholds applied to all pairs (no time window)\n\nPair precision / recall "
               "on whole datasets. bursts-profile was used to calibrate these thresholds.\n")
    out.append(md_table(["Signal", "preset"] + names, rows))

    # By transform.
    for key, title in (("copies_by_transform", "copies"), ("screenshots_by_transform", "screenshots")):
        if key not in R:
            continue
        by = R[key]
        ks = by["kinds"]
        part = "test half" if by["part"] == "test" else "whole set"
        hdr = ["Method"] + [f"{k} (n={by['test_n'][k]})" for k in ks]
        rows = [[f"`{m}`"] + [f"{f3(by['methods'][m][k]['recall_test'], 2)} ({f3(by['methods'][m][k]['auc_all'])})"
                              for k in ks] for m in methods]
        out.append(f"\n### {title}: recall by transform\n\nRecall on the {title} {part} at the transfer threshold "
                   "(n = pairs), and in parentheses ROC-AUC of that transform's pairs against all unrelated pairs on "
                   "the whole set (threshold-free). With n = 15-25 pairs a recall of 1.00 has a Clopper-Pearson 95% "
                   "lower bound of 0.78-0.86." + (" Single transforms are original vs copy." if title == "copies" else
                                                  " Recall alone hides the cost: see precision below.") + "\n")
        out.append(md_table(hdr, rows))
    if "screenshots_negatives" in R:
        sn = R["screenshots_negatives"]
        rows = []
        for m in sorted(methods, key=lambda m: M[m]["transfer"]["eval"]["screenshots"]["precision"] or 0, reverse=True):
            v, ev = sn[m], M[m]["transfer"]["eval"]["screenshots"]
            metric = R["speed"][m]["metric"]
            rows.append([f"`{m}`", f"{f3(ev['precision'])} / {f3(ev['recall'])}",
                         f"{v['same_app_fp']} of {v['same_app_n']}", f"{v['other_fp']} of {v['other_n']}",
                         fmt_thr(v["closest_same_app"], metric), fmt_thr(v["closest_other"], metric),
                         fmt_thr(v["farthest_duplicate"], metric)])
        out.append("\n### screenshots: what the transfer threshold calls a duplicate\n\nReal app screenshots, not "
                   "used for any threshold. False calls split into two different screens of the same app (often the "
                   "same screen in another state: one checkmark, an error banner, a typed field) and screens of "
                   "different apps.\n")
        out.append(md_table(["Method", "P / R", "false calls, same app", "false calls, other apps",
                             "closest same-app pair", "closest other pair", "farthest duplicate"], rows))

    # Fusion.
    if R.get("fusion"):
        hdr = ["Signal"] + [f"{ds} ({part}) AP" for ds, part in evals] + \
              [f"{ds} ({part}) P / R at transfer thr" for ds, part in evals]
        rows = []
        singles = sorted({x for n in R["fusion"] for x in n.split(" + ") if x in M},
                         key=lambda x: METHOD_ORDER.index(x) if x in METHOD_ORDER else 99)
        for m in singles:
            tf = M[m]["transfer"]["eval"]
            rows.append([f"`{m}`"] + [f3(tf[ds]["ap_split"]) for ds, _ in evals] +
                        [f"{f3(tf[ds]['precision'])} / {f3(tf[ds]['recall'])}" for ds, _ in evals])
        for n, fu in R["fusion"].items():
            tf = fu["transfer"]["eval"]
            rows.append([f"**{n}**"] + [f3(tf[ds]["ap_split"]) for ds, _ in evals] +
                        [f"{f3(tf[ds]['precision'])} / {f3(tf[ds]['recall'])}" for ds, _ in evals])
        out.append("\n### Fusion (logistic regression, fitted on the dev halves only)\n\nTwo distances; or the raw "
                   "print's distance with the two photos' sharpness gap |s_a − s_b| and their product (a learned "
                   "alternative to softening).\n")
        out.append(md_table(hdr, rows))

    # Copy pass.
    if "copy_pass" in R:
        C = R["copy_pass"]
        for part in C["parts"]:
            rows = []
            for m in methods:
                c = C["methods"][m]
                cells = []
                for rule in C["rules"]:
                    v = c["results"][part][rule]
                    cells.append("—" if v is None else f"{f3(v['pair_precision'])} / {f3(v['pair_recall'])}, "
                                 f"{v['groups_exact']}/{v['groups_total']}, {v['largest_cluster']}")
                metric = R["speed"][m]["metric"]
                rows.append([f"`{m}`", fmt_thr(c["screen_threshold"], metric)] + cells)
            sp_ = C["screen_pairs"][part]
            out.append(f"\n### Copy pass, {part}: library-wide linking without the time window\n\nPair P / R, "
                       "exact groups, largest cluster, at the transfer threshold. single = connected components; "
                       "complete = complete linkage cut at the threshold (every pair in a cluster within it); mutual-k "
                       "= link only if each is among the other's k nearest; two-threshold = single linkage with a "
                       "separate threshold for screen-shaped pairs (both portrait, h/w ≥ "
                       f"{R['settings']['screen_aspect']}), picked for P ≥ 0.99 on the screenshots dev half "
                       f"({sp_['pairs']} screen-shaped pairs here, {sp_['duplicates']} duplicates).\n")
            out.append(md_table(["Method", "screen thr"] + C["rules"], rows))

    # Time window.
    if "window" in R:
        W = R["window"]
        parts = [k for k in W["parts"] if k != W["calibration_part"]]
        rows = []
        for m in methods:
            w = W["methods"][m]
            for cname, per in w["results"].items():
                cfg = w["configs"][cname]
                cells = []
                for k in parts:
                    v = per[k]
                    if k.startswith("screenshots"):
                        cells.append(f"{v['fp']} false pairs")
                    else:
                        cells.append(f"{f3(v['precision'])} / {f3(v['recall'])}" +
                                     (f", {v['unscored_grouped']} other-moment" if v["unscored_grouped"] else ""))
                rows.append([f"`{m}`", f"{cname} ({cfg[2]:.3f}/{cfg[3]:.3f})"] + cells)
        out.append("\n### Inside the app's time window (every embedding through the app's grouping step)\n\n"
                   "series_port.py (SeriesBuilder + Scanner.groups, checked against gtscan) with each embedding "
                   "int8-quantized and compared by Euclidean distance as the app stores it. Configs (link/anchor): "
                   "transfer = the transfer threshold as a link; window-dev = the link with the most recall at "
                   f"in-window pair precision ≥ {WINDOW_TARGET} on {W['calibration_part']} (real series packed "
                   "10-60 s apart); app = the app's own presets (apple prints only). Timing: balanced (maxGap 60 s, "
                   "maxSpan 240 s) except 'app strict'. Cells: pair P / R. screenshots: only false pairs (its "
                   "copies are hours to weeks after the original, so never in a window). The copies part dates each "
                   "copy as its original, as Photos' Duplicate does; real copies (saved, downloaded, screenshotted) "
                   "get a new date and never meet the window.\n")
        out.append(md_table(["Method", "config (link/anchor)"] + parts, rows))
        sk = [k for k in W["methods"][methods[0]]["sweeps"] if not k.startswith("screenshots")]
        rows = [[f"`{m}`"] + [f"{f3(W['methods'][m]['sweeps'][k]['r99'])} / {f3(W['methods'][m]['sweeps'][k]['f1'])}"
                              for k in sk] for m in methods]
        out.append("\nOracle in-window sweeps (link picked on the set itself): recall at pair precision ≥ 0.99 / "
                   "best F1.\n")
        out.append(md_table(["Method"] + sk, rows))
        chk = W.get("gtscan_check", [])
        if chk:
            ok = sum(c["match"] for c in chk)
            out.append(f"\nPort vs gtscan (the Swift code): {ok} of {len(chk)} runs give identical groups.")
    if R.get("gtscan_features"):
        rows = []
        for m, per in R["gtscan_features"].items():
            for cname, by_ds in per.items():
                rows.append([f"`{m}`", cname] + [
                    (f"{f3(v['official']['pair_precision'])} / {f3(v['official']['pair_recall'])}, "
                     f"{v['official']['series_found']}/{v['official']['series_total']}, "
                     f"{f3(v['official']['keeper_accuracy'])}") if (v := by_ds.get(ds)) else "n/a"
                    for ds in GTSCAN_FEATURE_DATASETS])
        out.append("\n### gtscan eval --features: other embeddings inside the app itself\n\nThe app's GroupingEval "
                   "(pair P / R, series found, keeper accuracy), balanced timing, link/anchor as calibrated above. "
                   "Its pair precision counts gopro other-moment pairs as wrong.\n")
        out.append(md_table(["Embedding", "config"] + GTSCAN_FEATURE_DATASETS, rows))

    # App pipeline.
    if "app_pipeline" in R:
        rows = []
        for ds, runs in R["app_pipeline"].items():
            for sens, a in runs.items():
                o = a["official"]
                ms = a["missed_pairs"]
                rows.append([ds, sens, f"{a['analyzed']}/{a['photos']}", f3(o["pair_precision"]), f3(o["pair_recall"]),
                             f"{f3(a['scored_pair_precision'])} ({a['unscored_pairs_grouped']})",
                             f"{o['series_found']}/{o['series_total']}", f3(o["keeper_accuracy"]),
                             f"{f3(a['keeper_accuracy_known_best'])} (n={a['keeper_known_n']})",
                             f"{ms['not_analyzed']} / {ms['beyond_max_span']} / {ms['visual_or_linking']}",
                             "yes" if a.get("port_matches") else "NO"])
        out.append("\n### App pipeline (gtscan eval: capture-time window + SeriesBuilder + ShotScorer)\n\nMissed pairs: "
                   "never analyzed (no other photo within maxGap) / farther apart than maxSpan / within the window but "
                   "not grouped. Scored P leaves out unscored pairs (count in parentheses: gopro other-moment pairs "
                   "grouped). Keeper accuracy (gtscan) counts every found series, with the first file as 'best' "
                   "where none is known; the next column counts only series whose best is known. Port = "
                   "series_port.py gives the same groups.\n")
        out.append(md_table(["Dataset", "sensitivity", "analyzed", "pair P", "pair R", "scored P (unscored)",
                             "series found", "keeper acc. (gtscan)", "keeper acc. (known best)",
                             "missed: not analyzed / span / visual", "port"], rows))

    # Best shot.
    if R.get("best_shot"):
        for ds, bs in R["best_shot"].items():
            rows = []
            for name, r in bs["rankers"].items():
                rows.append([name, fci(r["pairwise"], r["pairwise_ci"]),
                             f3(r.get("pairwise_strong")) + (f" (n={r['n_strong']})" if "n_strong" in r else "")
                             if "pairwise_strong" in r else "—",
                             fci(r["top1"], r["top1_ci"]) if r["top1"] is not None else "—",
                             fci(None, None) if name in ("app (ShotScorer)", "random") else
                             (f"{r['app_minus_this_pairwise_ci'][0]:+.3f} to {r['app_minus_this_pairwise_ci'][1]:+.3f}"
                              if r.get("app_minus_this_pairwise_ci") else "—"),
                             "—" if name in ("app (ShotScorer)", "random") or not r.get("app_minus_this_top1_ci") else
                             f"{r['app_minus_this_top1_ci'][0]:+.3f} to {r['app_minus_this_top1_ci'][1]:+.3f}"])
            out.append(f"\n### Best shot: {ds}\n\nPairwise: {bs['pair_task']}, n = {bs['n_pairs']} pairs in "
                       f"{bs['n_pair_groups']} groups. Top-1: n = {bs['n_top1_groups']} groups. 95% CIs resample groups.\n")
            out.append(md_table(["Ranker", "pairwise accuracy [95% CI]", "strong pairs (ratio ≥ .8 or ≤ .2)",
                                 "top-1 accuracy [95% CI]", "app − this, pairwise [95% CI]",
                                 "app − this, top-1 [95% CI]"], rows))

    # Speed.
    rows = []
    for m in methods:
        sp = R["speed"][m]
        rows.append([f"`{m}`", sp["metric"], str(sp["dim"]), " / ".join(f"{sp['ms_per_image'][ds]:.1f}" for ds in names),
                     sp["device"], "0 (in iOS)" if m.startswith("apple") else f"{sp['model_mb'] or 0:.1f}",
                     sp["license_code"], sp["license_weights"]])
    out.append("\n### Speed, size, licenses\n\nms/img per dataset (" + " / ".join(names) + "), M3 Max, batch 1, warm. "
               "Not iPhone numbers.\n")
    out.append(md_table(["Method", "metric", "dim", "ms/img", "device", "model MB (fp32)", "code license",
                         "weights license"], rows))

    # Integrity.
    I = R["integrity"]
    sk = max(max(abs(x["ap"] - x["sklearn_ap"]), abs(x["auc"] - x["sklearn_auc"])) for x in I["sklearn_check"])
    unit = [v.get("max_norm_error") for per in I["methods"].values() for v in per.values() if "max_norm_error" in v]
    l2n = [(v["norm_min"], v["norm_max"]) for per in I["methods"].values() for v in per.values() if "norm_min" in v]
    dup = I["duplicate_files"]
    wrong = I.get("wrong_direction", [])
    lines = [f"- AP and ROC-AUC match scikit-learn to {sk:.1e} ({len(I['sklearn_check'])} dataset x method checks).",
             "- Duplicates are closer than unrelated pairs on average for every dataset x method" +
             (f" except {', '.join(wrong)}." if wrong else "."),
             "- Embedding ids match truth.json order; distance matrices are symmetric; hashes are unpacked 0/1 bits.",
             f"- Cosine methods are unit-normalized (max norm error {max(unit):.1e}); the l2 (Vision) prints have "
             f"norms {min(a for a, _ in l2n):.3f}-{max(b for _, b in l2n):.3f}, so L2 order is cosine order "
             "to within that spread.",
             f"- {dup['files_hashed']} image files hashed: {len(dup['byte_identical_sets'])} byte-identical sets "
             f"within datasets, {len(dup['cross_dataset_byte_identical'])} across datasets."]
    for c in I["cross_dataset_near"]:
        cl = c["closest"][0]
        lines.append(f"- Cross-dataset pairs within `{c['method']}`'s transfer threshold: {c['pairs_within_threshold']} "
                     f"(closest {cl['a']} vs {cl['b']} at {cl['distance']:.3f}). Pairs are only formed within a "
                     "dataset, so these do not enter any metric.")
    lines.append("- Thresholds come only from the dev halves (transfer, fusion, the in-window link, the screen "
                 "threshold). Columns marked oracle are picked on the set they are reported on.")
    out.append("\n### Integrity checks\n")
    out.append("\n".join(lines))
    return "\n".join(out)


if __name__ == "__main__":
    sys.exit(main())
