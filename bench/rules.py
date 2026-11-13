"""Choose the duplicate-detection rules the app ships, from the benchmark's cached embeddings.

    bench/.venv/bin/python bench/rules.py            # everything; writes out/rules.json, tables to stdout
    bench/.venv/bin/python bench/rules.py --quick    # coarser grids (for a smoke run)

Three questions, each answered with constants the Swift code can copy:

1. Series inside the time window (SeriesBuilder). A handful of simple linking rules over the
   signals the app may compute on the phone: the softened Vision print (today), the plain Vision
   print, DINOv2-small (Apache-2.0, one fixed 224x224 input) and the sharpness measure. Every
   rule's constants are fitted on dev data only: the dev half of photo-triage-tight (real sharp
   series) and the dev half of bursts-profile (synthetic blurry bursts). Held out: the test halves
   of both, and all of gopro-bursts (real camera shake).
2. The library-wide copy pass (no time window): complete linkage on DINOv2, a stricter rule for
   pairs of screen-shaped images, and an optional second signal. Fitted on the dev halves of
   copies and screenshots; scored on their test halves and whole sets. Then both steps are run
   together the way the app would (app_groups: series first, copy sets from what is left, so no
   photo is in two groups) on the copies set and on sets with no copies in them.
3. Which copy to keep, from metadata alone (date, pixels, screenshot or not, file format).

Everything is computed the way the app stores it: unit vectors, int8 QuantizedEmbedding (one
scale per vector), Euclidean distance (series_port.quantize / l2_matrix).

Dense halves. The photo-triage-tight halves that evaluate.py uses keep the full set's clock, so
removing the other half's series leaves longer gaps between some of the remaining series. Each
half is also re-timed with photo-triage-tight's own date model (the next series starts 10-60 s
after the previous one ends, gaps inside a series kept), so every series meets its neighbours
again. Fitting needs both the dense and the cut dev half to pass. In practice the two agree for
every fitted rule; only today's loose softened-print rules score differently.

The whole photo-triage-tight timeline (ptt:all) holds the dev series too, but its false pairs
between a dev series and a test series are pairs no fit has seen. That is where rules fitted on
one half overshoot (RESULTS.md: SSCD 0.986 on the test half, 0.967 on the whole set), so the
shipped family is judged on it as well as on the test halves.
"""

from __future__ import annotations

import argparse
import itertools
import json
import random
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

BENCH = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH))

import evaluate as ev  # noqa: E402  (loaders, splits and scoring shared with the benchmark)
import series_port as sp  # noqa: E402

OUT = ev.OUT
DATA = ev.DATA

# The app's presets today: (maxGap s, maxSpan s, link, anchor), link/anchor in softened-print units.
# The timings stay; the link rules are refitted.
PRESETS = {"strict": (30, 120, 0.40, 0.50), "balanced": (60, 240, 0.55, 0.65), "loose": (180, 900, 0.70, 0.80)}
# Pair precision every dev part must reach (ptt dev-dense, ptt dev, bp dev).
TARGET = {"strict": 1.0, "balanced": 0.99, "loose": 0.95}
# Guard band: the precision target must still hold with every link and anchor constant this much
# larger. Dev precision is a step function with a cliff where the first unrelated series merge, and
# the dev half holds only about a quarter of the hard look-alike neighbours, so a constant fitted
# right at the cliff overshoots on new data. Strict ("Only near-identical") keeps the widest band.
GUARD = {"strict": 0.15, "balanced": 0.05, "loose": 0.05}
# Anchor = link x this. Today's presets use 0.50/0.40, 0.65/0.55 and 0.80/0.70; one ratio (balanced's)
# for every preset keeps the anchors in the same order as the links, and the ratio barely moves
# the results.
ANCHOR_RATIO = {k: PRESETS["balanced"][3] / PRESETS["balanced"][2] for k in PRESETS}
# The dev half of bursts-profile must keep (almost) every burst: pair recall at least this.
BURST_RECALL_FLOOR = 0.97
DENSE_GAP = (10, 60)  # photo-triage-tight's gap between series, seconds
DENSE_SEED = 60

SIGNALS = ["apple-fp2-soft", "apple-fp2-raw", "dinov2-small", "dinov2-small-squash", "dinov2-small-pad",
           "dinov2-small-mean"]
DINO_VARIANTS = ["dinov2-small-squash", "dinov2-small-pad", "dinov2-small", "dinov2-small-mean"]
HASHES = ["phash", "dhash", "pdq"]
SHORT = {"apple-fp2-soft": "soft", "apple-fp2-raw": "raw", "dinov2-small": "dino-crop",
         "dinov2-small-squash": "dino-squash", "dinov2-small-pad": "dino-pad", "dinov2-small-mean": "dino-mean"}


# ---- data ------------------------------------------------------------------------------------


@dataclass
class Part:
    """Some images of one dataset on one timeline: what the window sees."""

    key: str
    ds: str  # the truth (and dates) it is scored against
    idx: np.ndarray
    dates: np.ndarray  # per image of the dataset (only idx matter)
    role: str  # "dev" (fitted on) or "held-out"


@dataclass
class Ctx:
    truths: dict = field(default_factory=dict)
    dates: dict = field(default_factory=dict)
    utility: dict = field(default_factory=dict)
    sharp: dict = field(default_factory=dict)
    devm: dict = field(default_factory=dict)
    W: dict = field(default_factory=dict)  # (source ds, method) -> int8 Euclidean matrix, float32
    flags: dict = field(default_factory=dict)  # (ds, mode) -> screen-like per photo

    def wm(self, ds: str, method: str) -> np.ndarray:
        src = self.truths[ds].source
        key = (src, method)
        if key not in self.W:
            self.W[key] = window_matrix(src, method)
        return self.W[key]


def window_matrix(src: str, method: str) -> np.ndarray:
    """Distances as the app stores and compares them: unit vector, int8 codes, Euclidean.
    Hashes become 0/1 vectors, so their Euclidean distance is sqrt(differing bits)."""
    side = json.loads((OUT / src / f"{method}.json").read_text())
    X = np.load(OUT / src / f"{method}.npz", allow_pickle=False)["X"].astype(np.float32)
    if side["metric"] == "hamming":
        return sp.l2_matrix(X).astype(np.float32)
    if side["metric"] == "cosine":
        X = X / np.linalg.norm(X, axis=1, keepdims=True)
    return sp.l2_matrix(sp.quantize(X)).astype(np.float32)


def load_ctx(datasets=("bursts-profile", "photo-triage", "photo-triage-tight", "gopro-bursts", "copies",
                       "screenshots")) -> Ctx:
    c = Ctx()
    for ds in datasets:
        tr = ev.load_truth(ds)
        c.truths[ds] = tr
        md = ev.manifest_dates(ds)
        c.dates[ds] = np.array([md[f] for f in tr.images])
        sig = json.loads((OUT / tr.source / "signals" / "apple-fp2-soft.json").read_text())["signals"]
        c.utility[ds] = [bool(sig[f]["isUtility"]) for f in tr.images]
        c.sharp[ds] = np.array([sig[f]["sharpness"] for f in tr.images], dtype=np.float32)
    for ds in ("bursts-profile", "copies", "screenshots", "photo-triage-tight"):
        if ds in c.truths:
            c.devm[ds] = ev.dev_mask(c.truths[ds])
    return c


def dense_dates(c: Ctx, ds: str, idx: np.ndarray, seed: str) -> np.ndarray:
    """Re-time the series in idx as photo-triage-tight does: in their order, the next series
    10-60 s after the previous one ends, gaps inside a series kept."""
    tr, old = c.truths[ds], c.dates[ds]
    inside = set(int(i) for i in idx)
    groups = [g for g in tr.groups if all(i in inside for i in g)]
    assert sum(len(g) for g in groups) == len(idx), "dense re-timing needs whole series only"
    groups.sort(key=lambda g: min(old[i] for i in g))
    rng = random.Random(f"{DENSE_SEED}:{seed}")
    out = old.copy()
    clock = min(old[i] for i in idx)
    for k, g in enumerate(groups):
        g = sorted(g, key=lambda i: (old[i], tr.images[i]))
        if k:
            clock += rng.uniform(*DENSE_GAP)
        t0 = old[g[0]]
        for i in g:
            out[i] = clock + (old[i] - t0)
        clock = out[g[-1]]
    return out


