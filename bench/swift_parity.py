"""Does the app's Swift engine reproduce bench/rules.py on the bench datasets?

    bench/.venv/bin/python bench/swift_parity.py           # tables to stdout, out/swift_parity.json
    bench/.venv/bin/python bench/swift_parity.py --features  # re-run `tkscan features` first
    bench/.venv/bin/python bench/swift_parity.py --model X.mlmodelc --variant fp16  # another model build

The Swift side is tkscan, built in release (cd TidykeepKit && swift build -c release --product
tkscan). `tkscan features` analyzes every image as the app does: the softened Vision print and
DINOv2-small through Core ML on the HF crop, int8 as stored. Those vectors are cached in
out/<dataset>/swift/features.jsonl. Each part of a dataset (a split, or the whole set) becomes a
temporary folder of symlinks with the part's dates and screenshot marks in manifest.json, and
`tkscan scan --json` (SeriesBuilder) or `tkscan copies --json` (CopyFinder, LibraryGroups) groups
it. The groups are scored with the bench's own scorers, so only the engine differs.

Four columns per number:
  bench   rules.py's code on the bench's vectors (PyTorch DINOv2 on PIL crops): the reported numbers;
  vectors rules.py's code on the Swift vectors: what the embedder alone changes;
  swift   the Swift engine's groups: what the Swift grouping code changes on top;
  tkscan  tkscan's own scores of those groups (`eval`, `copies`): equal to swift when its scorers
          measure what the bench's do.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

BENCH = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH))

import evaluate as ev  # noqa: E402
import rules as R  # noqa: E402
import series_port as sp  # noqa: E402

TKSCAN = BENCH.parent / "TidykeepKit" / ".build" / "release" / "tkscan"
SOURCES = ("photo-triage", "gopro-bursts", "bursts-profile", "copies", "screenshots")
MEAN, CLS = "dinov2-small-mean", "dinov2-small"
SERIES_KEYS = ("ptt:dev", "ptt:test", "ptt:all", "gopro:all", "bp:all", "screens:all")
SOFT_ONLY_KEYS = ("ptt:test", "ptt:all", "gopro:all", "bp:all")
LINK = {"strict": (0.50, 0.5909), "balanced": (0.55, 0.65), "loose": (0.65, 0.7682)}
SOFT_ONLY = {"strict": (0.50, 0.5909), "balanced": (0.55, 0.65), "loose": (0.58, 0.6855)}
COPY_RULE = R.CopyRule(CLS, 0.59, screen_signal=R.SOFT, t_screen=0.07)


def shipped(preset: str) -> R.Rule:
    tl, ta = LINK[preset]
    return R.Rule("logistic", (R.SOFT, MEAN), (0.3115, 0.6885), (), tl, ta, 0.0, False, 0.35, 0.4136)


def soft_only(preset: str) -> R.Rule:
    tl, ta = SOFT_ONLY[preset]
    return R.Rule("single", (R.SOFT,), (tl,), (ta,))


# ---- Swift vectors ---------------------------------------------------------------------------


MODEL: dict = {}  # GT_DINO_MODEL / GT_DINO_VARIANT for tkscan features, when not the bundled model


def features_path(src: str) -> Path:
    tag = MODEL.get("GT_DINO_VARIANT")
    return R.OUT / src / ("swift" if tag is None else f"swift-{tag}") / "features.jsonl"


def run_features(src: str) -> None:
    out = features_path(src)
    out.parent.mkdir(parents=True, exist_ok=True)
    p = subprocess.run([str(TKSCAN), "features", str(R.DATA / src / "images"), str(out)], capture_output=True, text=True,
                       env=os.environ | MODEL)
    if p.returncode != 0:
        raise RuntimeError(f"tkscan features {src}: {p.stderr[-400:]}")
    print(f"  features {src}: {p.stderr.strip().splitlines()[-1]}", file=sys.stderr)


def swift_ctx(c: R.Ctx) -> R.Ctx:
    """The bench context with the Swift vectors (and the Swift document flag) in place of the bench's."""
    s = R.Ctx(truths=c.truths, dates=c.dates, sharp=c.sharp, devm=c.devm)
    lines = {}
    for src in SOURCES:
        rows = {d["id"]: d for d in map(json.loads, features_path(src).read_text().splitlines())}
        lines[src] = rows
        names = ev.load_truth(src).images
        for method, key in ((R.SOFT, "embedding"), (MEAN, "dinoMean"), (CLS, "dinoCLS")):
            X = np.array([rows[f][key] for f in names], dtype=np.float32)
            s.W[(src, method)] = sp.l2_matrix(sp.quantize(X)).astype(np.float32)  # already int8: unchanged
    for ds, tr in c.truths.items():
        rows = lines[tr.source]
        s.utility[ds] = [bool(rows[f]["isUtility"]) for f in tr.images]
    s.lines = lines
    return s


