"""The app's grouping step, ported to Python so any embedding can be put inside its time window.

This follows TidykeepCore exactly:
  SeriesBuilder.candidates  photos with another photo within maxGap seconds (no bursts here)
  SeriesBuilder.build       walk in capture order (date, then file name); close open groups whose
                            last photo is more than maxGap earlier; join the open group (first photo
                            at most maxSpan earlier) whose nearest of its last `lookback` members is
                            closest, if that is <= link and the group's first photo is <= anchor;
                            else start a group. Groups of 2 or more.
  Scanner.groups            drop groups where every photo is always kept (here: every photo is a
                            document, isUtility; folder photos are never favorites or edited)
  QuantizedEmbedding        int8 codes with one scale per vector, Euclidean distance

evaluate.py checks this port against `tkscan scan` (the Swift code) group for group.
"""

from __future__ import annotations

import numpy as np

LOOKBACK = 8  # GroupingConfig.lookback


def quantize(X: np.ndarray) -> np.ndarray:
    """QuantizedEmbedding(vector).dequantized(), in float32 as the app does it."""
    X = np.nan_to_num(np.asarray(X, dtype=np.float32), nan=0.0, posinf=0.0, neginf=0.0)
    peak = np.abs(X).max(axis=1)
    scale = np.where(peak > 0, peak / np.float32(127), np.float32(1)).astype(np.float32)
    q = (X / scale[:, None]).astype(np.float64)  # the division is float32 in Swift
    codes = np.clip(np.sign(q) * np.floor(np.abs(q) + 0.5), -128, 127)  # rounded(): ties away from zero
    return (codes.astype(np.float32) * scale[:, None]).astype(np.float32)


def l2_matrix(V: np.ndarray) -> np.ndarray:
    """Euclidean distances between rows, computed in float64 from float32 vectors."""
    V = V.astype(np.float64)
    sq = (V * V).sum(1)
    D = np.sqrt(np.maximum(sq[:, None] + sq[None, :] - 2 * V @ V.T, 0))
    np.fill_diagonal(D, 0)
    return D


def capture_order(idx, dates, names) -> list[int]:
    return sorted(idx, key=lambda i: (dates[i], names[i]))


def candidates(order: list[int], dates, max_gap: float) -> list[int]:
    keep = [False] * len(order)
    for k in range(1, len(order)):
        if dates[order[k]] - dates[order[k - 1]] <= max_gap:
            keep[k] = keep[k - 1] = True
    return [i for i, ok in zip(order, keep) if ok]


def build(order: list[int], dates, D: np.ndarray, max_gap: float, max_span: float, link: float, anchor: float,
          lookback: int = LOOKBACK) -> list[list[int]]:
    """SeriesBuilder.build over photos already in capture order. D is a full distance matrix."""
    open_groups: list[list] = []  # [members, first date, last date]
    done: list[list[int]] = []
    for i in order:
        t = dates[i]
        still = []
        for g in open_groups:
            if t - g[2] > max_gap:
                done.append(g[0])
            else:
                still.append(g)
        open_groups = still
        row = D[i]
        target, best = None, np.inf
        for g in open_groups:
            if t - g[1] > max_span:
                continue
            nearest = row[g[0][-lookback:]].min()
            if not (nearest <= link and nearest < best):
                continue
            if row[g[0][0]] > anchor:
                continue
            best, target = nearest, g
        if target is None:
            open_groups.append([[i], t, t])
        else:
            target[0].append(i)
            target[2] = t
    done += [g[0] for g in open_groups]
    return [g for g in done if len(g) >= 2]


def app_groups(idx, dates, names, D: np.ndarray, config: tuple, utility=None) -> list[list[int]]:
    """Scanner.groups(from: candidates): the groups the app would show for the photos in idx.

    config = (max_gap, max_span, link, anchor) in the distance units of D."""
    max_gap, max_span, link, anchor = config
    order = capture_order(idx, dates, names)
    cand = candidates(order, dates, max_gap)
    groups = build(cand, dates, D, max_gap, max_span, link, anchor)
    if utility is not None:
        groups = [g for g in groups if not all(utility[i] for i in g)]
    return groups