def window_parts(c: Ctx) -> dict[str, Part]:
    parts = {}
    ptt = "photo-triage-tight"
    dv = c.devm[ptt]
    dev_idx, test_idx = np.nonzero(dv)[0], np.nonzero(~dv)[0]
    parts["ptt:dev-dense"] = Part("ptt:dev-dense", ptt, dev_idx, dense_dates(c, ptt, dev_idx, "dev"), "dev")
    parts["ptt:dev"] = Part("ptt:dev", ptt, dev_idx, c.dates[ptt], "dev")
    parts["ptt:test-dense"] = Part("ptt:test-dense", ptt, test_idx, dense_dates(c, ptt, test_idx, "test"), "held-out")
    parts["ptt:test"] = Part("ptt:test", ptt, test_idx, c.dates[ptt], "held-out")
    parts["ptt:all"] = Part("ptt:all", ptt, np.arange(c.truths[ptt].n), c.dates[ptt], "mixed")
    bp = "bursts-profile"
    parts["bp:dev"] = Part("bp:dev", bp, np.nonzero(c.devm[bp])[0], c.dates[bp], "dev")
    parts["bp:test"] = Part("bp:test", bp, np.nonzero(~c.devm[bp])[0], c.dates[bp], "held-out")
    parts["bp:all"] = Part("bp:all", bp, np.arange(c.truths[bp].n), c.dates[bp], "mixed")
    parts["gopro:all"] = Part("gopro:all", "gopro-bursts", np.arange(c.truths["gopro-bursts"].n),
                              c.dates["gopro-bursts"], "held-out")
    parts["screens:all"] = Part("screens:all", "screenshots", np.arange(c.truths["screenshots"].n),
                                c.dates["screenshots"], "held-out")
    return parts


# ---- the grouping step, with any pair score ---------------------------------------------------


def build(order: list[int], dates: np.ndarray, L: np.ndarray, tl: float, A: np.ndarray, ta: float,
          max_gap: float, max_span: float, lookback: int = sp.LOOKBACK) -> list[list[int]]:
    """SeriesBuilder.build with a pair score in place of the one embedding distance.

    A photo joins the open group (first photo at most maxSpan earlier) whose nearest of its last
    `lookback` members has the smallest link score L, if that is <= tl and the photo's anchor
    score A to the group's first photo is <= ta. With L = A = one distance matrix and tl, ta =
    link, anchor this is series_port.build exactly (checked in self_check)."""
    open_groups: list[list] = []
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
        row, arow = L[i], A[i]
        target, best = None, np.inf
        for g in open_groups:
            if t - g[1] > max_span:
                continue
            nearest = row[g[0][-lookback:]].min()
            if not (nearest <= tl and nearest < best):
                continue
            if arow[g[0][0]] > ta:
                continue
            best, target = nearest, g
        if target is None:
            open_groups.append([[i], t, t])
        else:
            target[0].append(i)
            target[2] = t
    done += [g[0] for g in open_groups]
    return [g for g in done if len(g) >= 2]


def run_part(c: Ctx, part: Part, timing: tuple[float, float], L, tl, A, ta) -> list[list[int]]:
    """Scanner.groups for one part: candidates (another photo within maxGap), build, drop
    all-utility groups."""
    names = c.truths[part.ds].images
    order = sp.capture_order(list(part.idx), part.dates, names)
    cand = sp.candidates(order, part.dates, timing[0])
    groups = build(cand, part.dates, L, tl, A, ta, timing[0], timing[1])
    u = c.utility[part.ds]
    return [g for g in groups if not all(u[i] for i in g)]


def score(c: Ctx, part: Part, groups) -> dict:
    r = ev.score_window(c.truths[part.ds], groups, part.idx)
    return {k: r[k] for k in ("precision", "recall", "tp", "fp", "positives", "unscored_grouped", "series_found",
                              "series_total", "groups", "largest_group")}


# ---- rules -------------------------------------------------------------------------------------
#
# Every rule turns per-pair signal distances into a link score L (join if L <= tl) and an anchor
# score A (stay if A <= ta). Signals: d[s] = int8 Euclidean distance of signal s.


@dataclass(frozen=True)
class Rule:
    kind: str  # "single", "or", "logistic"
    signals: tuple  # method names
    link: tuple  # per-signal link distances ("single", "or"); weights for "logistic"
    anchor: tuple  # per-signal anchor distances ("single", "or"); () for logistic
    tl: float = 1.0  # logistic: link threshold on the score
    ta: float = 1.0  # logistic: anchor threshold on the score
    bias: float = 0.0  # logistic intercept (included in the score)
    gap: bool = False  # logistic: last weight multiplies |sharpness_a - sharpness_b|
    soft_link: float = 0.0  # logistic: also link if soft <= this (0 = no soft arm)
    soft_anchor: float = 0.0

    def matrices(self, c: Ctx, ds: str):
        if self.kind == "single":
            D = c.wm(ds, self.signals[0])
            return D, float(self.link[0]), D, float(self.anchor[0])
        if self.kind == "or":
            Ds = [c.wm(ds, s) for s in self.signals]
            L = np.minimum.reduce([D / np.float32(a) for D, a in zip(Ds, self.link)])
            A = np.minimum.reduce([D / np.float32(a) for D, a in zip(Ds, self.anchor)])
            return L, 1.0, A, 1.0
        if self.kind == "logistic":
            S = logistic_score(c, ds, self)
            if self.soft_link <= 0:
                return S, self.tl, S, self.ta
            D = c.wm(ds, SOFT)
            L = np.minimum(S / np.float32(self.tl), D / np.float32(self.soft_link))
            A = np.minimum(S / np.float32(self.ta), D / np.float32(self.soft_anchor))
            return L, 1.0, A, 1.0
        raise ValueError(self.kind)

    def scaled(self, f: float) -> "Rule":
        """Every link and anchor constant times f (the guard-band check)."""
        if self.kind == "logistic":
            return Rule(self.kind, self.signals, self.link, self.anchor, self.tl * f, self.ta * f, self.bias, self.gap,
                        self.soft_link * f, self.soft_anchor * f)
        return Rule(self.kind, self.signals, tuple(x * f for x in self.link), tuple(x * f for x in self.anchor))

    def constants(self) -> dict:
        if self.kind == "logistic":
            names = [SHORT[s] for s in self.signals] + (["sharp_gap"] if self.gap else [])
            out = {"weights": dict(zip(names, map(float, self.link))), "link": float(self.tl),
                   "anchor": float(self.ta)}
            if self.soft_link > 0:
                out["soft_arm"] = {"link": round(float(self.soft_link), 4), "anchor": round(float(self.soft_anchor), 4)}
            return out
        return {SHORT[s]: {"link": round(float(a), 4), "anchor": round(float(b), 4)}
                for s, a, b in zip(self.signals, self.link, self.anchor)}

    def describe(self) -> str:
        if self.kind == "single":
            return f"{SHORT[self.signals[0]]} <= {self.link[0]:.3f} (anchor {self.anchor[0]:.3f})"
        if self.kind == "or":
            a = " OR ".join(f"{SHORT[s]} <= {v:.3f}" for s, v in zip(self.signals, self.link))
            b = " OR ".join(f"{SHORT[s]} <= {v:.3f}" for s, v in zip(self.signals, self.anchor))
            return f"link if {a}; anchor if {b}"
        names = [SHORT[s] for s in self.signals] + (["|sharp gap|"] if self.gap else [])
        terms = " + ".join(f"{w:+.3f}*{n}" for w, n in zip(self.link, names))
        arm = (f" OR soft <= {self.soft_link:.3f}" if self.soft_link > 0 else "")
        arm_a = (f" OR soft <= {self.soft_anchor:.3f}" if self.soft_link > 0 else "")
        return f"score = {terms}; link if score <= {self.tl:.3f}{arm}, anchor if score <= {self.ta:.3f}{arm_a}"