# ---- Swift engine ----------------------------------------------------------------------------


def iso(t: float) -> str:
    assert abs(t - round(t)) < 1e-6, "manifest dates are whole seconds"
    return datetime.fromtimestamp(round(t), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def part_folder(root: Path, name: str, ds: str, idx, dates, marked=None) -> Path:
    tr = ev.load_truth(ds)
    d = root / name.replace(":", "-").replace(" ", "_")
    d.mkdir(parents=True)
    files = {}
    for i in idx:
        f = tr.images[i]
        os.symlink(R.DATA / ds / "images" / f, d / f)
        files[f] = {"date": iso(dates[i])} | ({"screenshot": True} if marked is not None and marked[i] else {})
    (d / "manifest.json").write_text(json.dumps({"files": files}))
    inside = set(int(i) for i in idx)
    best = tr.raw.get("best", {})
    series = [{"files": [tr.images[i] for i in g], "best": best.get(str(k), tr.images[g[0]])}
              for k, g in enumerate(tr.groups) if all(i in inside for i in g)]
    grouped = {i for g in tr.groups for i in g}
    truth = {"series": series, "singles": [tr.images[i] for i in idx if i not in grouped]}
    if "unscored_same" in tr.raw:  # tkscan eval leaves the same pairs out
        of = tr.raw["unscored_same"]["of"]
        truth["scenes"] = {tr.images[i]: of[tr.images[i]] for i in idx if tr.images[i] in of}
    (d / "truth.json").write_text(json.dumps(truth))
    return d


def tkscan(*args: str) -> dict:
    p = subprocess.run([str(TKSCAN), *args], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"tkscan {' '.join(args[:2])}: {p.stderr[-400:]}")
    return json.loads(p.stdout)


def soft_only_features(src: str, root: Path) -> Path:
    out = root / f"{src}-soft-only.jsonl"
    if not out.exists():
        keep = ("id", "embedding", "sharpness", "aesthetics", "isUtility", "faceQualities")
        rows = [json.dumps({k: d[k] for k in keep}) for d in map(json.loads, features_path(src).read_text().splitlines())]
        out.write_text("\n".join(rows) + "\n")
    return out


def swift_series(c: R.Ctx, part: R.Part, folder: Path, preset: str, features: Path) -> list[list[int]]:
    out = tkscan("scan", str(folder), "--json", "--sensitivity", preset, "--features", str(features))
    index = c.truths[part.ds].index
    return [[index[f] for f in g["ranked"]] for g in out["groups"]]


def tkscan_eval(folder: Path, preset: str, features: Path) -> dict:
    """tkscan's own scores (GroupingEval), which should equal the bench scorer's on the Swift groups."""
    e = tkscan("eval", str(folder), "--json", "--sensitivity", preset, "--features", str(features))
    return {"precision": e["pairPrecision"], "recall": e["pairRecall"], "series_found": e["seriesFound"],
            "unscored_grouped": e["unscoredPairs"]}


def swift_copies(c: R.Ctx, ds: str, folder: Path, preset: str = "balanced") -> dict:
    out = tkscan("copies", str(folder), "--json", "--sensitivity", preset, "--features", str(features_path(c.truths[ds].source)))
    index = c.truths[ds].index
    return {k: [[index[f] for f in g] for g in out[k]] for k in ("clusters", "series", "similarShots", "copies")} | {
        "joined": out["joined"], "eval": out.get("eval")}


def labels_of(n: int, clusters) -> np.ndarray:
    labels = np.arange(n) + n
    for k, g in enumerate(clusters):
        labels[g] = k
    return labels


# ---- the comparison --------------------------------------------------------------------------


def series_rows(c, s, parts, root) -> dict:
    out = {}
    folders = {k: part_folder(root, k, parts[k].ds, parts[k].idx, parts[k].dates) for k in SERIES_KEYS}
    for preset in R.PRESETS:
        timing = R.PRESETS[preset][:2]
        for arm, rule, keys in (("both", shipped(preset), SERIES_KEYS), ("soft only", soft_only(preset), SOFT_ONLY_KEYS)):
            bench = R.evaluate_rule(c, parts, rule, timing, keys)
            vec = R.evaluate_rule(s, parts, rule, timing, keys)
            for k in keys:
                src = c.truths[parts[k].ds].source
                feats = features_path(src) if arm == "both" else soft_only_features(src, root)
                sw = R.score(c, parts[k], swift_series(c, parts[k], folders[k], preset, feats))
                own = tkscan_eval(folders[k], preset, feats)
                out[f"{preset} {arm} {k}"] = {"bench": bench[k], "vectors": vec[k], "swift": sw, "tkscan": own}
    return out


def copy_rows(c, s, root) -> dict:
    out = {}
    for ds in ("copies", "screenshots"):
        for mode in (("kept", "lost") if ds == "screenshots" else ("kept",)):
            marked = R.screenshot_marks(c, ds, mode)  # the shape is tkscan's to see
            for half, S in R.copy_halves(c, ds).items():
                key = f"{ds}:{half}" + (f" ({mode})" if ds == "screenshots" else "")
                bench, _ = R.copy_score(c, ds, COPY_RULE, S, mode)
                vec, _ = R.copy_score(s, ds, COPY_RULE, S, mode)
                got = swift_copies(c, ds, part_folder(root, "cp " + key, ds, np.nonzero(S)[0], c.dates[ds], marked))
                sw = ev.score_components(c.truths[ds], S, labels_of(c.truths[ds].n, got["clusters"]))
                e = got["eval"]
                own = {"pair_precision": e["pairPrecision"], "pair_recall": e["pairRecall"], "false_pairs": e["falsePairs"],
                       "groups_exact": e["setsExact"], "groups_total": e["setsTotal"],
                       "keepers": f"{e['keepersRight']}/{e['keepersScored']}"}
                out[key] = {"bench": bench, "vectors": vec, "swift": sw, "tkscan": own}
    return out


def end_to_end(c, s, root) -> dict:
    """copies_end_to_end and library_hazard, at balanced, from the Swift groups."""
    out = {}
    window = shipped("balanced")
    ds = "copies"
    tr = c.truths[ds]
    meta = json.loads((R.DATA / ds / "copies.json").read_text())
    marked = R.screenshot_marks(c, ds, "kept")
    as_original = c.dates[ds].copy()
    for f, v in meta["copies"].items():
        as_original[tr.index[f]] = c.dates[ds][tr.index[v["original"]]]
    bench = R.copies_end_to_end(c, COPY_RULE, window)
    vec = R.copies_end_to_end(s, COPY_RULE, window)
    for scen, d in (("as built (copies dated later)", c.dates[ds]), ("copies dated as the original", as_original)):
        got = swift_copies(c, ds, part_folder(root, "e2e " + scen.split(" (")[0], ds, np.arange(tr.n), d, marked))
        series, sets = got["series"], got["copies"] + got["similarShots"]
        home = {i: ("series", k) for k, g in enumerate(series) for i in g}
        home.update({i: ("set", k) for k, g in enumerate(sets) for i in g})
        whole = sum(1 for g in tr.groups if g[0] in home and all(home.get(i) == home[g[0]] for i in g))
        as_series = sum(1 for g in tr.groups if g[0] in home and home[g[0]][0] == "series"
                        and all(home.get(i) == home[g[0]] for i in g))
        truth = {i: k for k, g in enumerate(tr.groups) for i in g}
        pairs = [(a, b) for g in series + sets for x, a in enumerate(g) for b in g[x + 1:]]
        tp = sum(1 for a, b in pairs if truth.get(a, -1 - a) == truth.get(b, -1 - b))
        keepers = sum(1 for g in got["copies"] for k, t in enumerate(tr.groups) if set(g) == set(t)
                      and tr.images[g[0]] == tr.raw["best"][str(k)])
        sw = {"whole": whole, "whole_as_series": as_series, "copy_sets_shown": len(sets), "joins": got["joined"],
              "true_pairs": tp, "false_pairs": len(pairs) - tp, "keepers_right": keepers, "copy_sets_as_copies": len(got["copies"])}
        out[f"copies e2e: {scen}"] = {"bench": bench[scen], "vectors": vec[scen], "swift": sw}
    bench_h, vec_h = R.library_hazard(c, COPY_RULE, window), R.library_hazard(s, COPY_RULE, window)
    for ds in ("photo-triage", "gopro-bursts", "bursts-profile"):
        tr = c.truths[ds]
        got = swift_copies(c, ds, part_folder(root, "haz " + ds, ds, np.arange(tr.n), c.dates[ds]))
        sets = got["copies"] + got["similarShots"]
        sw = {"clusters": len(got["clusters"]), "copy_sets_shown": len(sets), "photos_in_sets": sum(map(len, sets)),
              "joined_to_series": got["joined"]}
        out[f"hazard: {ds}"] = {"bench": bench_h[ds], "vectors": vec_h[ds], "swift": sw}
    return out


# ---- tables ----------------------------------------------------------------------------------


def f3(x) -> str:
    return "-" if x is None else f"{x:.3f}"


def cell_series(r: dict) -> str:
    return f"{f3(r['precision'])} / {f3(r['recall'])}, {r['series_found']}"


def cell_copy(r: dict) -> str:
    return f"{f3(r['pair_precision'])} / {f3(r['pair_recall'])}, {r['groups_exact']}/{r['groups_total']}"


def tables(res: dict) -> str:
    lines = ["| Series (P / R, series found) | bench | rules on Swift vectors | Swift engine | tkscan eval |",
             "|---|---|---|---|---|"]
    for k, v in res["series"].items():
        lines.append(f"| {k} | {cell_series(v['bench'])} | {cell_series(v['vectors'])} | {cell_series(v['swift'])} "
                     f"| {cell_series(v['tkscan'])} |")
    lines += ["", "| Copy pass (pair P / R, exact sets) | bench | rules on Swift vectors | Swift engine | tkscan copies (keepers) |",
              "|---|---|---|---|---|"]
    for k, v in res["copies"].items():
        lines.append(f"| {k} | {cell_copy(v['bench'])} | {cell_copy(v['vectors'])} | {cell_copy(v['swift'])} "
                     f"| {cell_copy(v['tkscan'])} ({v['tkscan']['keepers']}) |")
    lines += ["", "| Together, balanced | bench | rules on Swift vectors | Swift engine |", "|---|---|---|---|"]
    for k, v in res["end_to_end"].items():
        keys = [x for x in v["swift"] if x in v["bench"]]
        row = [", ".join(f"{x} {v[col][x]}" for x in keys) for col in ("bench", "vectors", "swift")]
        extra = {x: v["swift"][x] for x in v["swift"] if x not in v["bench"]}
        lines.append(f"| {k} | {row[0]} | {row[1]} | {row[2]}{'; ' + str(extra) if extra else ''} |")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--features", action="store_true", help="re-run tkscan features")
    ap.add_argument("--model", help="a compiled DINOv2 .mlmodelc to use instead of the bundled one")
    ap.add_argument("--variant", help="its weights metadata, e.g. fp16 (also names the cache)")
    a = ap.parse_args()
    if a.model:
        MODEL.update(GT_DINO_MODEL=a.model, GT_DINO_VARIANT=a.variant or "custom")
    if not TKSCAN.exists():
        sys.exit(f"tkscan not built: {TKSCAN}")
    for src in SOURCES:
        if a.features or not features_path(src).exists():
            run_features(src)
    c = R.load_ctx()
    s = swift_ctx(c)
    parts = R.window_parts(c)
    with tempfile.TemporaryDirectory(prefix="gt-parity-") as tmp:
        root = Path(tmp)
        res = {"series": series_rows(c, s, parts, root), "copies": copy_rows(c, s, root), "end_to_end": end_to_end(c, s, root)}
    res["model"] = MODEL or "bundled"
    name = "swift_parity" + (f"-{MODEL['GT_DINO_VARIANT']}" if MODEL else "")
    (R.OUT / f"{name}.json").write_text(json.dumps(R.to_json(res), indent=1) + "\n")
    print(tables(res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