def logistic_score(c: Ctx, ds: str, rule: Rule) -> np.ndarray:
    """A linear 'distance': bias + sum w_s d_s (+ w_g |s_a - s_b|). Lower = more alike."""
    S = np.full(c.wm(ds, rule.signals[0]).shape, rule.bias, dtype=np.float32)
    for s, w in zip(rule.signals, rule.link):
        S += np.float32(w) * c.wm(ds, s)
    if rule.gap:
        sh = c.sharp[ds]
        S += np.float32(rule.link[len(rule.signals)]) * np.abs(sh[:, None] - sh[None, :])
    return S


def evaluate_rule(c: Ctx, parts: dict[str, Part], rule: Rule, timing, keys) -> dict:
    out = {}
    cache = {}
    for k in keys:
        p = parts[k]
        if p.ds not in cache:
            cache[p.ds] = rule.matrices(c, p.ds)
        L, tl, A, ta = cache[p.ds]
        out[k] = score(c, p, run_part(c, p, timing, L, tl, A, ta))
    return out


def groups_for(c: Ctx, part: Part, rule: Rule, timing) -> list[list[int]]:
    L, tl, A, ta = rule.matrices(c, part.ds)
    return run_part(c, part, timing, L, tl, A, ta)


def false_pairs_by_half(c: Ctx, groups) -> dict:
    """photo-triage-tight false pairs split by where their two series sit: both dev, both test, or
    one in each (only possible when the halves share a timeline, as in ptt:all)."""
    tr, dv = c.truths["photo-triage-tight"], c.devm["photo-triage-tight"]
    out = {"dev-dev": 0, "test-test": 0, "cross": 0}
    for g in groups:
        for a, b in itertools.combinations(g, 2):
            if tr.unit[a] == tr.unit[b]:
                continue
            out["dev-dev" if dv[a] and dv[b] else "test-test" if not (dv[a] or dv[b]) else "cross"] += 1
    return out


# ---- Task 1: fitting the window rules on dev -----------------------------------------------------

SOFT, RAW = "apple-fp2-soft", "apple-fp2-raw"
DEV_KEYS = ("ptt:dev-dense", "ptt:dev", "bp:dev")
HELD_KEYS = ("ptt:test-dense", "ptt:test", "bp:test", "gopro:all")
WHOLE_KEYS = ("ptt:all", "bp:all", "screens:all")
REPORT_KEYS = DEV_KEYS + HELD_KEYS + WHOLE_KEYS


def grid(lo: float, hi: float, step: float) -> list[float]:
    return [round(float(x), 4) for x in np.arange(lo, hi + step / 2, step)]


GRIDS = {"soft": grid(0.30, 0.80, 0.01), "dino": grid(0.36, 0.90, 0.01), "or_soft": [0.0] + grid(0.30, 0.55, 0.025),
         "logistic": grid(0.30, 0.80, 0.01)}


def dev_ok(res: dict, target: float, bursts: bool = True) -> bool:
    """Every dev part at the precision target, and (bursts) bp dev keeps its bursts."""
    if any(res[k]["precision"] < target - 1e-9 for k in DEV_KEYS):
        return False
    return not bursts or res["bp:dev"]["recall"] >= BURST_RECALL_FLOOR


def check(c: Ctx, parts, preset: str, rule: Rule, bursts: bool = True) -> tuple[bool, dict]:
    """Does the rule pass on dev: the target at its constants, and again with every constant
    widened by the guard band (precision only)?"""
    timing = PRESETS[preset][:2]
    res = evaluate_rule(c, parts, rule, timing, DEV_KEYS)
    if not dev_ok(res, TARGET[preset], bursts):
        return False, res
    wide = evaluate_rule(c, parts, rule.scaled(1 + GUARD[preset]), timing, DEV_KEYS)
    return dev_ok(wide, TARGET[preset], bursts=False), res


def pick(c: Ctx, parts, preset: str, rules: list[Rule], bursts: bool = True):
    """Of rules ordered tightest first, the passing one with the most ptt dev-dense pair recall
    (the tightest on ties). Returns (rule, dev results) or (None, None)."""
    best, best_res, best_rec = None, None, -1.0
    for r in rules:
        ok, res = check(c, parts, preset, r, bursts)
        rec = res["ptt:dev-dense"]["recall"]
        if ok and rec > best_rec + 1e-12:
            best, best_res, best_rec = r, res, rec
    return best, best_res


def single_rule(sig: str, x: float, preset: str) -> Rule:
    return Rule("single", (sig,), (x,), (round(x * ANCHOR_RATIO[preset], 4),))


def or_rule(dino: str, a: float, b: float, preset: str) -> Rule:
    if a <= 0:
        return single_rule(dino, b, preset)
    r = ANCHOR_RATIO[preset]
    return Rule("or", (SOFT, dino), (a, b), (round(a * r, 4), round(b * r, 4)))


def bounded(g: list[float], ref: float | None, side: str | None) -> list[float]:
    """The grid values allowed by the monotone presets: strict <= balanced <= loose."""
    if ref is None or side is None:
        return g
    return [x for x in g if (x <= ref + 1e-9 if side == "le" else x >= ref - 1e-9)]


def fit_single(c: Ctx, parts, preset: str, sig: str, g: list[float], ref: Rule | None = None,
               side: str | None = None):
    g = bounded(g, ref.link[0] if ref else None, side)
    return pick(c, parts, preset, [single_rule(sig, x, preset) for x in g])


def fit_or(c: Ctx, parts, preset: str, dino: str, ref: Rule | None = None, side: str | None = None):
    """soft <= a OR dino <= b, each signal sized for its own job.

    The DINO link is fitted alone on the real series (bursts not required): the passing link with
    the most ptt dev-dense recall. The softened print then only has to add the blurry bursts DINO
    misses, so its link is the smallest that brings bp dev recall to its best while everything
    still passes. Fitting both jointly for ptt recall alone would push the soft link up for a
    sliver of dev recall, and the softened print's high links are what merge different moments of
    one scene (gopro-bursts; RESULTS.md). ref/side keep the presets monotone (a and b each)."""
    ref_a = ref_b = None
    if ref is not None:
        ref_a, ref_b = (ref.link[0], ref.link[1]) if ref.kind == "or" else (0.0, ref.link[0])
    cands = []
    for b in bounded(GRIDS["dino"], ref_b, side):
        ok, res = check(c, parts, preset, single_rule(dino, b, preset), bursts=False)
        if ok:
            cands.append((res["ptt:dev-dense"]["recall"], -b, b))
    for _, _, b in sorted(cands, reverse=True):  # most recall first, tightest on ties
        found = []
        for a in bounded(GRIDS["or_soft"], ref_a, side):
            ok, res = check(c, parts, preset, or_rule(dino, a, b, preset))
            if ok:
                found.append((res["bp:dev"]["recall"], a, res))
        if found:
            top = max(f[0] for f in found)
            _, a, res = next(f for f in found if f[0] >= top - 1e-12)
            return or_rule(dino, a, b, preset), res
    return None, None


def logistic_weights(c: Ctx, parts, preset: str, signals: tuple, gap: bool) -> tuple:
    """Logistic regression (balanced classes) on every dev pair at most maxSpan apart, rescaled to a
    weighted mean distance: score = sum w_s d_s (+ w_g |sharpness gap|), signal weights summing to 1,
    so the score is in distance units and the threshold is fitted like a link distance."""
    from sklearn.linear_model import LogisticRegression

    span = PRESETS[preset][1]
    X, Y = [], []
    for k in ("ptt:dev-dense", "bp:dev"):
        p = parts[k]
        I, J = np.triu_indices(len(p.idx), 1)
        a, b = p.idx[I], p.idx[J]
        near = np.abs(p.dates[a] - p.dates[b]) <= span
        a, b = a[near], b[near]
        cols = [c.wm(p.ds, s)[a, b] for s in signals]
        if gap:
            cols.append(np.abs(c.sharp[p.ds][a] - c.sharp[p.ds][b]))
        X.append(np.stack(cols, 1))
        Y.append(c.truths[p.ds].unit[a] == c.truths[p.ds].unit[b])
    lr = LogisticRegression(class_weight="balanced", max_iter=5000).fit(np.concatenate(X), np.concatenate(Y))
    beta = lr.coef_[0]
    scale = -float(beta[: len(signals)].sum())
    return tuple(round(float(-x / scale), 4) for x in beta)


def fit_logistic(c: Ctx, parts, preset: str, signals: tuple, gap: bool, ref: Rule | None = None,
                 side: str | None = None):
    """The weights are learned once, at balanced timing, and every preset reuses them (one score
    formula in the app, three thresholds)."""
    w = ref.link if ref is not None else logistic_weights(c, parts, "balanced", signals, gap)
    r = ANCHOR_RATIO[preset]
    g = bounded(GRIDS["logistic"], ref.tl if ref is not None else None, side)
    rules = [Rule("logistic", signals, w, (), tl=x, ta=round(x * r, 4), gap=gap) for x in g]
    return pick(c, parts, preset, rules)


def fit_weighted_arm(c: Ctx, parts, preset: str, signals: tuple, ref: Rule | None = None, side: str | None = None):
    """The weighted score OR soft <= a: fit_or's construction with the weighted score in place of
    DINO alone. The score's threshold is fitted on the real series (bursts not required); then the
    smallest soft arm that brings bp dev recall to its best."""
    w = ref.link if ref is not None else logistic_weights(c, parts, "balanced", signals, False)
    r = ANCHOR_RATIO[preset]
    cands = []
    for x in bounded(GRIDS["logistic"], ref.tl if ref is not None else None, side):
        ok, res = check(c, parts, preset, Rule("logistic", signals, w, (), tl=x, ta=round(x * r, 4)), bursts=False)
        if ok:
            cands.append((res["ptt:dev-dense"]["recall"], -x, x))
    for _, _, x in sorted(cands, reverse=True):
        found = []
        for a in bounded(GRIDS["or_soft"], ref.soft_link if ref is not None else None, side):
            rule = Rule("logistic", signals, w, (), tl=x, ta=round(x * r, 4), soft_link=a, soft_anchor=round(a * r, 4))
            ok, res = check(c, parts, preset, rule)
            if ok:
                found.append((res["bp:dev"]["recall"], a, rule, res))
        if found:
            top = max(f[0] for f in found)
            _, _, rule, res = next(f for f in found if f[0] >= top - 1e-12)
            return rule, res
    return None, None


def today_rule(preset: str) -> Rule:
    return Rule("single", (SOFT,), (PRESETS[preset][2],), (PRESETS[preset][3],))


def window_families(dino_variants) -> list[tuple[str, str, callable]]:
    """(name, dino variant or '', fit(c, parts, preset, ref, side)) for every rule family compared."""
    fams = [("today (soft, app constants)", "", lambda c, p, s, ref, side: (today_rule(s), None)),
            ("soft alone, refitted", "", lambda c, p, s, ref, side: fit_single(c, p, s, SOFT, GRIDS["soft"], ref, side))]
    for v in dino_variants:
        fams += [("dino alone", v, lambda c, p, s, ref, side, v=v: fit_single(c, p, s, v, GRIDS["dino"], ref, side)),
                 ("soft OR dino", v, lambda c, p, s, ref, side, v=v: fit_or(c, p, s, v, ref, side)),
                 ("weighted soft+dino", v,
                  lambda c, p, s, ref, side, v=v: fit_logistic(c, p, s, (SOFT, v), False, ref, side)),
                 ("weighted soft+dino OR soft", v,
                  lambda c, p, s, ref, side, v=v: fit_weighted_arm(c, p, s, (SOFT, v), ref, side)),
                 ("weighted soft+raw+dino+|sharp gap|", v,
                  lambda c, p, s, ref, side, v=v: fit_logistic(c, p, s, (SOFT, RAW, v), True, ref, side))]
    return fams


def window_row(c: Ctx, parts, preset: str, name: str, v: str, rule: Rule | None, note: str) -> dict:
    timing = PRESETS[preset][:2]
    row = {"preset": preset, "family": name, "dino": v, "rule": None, "results": None, "note": note}
    if rule is not None:
        res = evaluate_rule(c, parts, rule, timing, REPORT_KEYS)
        g_all = groups_for(c, parts["ptt:all"], rule, timing)
        row.update(rule=rule.describe(), kind=rule.kind, constants=rule.constants(), results=res,
                   ptt_all_false_pairs=false_pairs_by_half(c, g_all), _rule=rule)
    return row


def task_window(c: Ctx, parts, dino_variants) -> list[dict]:
    """Every family at the three presets. Balanced is fitted first; strict is then fitted with each
    constant at most balanced's and loose with each at least balanced's, so moving the slider
    towards "Include similar" never tightens a threshold. If no loose constants at or above
    balanced's reach loose's target, loose keeps balanced's constants (with its longer window)."""
    rows = []
    for name, v, fit in window_families(dino_variants):
        t0 = time.time()
        bal, _ = fit(c, parts, "balanced", None, None)
        fitted = {"balanced": (bal, "fitted")}
        for preset, side in (("strict", "le"), ("loose", "ge")):
            rule, _ = fit(c, parts, preset, bal, side if bal is not None else None)
            note = "fitted" if bal is None or name.startswith("today") else "fitted, monotone"
            if rule is None and preset == "loose" and bal is not None:
                rule, note = Rule(bal.kind, bal.signals, bal.link,
                                  tuple(round(x * ANCHOR_RATIO["loose"] / ANCHOR_RATIO["balanced"], 4)
                                        for x in bal.anchor) if bal.kind != "logistic" else (),
                                  bal.tl, round(bal.tl * ANCHOR_RATIO["loose"], 4), bal.bias, bal.gap,
                                  bal.soft_link, round(bal.soft_link * ANCHOR_RATIO["loose"], 4)), \
                    "target not reached: balanced's links"
            fitted[preset] = (rule, note)
        for preset in PRESETS:
            rule, note = fitted[preset]
            rows.append(window_row(c, parts, preset, name, v, rule, note))
        print(f"  {name:36s} {SHORT.get(v, ''):11s} "
              + " | ".join(f"{p}: {fitted[p][0].describe() if fitted[p][0] else None}" for p in PRESETS)
              + f"  ({time.time() - t0:.1f}s)", file=sys.stderr)
    return rows


# ---- Task 2: the library-wide copy pass ----------------------------------------------------------
#
# Complete linkage over every photo (no time window): two photos end up together only if every pair
# in their cluster passes the rule, so one look-alike can't chain two copy sets into one. A rule is a
# normalized distance N (link if N <= 1):
#   N = d_general / t
#   on screen pairs (both photos screen-like):  N = max(N, d_screen / t_screen)
#   with a confirming signal:                   N = max(N, d_confirm / t_confirm)
# Screen-like = Photos marks it a screenshot, or its long side is at least TALL_ASPECT x its short side.

COPY_TARGET = 0.99  # pair precision on every dev half, also with the thresholds widened by COPY_GUARD
COPY_GUARD = 0.05
TALL_ASPECT = 1.9
COPY_SIGNALS = DINO_VARIANTS + [SOFT, RAW]
SCREEN_SIGNALS = [SOFT, RAW, "pdq", "phash", "dhash"] + DINO_VARIANTS
CONFIRM_SIGNALS = [RAW, SOFT, "pdq"]
# Signals the app computes anyway once DINOv2-small ships (one inference gives CLS and patch mean).
APP_HAS = {SOFT, "dinov2-small", "dinov2-small-mean"}
# A signal the app doesn't compute must find at least this many more dev pairs than the best one it
# does, to be worth a second feature print or a new hash per photo.
NEW_SIGNAL_MIN_GAIN = 2
# Ties go to the cheapest signal.
SIGNAL_COST = {SOFT: 0, "dinov2-small": 0, "dinov2-small-mean": 0, RAW: 1, "dinov2-small-squash": 2,
               "dinov2-small-pad": 2, "pdq": 3, "phash": 3, "dhash": 3}
for _h in HASHES:
    SHORT.setdefault(_h, _h)


def is_hash(method: str) -> bool:
    return method in HASHES


def copy_grid(method: str, wide: bool = False) -> list[float]:
    """Hashes in whole bits (stored as sqrt(bits)); embeddings in steps of 0.005. wide: the whole
    range (a confirming signal may need to accept a photo and its screenshot)."""
    if is_hash(method):
        return [float(np.sqrt(k)) for k in range(0, 257 if wide else 41)]
    return grid(0.01, 1.60 if wide else 0.90, 0.005)


def fmt_t(method: str, t: float) -> str:
    return f"{round(t * t)} bits" if is_hash(method) else f"{t:.3f}"


def sizes_of(c: Ctx, ds: str) -> np.ndarray:
    tr = c.truths[ds]
    s = ev.image_sizes(tr.source, tr.images)
    return np.array([s[f] for f in tr.images], dtype=np.float64)


def screen_flags(c: Ctx, ds: str, mode: str = "kept") -> np.ndarray:
    if (ds, mode) not in c.flags:
        c.flags[(ds, mode)] = _screen_flags(c, ds, mode)
    return c.flags[(ds, mode)]


def _screen_flags(c: Ctx, ds: str, mode: str) -> np.ndarray:
    """Per photo: screen-like, i.e. marked as a screenshot (screenshot_marks) or tall."""
    wh = sizes_of(c, ds)
    tall = wh.max(1) >= TALL_ASPECT * wh.min(1)
    return screenshot_marks(c, ds, mode) | tall


def screenshot_marks(c: Ctx, ds: str, mode: str) -> np.ndarray:
    """Per photo: which photos Photos marks as screenshots.
    screenshots dataset, mode "kept": all (originals, re-screenshots, and copies that kept the
    subtype, as Photos' Duplicate does); mode "lost": only the originals and re-screenshots
    (the re-saved, HEIC and cropped copies were saved by another app and lost it).
    copies dataset: the 'screenshot' copies. Photo datasets: none."""
    tr = c.truths[ds]
    if ds == "screenshots":
        if mode == "kept":
            marked = np.ones(tr.n, bool)
        else:
            meta = json.loads((DATA / "screenshots" / "screenshots.json").read_text())
            marked = np.array([f in meta["screens"] or meta["copies"][f]["transform"] == "rescreenshot"
                               for f in tr.images])
    elif ds == "copies":
        meta = json.loads((DATA / "copies" / "copies.json").read_text())
        marked = np.array([meta["copies"].get(f, {}).get("transform") == "screenshot" for f in tr.images])
    else:
        marked = np.zeros(tr.n, bool)
    return marked


@dataclass(frozen=True)
class CopyRule:
    signal: str
    t: float
    screen_signal: str | None = None
    t_screen: float = 0.0
    confirm: str | None = None
    t_confirm: float = 0.0

    def matrix(self, c: Ctx, ds: str, screen: np.ndarray) -> np.ndarray:
        N = c.wm(ds, self.signal) / np.float32(self.t)
        if self.screen_signal is not None:
            both = screen[:, None] & screen[None, :]
            Ns = c.wm(ds, self.screen_signal) / np.float32(max(self.t_screen, 1e-6))
            N = np.where(both, np.maximum(N, Ns), N)
        if self.confirm is not None:
            N = np.maximum(N, c.wm(ds, self.confirm) / np.float32(max(self.t_confirm, 1e-6)))
        return N

    def with_(self, **kw) -> "CopyRule":
        d = dict(self.__dict__)
        d.update(kw)
        return CopyRule(**d)

    def widened(self, f: float) -> "CopyRule":
        return self.with_(t=self.t * f, t_screen=self.t_screen * f, t_confirm=self.t_confirm * f)

    def describe(self) -> str:
        s = f"complete linkage, {SHORT[self.signal]} <= {self.t:.3f}"
        if self.screen_signal:
            s += f"; screen pairs also {SHORT[self.screen_signal]} <= {fmt_t(self.screen_signal, self.t_screen)}"
        if self.confirm:
            s += f"; every pair also {SHORT[self.confirm]} <= {fmt_t(self.confirm, self.t_confirm)}"
        return s

    def constants(self) -> dict:
        out = {"signal": SHORT[self.signal], "t": round(self.t, 4)}
        if self.screen_signal:
            out["screen"] = {"signal": SHORT[self.screen_signal], "t": round(self.t_screen, 4),
                             "tall_aspect": TALL_ASPECT}
            if is_hash(self.screen_signal):
                out["screen"]["bits"] = round(self.t_screen ** 2)
        if self.confirm:
            out["confirm"] = {"signal": SHORT[self.confirm], "t": round(self.t_confirm, 4)}
            if is_hash(self.confirm):
                out["confirm"]["bits"] = round(self.t_confirm ** 2)
        return out


def complete_labels(N: np.ndarray, idx: np.ndarray, n: int) -> np.ndarray:
    """Complete-linkage clusters of the photos in idx, cut at normalized distance 1; everyone else alone."""
    from scipy.cluster.hierarchy import fcluster, linkage
    from scipy.spatial.distance import squareform

    labels = np.arange(n) + n
    if len(idx) < 2:
        return labels
    Ns = N[np.ix_(idx, idx)].astype(np.float64)
    Ns = np.minimum(Ns, Ns.T)
    np.fill_diagonal(Ns, 0)
    labels[idx] = fcluster(linkage(squareform(Ns, checks=False), method="complete"), 1.0, criterion="distance")
    return labels


def copy_halves(c: Ctx, ds: str) -> dict[str, np.ndarray]:
    dv = c.devm[ds]
    return {"dev": dv, "test": ~dv, "all": np.ones(c.truths[ds].n, bool)}


def copy_score(c: Ctx, ds: str, rule: CopyRule, S: np.ndarray, mode: str = "kept") -> tuple[dict, np.ndarray]:
    N = rule.matrix(c, ds, screen_flags(c, ds, mode))
    labels = complete_labels(N, np.nonzero(S)[0], c.truths[ds].n)
    return ev.score_components(c.truths[ds], S, labels), labels


def copy_ok(c: Ctx, rule: CopyRule, sets: list[str]) -> tuple[bool, dict]:
    """Dev precision >= COPY_TARGET on each dataset in sets, also with every threshold widened."""
    res = {}
    for ds in sets:
        r, _ = copy_score(c, ds, rule, c.devm[ds])
        res[ds] = r
        if (r["pair_precision"] or 0) < COPY_TARGET - 1e-9:
            return False, res
    for ds in sets:
        w, _ = copy_score(c, ds, rule.widened(1 + COPY_GUARD), c.devm[ds])
        if (w["pair_precision"] if w["pair_precision"] is not None else 1) < COPY_TARGET - 1e-9:
            return False, res
    return True, res


def fit_general(c: Ctx, signal: str) -> tuple[CopyRule | None, dict | None]:
    """The general threshold, on copies dev: most pair recall at the target, tightest on ties."""
    best, best_res, best_rec = None, None, -1.0
    for t in grid(0.30, 0.90, 0.01):
        rule = CopyRule(signal, t)
        ok, res = copy_ok(c, rule, ["copies"])
        rec = res["copies"]["pair_recall"] or 0
        if ok and rec > best_rec + 1e-12:
            best, best_res, best_rec = rule, res, rec
    return best, best_res


def fit_screen(c: Ctx, base: CopyRule, sig: str) -> tuple[CopyRule | None, dict | None]:
    """The screen threshold on screenshots dev (every screen pair), keeping copies dev at the target."""
    best, best_res, best_rec = None, None, -1.0
    for t in copy_grid(sig):
        rule = base.with_(screen_signal=sig, t_screen=t)
        ok, res = copy_ok(c, rule, ["screenshots", "copies"])
        rec = res["screenshots"]["pair_recall"] or 0 if "screenshots" in res else 0
        if ok and rec > best_rec + 1e-12:
            best, best_res, best_rec = rule, res, rec
    return best, best_res


def fit_confirm(c: Ctx, base: CopyRule, sig: str) -> tuple[CopyRule | None, dict | None]:
    """The tightest confirming threshold that loses no dev recall on either set, widened by the guard."""
    ref = {ds: copy_score(c, ds, base, c.devm[ds])[0]["pair_recall"] for ds in ("copies", "screenshots")}
    for t in copy_grid(sig, wide=True):
        rule = base.with_(confirm=sig, t_confirm=t)
        res = {ds: copy_score(c, ds, rule, c.devm[ds])[0] for ds in ("copies", "screenshots")}
        if all((res[ds]["pair_recall"] or 0) >= ref[ds] - 1e-12 for ds in res):
            g = t * (1 + COPY_GUARD) if not is_hash(sig) else float(np.sqrt(round(t * t) + 1))
            rule = rule.with_(t_confirm=g)
            return rule, {ds: copy_score(c, ds, rule, c.devm[ds])[0] for ds in res}
    return None, None


def transform_recall(c: Ctx, ds: str, labels: np.ndarray, S: np.ndarray) -> dict:
    """Per transform: copies (in S) that share a cluster with their original."""
    tr = c.truths[ds]
    meta = json.loads((DATA / ds / f"{ds}.json").read_text())["copies"]
    out: dict = {}
    for f, v in meta.items():
        i, j = tr.index[f], tr.index[v["original"]]
        if not (S[i] and S[j]):
            continue
        k = out.setdefault(v["transform"], [0, 0])
        k[0] += int(labels[i] == labels[j])
        k[1] += 1
    return {k: f"{a}/{b}" for k, (a, b) in sorted(out.items())}


def copy_report(c: Ctx, rule: CopyRule) -> dict:
    out = {}
    for ds in ("copies", "screenshots"):
        modes = ("kept", "lost") if ds == "screenshots" else ("kept",)
        for mode in modes:
            for half, S in copy_halves(c, ds).items():
                r, labels = copy_score(c, ds, rule, S, mode)
                key = f"{ds}:{half}" + (f" ({mode})" if ds == "screenshots" else "")
                out[key] = {**r, "transforms": transform_recall(c, ds, labels, S)}
    return out


def app_groups(c: Ctx, ds: str, rule: CopyRule, window: Rule, preset: str, dates: np.ndarray):
    """What the app would show, so no photo sits in two groups (keep/remove choices are stored
    per photo). Series first. Then each copy cluster loses its series photos: two or more left
    make a copy set; exactly one left whose partners all sit in one series joins that series
    (it is a copy of a photo there); anything else is dropped.
    Returns (series groups after joins, copy sets, joins as (photo, series index))."""
    tr = c.truths[ds]
    timing = PRESETS[preset][:2]
    part = Part(ds, ds, np.arange(tr.n), dates, "held-out")
    series = [list(g) for g in groups_for(c, part, window, timing)]
    where = {i: k for k, g in enumerate(series) for i in g}
    _, labels = copy_score(c, ds, rule, np.ones(tr.n, bool))
    sets, joins = [], []
    for l in np.unique(labels):
        cl = np.nonzero(labels == l)[0]
        if len(cl) < 2:
            continue
        rest = [int(i) for i in cl if i not in where]
        homes = {where[i] for i in cl if i in where}
        if len(rest) >= 2:
            sets.append(rest)
        elif len(rest) == 1 and len(homes) == 1:
            joins.append((rest[0], homes.pop()))
    for i, k in joins:
        series[k].append(i)
    return series, sets, joins


def library_hazard(c: Ctx, rule: CopyRule, window: Rule, preset: str = "balanced") -> dict:
    """The copy pass over sets that hold no copies at all, run as app_groups would, so every copy
    set shown or photo joined to a series is either a false copy or a near-identical frame of one
    moment that the series step missed."""
    out = {}
    timing = PRESETS[preset][:2]
    for ds in ("photo-triage", "gopro-bursts", "bursts-profile"):
        tr = c.truths[ds]
        d = c.dates[ds]
        _, labels = copy_score(c, ds, rule, np.ones(tr.n, bool))
        sizes = np.bincount(labels)
        _, sets, joins = app_groups(c, ds, rule, window, preset, d)
        series = [list(g) for g in groups_for(c, Part(ds, ds, np.arange(tr.n), d, "held-out"), window, timing)]
        same = sum(1 for cl in sets for a, b in itertools.combinations(cl, 2) if tr.unit[a] == tr.unit[b])
        other = sum(1 for cl in sets for a, b in itertools.combinations(cl, 2) if tr.unit[a] != tr.unit[b])
        join_same = sum(1 for i, k in joins if any(tr.unit[i] == tr.unit[j] for j in series[k]))
        out[ds] = {"photos": tr.n, "clusters": int((sizes >= 2).sum()), "photos_in_clusters": int(sizes[sizes >= 2].sum()),
                   "copy_sets_shown": len(sets), "photos_in_sets": int(sum(map(len, sets))),
                   "set_pairs_same_series": same, "set_pairs_other_series": other,
                   "sets_within_max_span": sum(1 for cl in sets if d[cl].max() - d[cl].min() <= timing[1]),
                   "joined_to_series": len(joins), "joined_same_series": join_same}
    return out


def copies_end_to_end(c: Ctx, rule: CopyRule, window: Rule, preset: str = "balanced") -> dict:
    """The copies set run as app_groups would, in both date scenarios: how many copy sets end up
    whole in one shown group (a series or a copy set), and what else got grouped."""
    ds = "copies"
    tr = c.truths[ds]
    meta = json.loads((DATA / ds / "copies.json").read_text())
    as_original = c.dates[ds].copy()
    for f, v in meta["copies"].items():
        as_original[tr.index[f]] = c.dates[ds][tr.index[v["original"]]]
    out = {}
    for scen, d in (("as built (copies dated later)", c.dates[ds]), ("copies dated as the original", as_original)):
        series, sets, joins = app_groups(c, ds, rule, window, preset, d)
        home = {i: ("series", k) for k, g in enumerate(series) for i in g}
        home.update({i: ("set", k) for k, g in enumerate(sets) for i in g})
        whole = sum(1 for g in tr.groups if g[0] in home and all(home.get(i) == home[g[0]] for i in g))
        in_series = sum(1 for g in tr.groups if g[0] in home and home[g[0]][0] == "series"
                        and all(home.get(i) == home[g[0]] for i in g))
        truth = {i: k for k, g in enumerate(tr.groups) for i in g}
        shown = [g for g in series + sets]
        tp = sum(1 for g in shown for a, b in itertools.combinations(g, 2) if truth.get(a, -1 - a) == truth.get(b, -1 - b))
        fp = sum(1 for g in shown for a, b in itertools.combinations(g, 2) if truth.get(a, -1 - a) != truth.get(b, -1 - b))
        out[scen] = {"copy_sets": len(tr.groups), "whole": whole, "whole_as_series": in_series,
                     "series_groups": len(series), "copy_sets_shown": len(sets), "joins": len(joins),
                     "pair_precision": round(tp / max(tp + fp, 1), 4), "true_pairs": tp, "false_pairs": fp}
    return out


def task_copies(c: Ctx) -> dict:
    t0 = time.time()
    general = {}
    for sig in COPY_SIGNALS:
        rule, _ = fit_general(c, sig)
        general[sig] = {"rule": rule, "report": copy_report(c, rule) if rule else None}
        print(f"  copy general {SHORT[sig]:11s} {rule.describe() if rule else None}", file=sys.stderr)
    # The shipped signal: most copies dev recall, then the screenshot recall from copies test.
    dino = max((s for s in DINO_VARIANTS if general[s]["rule"]),
               key=lambda s: (general[s]["report"]["copies:dev"]["pair_recall"] or 0,
                              general[s]["report"]["copies:all"]["pair_recall"] or 0, -SIGNAL_COST[s]))
    base = general[dino]["rule"]
    screens = {}
    for sig in SCREEN_SIGNALS:
        rule, res = fit_screen(c, base, sig)
        screens[sig] = {"rule": rule, "dev_recall": res["screenshots"]["pair_recall"] if rule else None}
        print(f"  copy screen  {SHORT[sig]:11s} {rule.describe() if rule else None}", file=sys.stderr)
    ok_s = [s for s in SCREEN_SIGNALS if screens[s]["rule"]]
    n_dev = int(c.truths["screenshots"].y[c.devm["screenshots"][c.truths["screenshots"].I]
                                          & c.devm["screenshots"][c.truths["screenshots"].J]].sum())
    pairs = {s: round((screens[s]["dev_recall"] or 0) * n_dev) for s in ok_s}
    rank = lambda s: (pairs[s], -SIGNAL_COST[s])  # noqa: E731
    have = max((s for s in ok_s if s in APP_HAS), key=rank, default=None)
    new = max((s for s in ok_s if s not in APP_HAS), key=rank, default=None)
    sig = new if have is None or (new is not None and pairs[new] >= pairs[have] + NEW_SIGNAL_MIN_GAIN) else have
    with_screen = screens[sig]["rule"]
    for s in ok_s:
        screens[s]["report"] = copy_report(c, screens[s]["rule"])
        screens[s]["dev_pairs"] = pairs[s]
    # A confirming signal ships only if it raises dev precision where the rule is fitted (both dev
    # halves, screenshot flags kept) without losing dev recall; the 'lost' flags are reported only.
    confirms = {}
    base_dev = {ds: copy_score(c, ds, with_screen, c.devm[ds])[0] for ds in ("copies", "screenshots")}
    shipped_confirm = None
    for s in CONFIRM_SIGNALS:
        rule, dev = fit_confirm(c, with_screen, s)
        gain = rule is not None and any((dev[ds]["pair_precision"] or 0) > (base_dev[ds]["pair_precision"] or 0) + 1e-9
                                        for ds in dev)
        confirms[s] = {"rule": rule, "report": copy_report(c, rule) if rule else None, "raises_dev_precision": gain}
        if gain and shipped_confirm is None and (s in APP_HAS or s == RAW):
            shipped_confirm = s
        print(f"  copy confirm {SHORT[s]:11s} {rule.describe() if rule else None}", file=sys.stderr)
    final = confirms[shipped_confirm]["rule"] if shipped_confirm else with_screen
    print(f"  copies task: {time.time() - t0:.0f}s", file=sys.stderr)
    return {"general": general, "dino": dino, "screens": screens, "screen_signal": sig,
            "with_screen": with_screen, "confirms": confirms, "shipped_confirm": shipped_confirm, "final": final}


# ---- Task 3: which copy to keep -------------------------------------------------------------------

FORMAT_RANK = {"heic": 0, "jpg": 1, "jpeg": 1, "png": 2}  # lower = more likely the camera original


def keeper_table(c: Ctx) -> dict:
    """Each keeper rule on the 150 copy sets, as built (copies dated later) and with every copy dated
    as its original (Photos' Duplicate). Keys sort ascending; the first is kept. 'tie' = the rule
    can't separate the original from another photo of the set."""
    ds = "copies"
    tr = c.truths[ds]
    meta = json.loads((DATA / ds / "copies.json").read_text())
    wh = sizes_of(c, ds)
    pixels = wh[:, 0] * wh[:, 1]
    shot = screen_flags(c, ds)
    fmt = np.array([FORMAT_RANK[f.rsplit(".", 1)[1].lower()] for f in tr.images])
    originals = {i for i, f in enumerate(tr.images) if f in meta["originals"]}
    keys = {"earliest date": lambda d, i: (d[i],),
            "most pixels": lambda d, i: (-pixels[i],),
            "not a screenshot": lambda d, i: (shot[i],),
            "original format (HEIC < JPEG < PNG)": lambda d, i: (fmt[i],),
            "not a screenshot, then most pixels": lambda d, i: (shot[i], -pixels[i]),
            "earliest date, then most pixels": lambda d, i: (d[i], -pixels[i]),
            "not a screenshot, earliest date, most pixels": lambda d, i: (shot[i], d[i], -pixels[i]),
            "not a screenshot, most pixels, earliest date": lambda d, i: (shot[i], -pixels[i], d[i]),
            "not a screenshot, format, most pixels, earliest date": lambda d, i: (shot[i], fmt[i], -pixels[i], d[i])}
    dated_as_original = c.dates[ds].copy()
    for f, v in meta["copies"].items():
        dated_as_original[tr.index[f]] = c.dates[ds][tr.index[v["original"]]]
    out = {}
    for scen, d in (("as built (copies dated later)", c.dates[ds]), ("copies dated as the original", dated_as_original)):
        rows = {}
        for name, key in keys.items():
            n = {"right": 0, "tie": 0, "wrong": 0}
            for g in tr.groups:
                orig = [i for i in g if i in originals]
                assert len(orig) == 1
                ks = {i: key(d, i) for i in g}
                top = min(ks.values())
                best = [i for i in g if ks[i] == top]
                n["right" if best == orig else "tie" if orig[0] in best else "wrong"] += 1
            rows[name] = n
        out[scen] = rows
    return out


# ---- choosing, checking, reporting -------------------------------------------------------------

HELD_PRECISION = 0.985  # balanced, on ptt test, test-dense and the whole timeline
GOPRO_MIN = 53  # gopro-bursts moments found (today: 53/66)
BP_MIN = 28  # bursts-profile bursts found (of 29)


def choose_window(rows: list[dict]) -> tuple | None:
    """The shipped window family, judged at balanced on the held-out sets: pair precision at least
    HELD_PRECISION on photo-triage-tight's test half (as cut and re-timed) and on its whole
    timeline (where dev and test series meet: pairs no fit has seen), gopro and bursts kept; then
    the most test-half recall, gopro moments and bursts. Strict and loose must exist too."""
    fams: dict = {}
    for r in rows:
        fams.setdefault((r["family"], r["dino"]), {})[r["preset"]] = r
    ok = []
    for key, by in fams.items():
        if key[0].startswith("today") or any(by[p]["results"] is None for p in PRESETS):
            continue
        res = by["balanced"]["results"]
        if min(res[k]["precision"] for k in ("ptt:test", "ptt:test-dense", "ptt:all")) < HELD_PRECISION - 1e-9:
            continue
        if res["gopro:all"]["series_found"] < GOPRO_MIN or res["bp:all"]["series_found"] < BP_MIN:
            continue
        ok.append((round(res["ptt:test"]["recall"], 6), res["gopro:all"]["series_found"],
                   res["bp:all"]["series_found"], key))
    return max(ok)[3] if ok else None


def self_check(c: Ctx, parts) -> list[str]:
    """The pieces agree with the benchmark's own code."""
    done = []
    # 1. build == series_port.build for one embedding (the app's SeriesBuilder, ported and checked).
    for k in ("ptt:all", "bp:all", "gopro:all"):
        p = parts[k]
        D = c.wm(p.ds, SOFT)
        names = c.truths[p.ds].images
        order = sp.capture_order(list(p.idx), p.dates, names)
        cand = sp.candidates(order, p.dates, 60)
        ours = build(cand, p.dates, D, 0.55, D, 0.65, 60, 240)
        theirs = sp.build(cand, p.dates, D, 60, 240, 0.55, 0.65)
        assert sorted(map(sorted, ours)) == sorted(map(sorted, theirs)), k
    done.append("build() equals series_port.build on ptt, bp, gopro (soft, balanced)")
    # 2. An OR of one signal with itself is the single rule.
    one = single_rule("dinov2-small-mean", 0.52, "balanced")
    two = Rule("or", ("dinov2-small-mean", "dinov2-small-mean"), (0.52, 0.52), one.anchor * 2)
    a = evaluate_rule(c, parts, one, PRESETS["balanced"][:2], ("ptt:all",))["ptt:all"]
    b = evaluate_rule(c, parts, two, PRESETS["balanced"][:2], ("ptt:all",))["ptt:all"]
    assert a == b
    done.append("OR of a signal with itself equals the single rule")
    # 3. CopyRule without a screen rule == evaluate.copy_pass complete linkage.
    for ds in ("copies", "screenshots"):
        tr = c.truths[ds]
        D = c.wm(ds, "dinov2-small")
        mine, _ = copy_score(c, ds, CopyRule("dinov2-small", 0.59), np.ones(tr.n, bool))
        theirs = ev.copy_pass(tr, D, D[tr.I, tr.J], np.ones(tr.n, bool), "complete", 0.59)
        assert mine == theirs, (ds, mine, theirs)
    done.append("CopyRule (no screen rule) equals evaluate.copy_pass complete linkage")
    # 4. Dense re-timing: whole series, every gap between series 10-60 s, gaps inside kept.
    tr = c.truths["photo-triage-tight"]
    for k in ("ptt:dev-dense", "ptt:test-dense"):
        p = parts[k]
        inside = set(p.idx.tolist())
        gs = sorted((g for g in tr.groups if all(i in inside for i in g)), key=lambda g: p.dates[g].min())
        for g in gs:
            old = np.sort(c.dates["photo-triage-tight"][g])
            assert np.allclose(np.diff(np.sort(p.dates[g])), np.diff(old))
        gaps = [p.dates[b].min() - p.dates[a].max() for a, b in zip(gs, gs[1:])]
        assert min(gaps) >= DENSE_GAP[0] - 1e-6 and max(gaps) <= DENSE_GAP[1] + 1e-6, k
    done.append("dense halves: series kept whole, 10-60 s between series")
    return done


def f3(x) -> str:
    return "—" if x is None else f"{x:.3f}"


def pr(r: dict) -> str:
    return f"{f3(r['precision'])} / {f3(r['recall'])}"


def md(header: list[str], rows: list[list]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(x) for x in r) + " |" for r in rows]
    return "\n".join(out)


def window_tables(rows: list[dict]) -> str:
    head = ["preset", "family", "dino", "rule", "dev-dense P/R", "bp dev R", "test P/R", "test-dense P/R",
            "ptt all P/R, series", "ptt all false pairs (dev/test/cross)", "gopro P/R, moments", "bp all P/R, bursts"]
    body = []
    for r in rows:
        if r["results"] is None:
            body.append([r["preset"], r["family"], SHORT.get(r["dino"], ""), "no rule passes"] + [""] * 8)
            continue
        x = r["results"]
        fp = r["ptt_all_false_pairs"]
        body.append([r["preset"], r["family"], SHORT.get(r["dino"], ""), r["rule"] + ("" if r["note"] in ("fitted", "fitted, monotone") else f" ({r['note']})"),
                     pr(x["ptt:dev-dense"]), f3(x["bp:dev"]["recall"]), pr(x["ptt:test"]), pr(x["ptt:test-dense"]),
                     f"{pr(x['ptt:all'])}, {x['ptt:all']['series_found']}/280",
                     f"{fp['dev-dev']}/{fp['test-test']}/{fp['cross']}",
                     f"{pr(x['gopro:all'])}, {x['gopro:all']['series_found']}/66",
                     f"{pr(x['bp:all'])}, {x['bp:all']['series_found']}/29"])
    return md(head, body)


def copy_rows(rep: dict) -> list:
    keys = ["copies:dev", "copies:test", "copies:all", "screenshots:dev (kept)", "screenshots:test (kept)",
            "screenshots:all (kept)", "screenshots:all (lost)"]

    def cell(r):
        return f"{f3(r['pair_precision'])} / {f3(r['pair_recall'])}, {r['groups_exact']}/{r['groups_total']}"
    return [cell(rep[k]) for k in keys]


COPY_HEAD = ["copies dev", "copies test", "copies all", "screens dev", "screens test", "screens all",
             "screens all, flags lost"]


def to_json(x):
    if isinstance(x, (Rule, CopyRule)):
        return {"describe": x.describe(), "constants": x.constants()}
    if isinstance(x, dict):
        return {str(k): to_json(v) for k, v in x.items() if not str(k).startswith("_")}
    if isinstance(x, (list, tuple)):
        return [to_json(v) for v in x]
    if isinstance(x, (np.integer,)):
        return int(x)
    if isinstance(x, (np.floating,)):
        return float(x)
    if isinstance(x, np.bool_):
        return bool(x)
    return x


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--quick", action="store_true", help="coarser grids, for a smoke run")
    args = ap.parse_args()
    if args.quick:
        for k in GRIDS:
            GRIDS[k] = GRIDS[k][::3] if k != "or_soft" else GRIDS[k][::2]
    t0 = time.time()
    c = load_ctx()
    parts = window_parts(c)
    checks = self_check(c, parts)
    print("self-check: " + "; ".join(checks), file=sys.stderr)

    print("Task 1: window rules", file=sys.stderr)
    rows = task_window(c, parts, DINO_VARIANTS)
    choice = choose_window(rows)
    shipped = {r["preset"]: r for r in rows if (r["family"], r["dino"]) == choice}

    print("Task 2: copy pass", file=sys.stderr)
    cp = task_copies(c)
    window_bal = shipped["balanced"]["_rule"] if shipped else today_rule("balanced")
    hazard = library_hazard(c, cp["final"], window_bal)
    e2e = copies_end_to_end(c, cp["final"], window_bal)

    print("Task 3: keeper", file=sys.stderr)
    keep = keeper_table(c)

    out = {"presets_timing": {k: v[:2] for k, v in PRESETS.items()}, "targets": TARGET, "guard": GUARD,
           "anchor_ratio": ANCHOR_RATIO, "self_check": checks,
           "window": {"rows": rows, "choice": list(choice) if choice else None,
                      "shipped": {p: {"rule": r["rule"], "constants": r["constants"], "note": r["note"]}
                                  for p, r in shipped.items()}},
           "copies": {"general": {SHORT[s]: {"rule": v["rule"], "report": v["report"]} for s, v in cp["general"].items()},
                      "dino": SHORT[cp["dino"]],
                      "screens": {SHORT[s]: v for s, v in cp["screens"].items()},
                      "screen_signal": SHORT[cp["screen_signal"]],
                      "confirms": {SHORT[s]: v for s, v in cp["confirms"].items()},
                      "shipped_confirm": cp["shipped_confirm"], "final": cp["final"],
                      "final_report": copy_report(c, cp["final"]), "library_hazard": hazard,
                      "copies_end_to_end": e2e},
           "keeper": keep, "seconds": round(time.time() - t0, 1)}
    (OUT / "rules.json").write_text(json.dumps(to_json(out), indent=1) + "\n")

    print("## Task 1: window rules (fitted on dev; held out: test halves, gopro)\n")
    print(window_tables(rows))
    print(f"\nShipped family: {choice}\n")
    print("## Task 2: copy pass\n")
    print(md(["general rule"] + COPY_HEAD,
             [[v["rule"].describe() if v["rule"] else f"{SHORT[s]}: none"] + (copy_rows(v["report"]) if v["report"] else [""] * 7)
              for s, v in cp["general"].items()]))
    print()
    print(md(["screen rule (on the shipped general rule)", "dev pairs"] + COPY_HEAD,
             [[v["rule"].describe() if v["rule"] else f"{SHORT[s]}: none", v.get("dev_pairs", "")]
              + (copy_rows(v["report"]) if v.get("report") else [""] * 7) for s, v in cp["screens"].items()]))
    print()
    print(md(["confirming signal", "raises dev precision"] + COPY_HEAD,
             [[v["rule"].describe() if v["rule"] else f"{SHORT[s]}: none", v["raises_dev_precision"]]
              + (copy_rows(v["report"]) if v["report"] else [""] * 7) for s, v in cp["confirms"].items()]))
    fr = copy_report(c, cp["final"])
    print(f"\nShipped copy rule: {cp['final'].describe()}\n")
    print(md(["part", "transforms found (copy shares its original's cluster)"],
             [[k, ", ".join(f"{t} {v}" for t, v in r["transforms"].items())] for k, r in fr.items()]))
    print()
    print(md(["set (no copies in it)", "photos", "clusters (photos)", "copy sets shown (photos)",
              "set pairs same series / other", "sets within maxSpan", "photos joined to a series (same series)"],
             [[ds, h["photos"], f"{h['clusters']} ({h['photos_in_clusters']})",
               f"{h['copy_sets_shown']} ({h['photos_in_sets']})",
               f"{h['set_pairs_same_series']} / {h['set_pairs_other_series']}", h["sets_within_max_span"],
               f"{h['joined_to_series']} ({h['joined_same_series']})"]
              for ds, h in hazard.items()]))
    print()
    print(md(["copies, run as the app would", "copy sets whole in one group", "of them inside a series",
              "series groups", "copy sets shown", "joins", "pair precision (true / false pairs)"],
             [[scen, f"{e['whole']}/{e['copy_sets']}", e["whole_as_series"], e["series_groups"],
               e["copy_sets_shown"], e["joins"], f"{e['pair_precision']:.3f} ({e['true_pairs']} / {e['false_pairs']})"]
              for scen, e in e2e.items()]))
    print("\n## Task 3: keeper (150 copy sets; right / tie / wrong)\n")
    names = list(next(iter(keep.values())))
    print(md(["rule"] + list(keep), [[n] + [f"{keep[s][n]['right']} / {keep[s][n]['tie']} / {keep[s][n]['wrong']}"
                                         for s in keep] for n in names]))
    print(f"\n{time.time() - t0:.0f}s; wrote {OUT / 'rules.json'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
