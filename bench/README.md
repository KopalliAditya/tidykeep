# Duplicate-photo benchmark

Compares the signal Tidykeep uses to find near-identical photos (Apple Vision's feature print)
with open-source alternatives: perceptual hashes (aHash, pHash, dHash, wHash, PDQ) and learned
image embeddings (CLIP, MobileCLIP, SigLIP 2, DINOv2/v3, SSCD). Each one is also run inside the
app's own grouping step. Everything runs on this Mac.
The only network use is downloading public datasets, models and packages. No personal photos
are used: only public datasets and the images that ship with macOS.

## Layout

```
bench/
  embed.py            runs embedding methods on datasets, writes out/<dataset>/<method>.npz + .json
  embedders/          the methods (apple.py, hashing.py, neural.py), registered in __init__.py
  sanity.py           quick check: are duplicates closer than unrelated pairs?
  aesthetic.py        LAION aesthetic score per image, a best-shot baseline (out/<dataset>/signals/)
  evaluate.py         scores everything (pair metrics, threshold transfer, copy pass, time window,
                      app pipeline, best shot)
  series_port.py      the app's SeriesBuilder in Python, so any embedding can run in its time window
  RESULTS.md          the results and what they mean
  make_smoke.py       builds data/smoke, a 17-image check set from /Library/User Pictures
  datasets/           dataset builders (shared truth.json writer in datasets/common.py)
  requirements.txt    the Python environment
  .venv/ data/ models/ out/   gitignored: environment, datasets, downloaded weights, outputs
```

## Setup

```
uv venv bench/.venv --python 3.12
VIRTUAL_ENV=bench/.venv uv pip install -r bench/requirements.txt
cd TidykeepKit && swift build -c release --product tkscan    # for the apple-* methods
```

Model weights download on first use into `bench/models/` (`HF_HOME`, `TORCH_HOME` and the
open_clip cache all point there). No account or token is needed for any of them.

## Running

```
bench/.venv/bin/python bench/make_smoke.py                       # data/smoke
bench/.venv/bin/python bench/embed.py --list                     # methods and what has been run
bench/.venv/bin/python bench/embed.py --dataset smoke --method all
bench/.venv/bin/python bench/embed.py --dataset all --method sscd,dinov2-small --force
bench/.venv/bin/python bench/sanity.py --dataset smoke --pairs
```

`--dataset` and `--method` take a name, a comma-separated list, or `all`. Existing outputs are
kept unless `--force`. A method that fails is reported and the others carry on (exit code 1
at the end). PyTorch methods use MPS when available (`--device cpu` to force CPU) and fall
back to CPU if an op is missing on MPS.

### Scoring

```
bench/.venv/bin/python bench/aesthetic.py          # LAION aesthetic baseline for the best-shot section
bench/.venv/bin/python bench/evaluate.py           # every built dataset (unbuilt ones skipped); writes out/results.json, out/tables.md
bench/.venv/bin/python bench/evaluate.py --skip-app --boot 100   # embeddings only, quicker CIs
```

`evaluate.py` does the following, and `RESULTS.md` is written from its tables:

- **Pair metrics.** Every pair of images per dataset: AP, ROC-AUC, oracle recall at precision
  0.99/0.95, recall at a false-positive rate of 1e-2/1e-3, best F1, and group-bootstrap CIs.
  Pairs marked `unscored_same` are left out and counted separately.
- **Threshold transfer.** One threshold per method, picked at precision 0.99 on the pooled dev
  halves of bursts-profile and copies, then applied to every test half and to the held-out sets
  (Clopper-Pearson bounds when a score is perfect). It also reports the threshold on the full
  sets and across the split, results by copy transform, and photo-triage in thirds by how much
  the shot changed.
- **Fusion.** Two-signal logistic fusions fitted on the same dev halves.
- **Copy pass.** The app's no-time-window duplicate pass, with five ways to turn distances into
  groups: single linkage, complete linkage, mutual nearest neighbour (1 and 3), and a second,
  tighter threshold for screen-shaped pairs.
- **Time window.** Every embedding inside the app's grouping step, via `series_port.py`: capture
  order, max gap and span, link and anchor distances, int8 quantization. Link distances come
  from the transfer threshold, from a sweep on the photo-triage-tight dev half, or from the
  app's presets. The port is checked group for group against `tkscan scan`, and selected
  embeddings are also run through tkscan itself with `--features`.
- **App pipeline and best shot.** `tkscan eval`/`scan`/`rank`, cached in `out/<dataset>/app/`
  (`--force-app` reruns them).
- **Integrity checks.** ids, metric direction, unit norms, and duplicate files across datasets.

### The app's own pipeline

`tkscan` (in `TidykeepKit`) runs the app's real code on a folder of images:

```
tkscan features <folder|list.txt> <out.jsonl>    # per image: id, embedding, sharpness, aesthetics, isUtility, faceQualities, ms
tkscan rank <images folder> <groups.json> <out.json>   # ranks given groups with PhotoGroup/ShotScorer, best first
tkscan eval <dataset>/images --sensitivity balanced    # the full scan: candidates, SeriesBuilder, ranking
tkscan copies <dataset>/images --json    # the copy pass (CopyFinder + LibraryGroups), scored when there is a truth.json
```

`features` reads each image the way the app's folder source does (CGImageSource thumbnail with
the EXIF transform, 1024 px on the long side) and runs `VisionFrameAnalyzer`; the embedding is
the feature print after the app's int8 quantization. `GT_SOFTEN=0` turns the softening off.
`rank` accepts a list of groups or any JSON with a `"groups"` key, so a dataset's `truth.json`
works directly; photos have no favorites or edits, so the ranking is the analysis alone.
`scan` and `eval` take `--features <file.jsonl>` (lines as `features` writes them, with any
embedding in place of the feature print) and `--link`/`--anchor` (distances in that
embedding's space). That runs another embedding through the app's real scan. `eval` and `copies` score the way
`evaluate.py` does (`score_window`, `score_components`), so their numbers sit next to the
bench's; `swift_parity.py` puts them in its tkscan column. `eval --json` prints the scores
with every wrong keeper.
The apple-* methods also save these ranking signals to `out/<dataset>/signals/<method>.json`.

## Formats

**Dataset** `data/<name>/`:

- `images/`: flat folder of every image, unique file names (jpg, jpeg, png, heic).
- `truth.json`: `name`, `kind` (`near-duplicate`, `copies` or `series`), `source`, `license`,
  `notes`, `images` (file names), `groups` (lists of 2+ files that are duplicates of each other;
  images in no group are singles), and optionally `times` (file to unix seconds), `best`
  (group index to best file), `preferences` (`[better, worse]` pairs), `pair_agreement`
  (`"a|b"` to the fraction of annotators that called the pair a near-duplicate),
  `unscored_same` (pairs to leave out of pair metrics) and `variant_of` (a re-timed copy of
  another dataset, used only by the time window).
- `images/truth.json` and `images/manifest.json`: the same groups and times in tkscan's format,
  so `tkscan eval data/<name>/images` runs the app's pipeline on it. Its optional `scenes`
  (file to scene) comes from `unscored_same`, so tkscan leaves out the same pairs.

Positive pairs are all pairs within a group; every other pair is negative.

**Embeddings** `out/<dataset>/<method>.npz` holds `ids` (file names, in `truth.json` `images`
order) and `X` (float32 `[n, d]`, or uint8 0/1 bits `[n, bits]` for hashes). The sidecar
`<method>.json` has `method`, `metric` (`cosine`, `l2` or `hamming`), `dim`, `ms_per_image`,
`device` (`cpu`, `mps` or `vision`), `model_mb`, `license_code`, `license_weights`, `notes`.
Cosine methods are L2-normalized, so cosine similarity is `X @ X.T`.

## Methods

Timings are on an M3 Max (macOS 27), batch 1, warm, on an already decoded image: the model's
own preprocessing plus the forward pass, median over 30 images. At batch 1 on MPS a call costs
about 7 ms however small the model, so these numbers rank models only roughly and say nothing
about iPhone speed (no Core ML conversion or iPhone profiling here: Command Line Tools only).
Model size is the fp32 size of the image encoder alone (parameters and buffers, 1 MB = 10^6 bytes),
which is what an app would have to ship.

| Method | What | Metric | Dim | MB | ms | Code license | Weights license |
|---|---|---|---|---|---|---|---|
| `apple-fp2-soft` | **The app.** Vision feature print rev 2 of a softened (σ = 0.8% of long side) 1024 px copy, int8 | l2 | 768 | in iOS | 17* | Apache-2.0 (Tidykeep) | Apple OS component |
| `apple-fp2-raw` | The same without softening | l2 | 768 | in iOS | 17* | Apache-2.0 (Tidykeep) | Apple OS component |
| `ahash` | Average hash (imagehash, 8x8) | hamming | 64 | 0 | 0.2 | BSD-2-Clause | none |
| `phash` | DCT perceptual hash (imagehash) | hamming | 64 | 0 | 0.3 | BSD-2-Clause | none |
| `dhash` | Difference hash (imagehash) | hamming | 64 | 0 | 0.2 | BSD-2-Clause | none |
| `whash` | Haar wavelet hash (imagehash) | hamming | 64 | 0 | 2.3 | BSD-2-Clause | none |
| `pdq` | Meta PDQ (pdqhash, matches Meta's reference bit for bit) | hamming | 256 | 0 | 1.7 | BSD-3-Clause (PDQ), MIT (bindings) | none |
| `imagededup-cnn` | imagededup's CNN: MobileNetV3-small ImageNet, pooled features | cosine | 576 | 3.8 | 6.9 | Apache-2.0 recipe, BSD-3 torchvision | BSD-3 (torchvision); ImageNet terms may apply |
| `clip-b32-openai` | OpenCLIP ViT-B-32 `openai` (Immich's default) | cosine | 512 | 351 | 12 | MIT (open_clip) | MIT (OpenAI CLIP) |
| `mobileclip` | Apple MobileCLIP2-S0 (smallest MobileCLIP in open_clip) | cosine | 512 | 46 | 11 | MIT | **Apple ML Research Model license: research only** |
| `siglip2-base` | Google SigLIP 2 B/16 224 px | cosine | 768 | 372 | 13 | Apache-2.0 | Apache-2.0 |
| `dinov2-small` | Meta DINOv2 ViT-S/14, CLS token | cosine | 384 | 88 | 9.2 | Apache-2.0 | Apache-2.0 |
| `dinov2-small-mean` | DINOv2 ViT-S/14, mean of patch tokens | cosine | 384 | 88 | 9.4 | Apache-2.0 | Apache-2.0 |
| `dinov2-base` | DINOv2 ViT-B/14, CLS token | cosine | 768 | 346 | 16 | Apache-2.0 | Apache-2.0 |
| `sscd` | Meta SSCD `sscd_disc_mixup` (ResNet-50), copy detection | cosine | 512 | 98 | 13 | MIT | MIT (repo relicensed from CC-BY-NC on 2022-07-14) |
| `dinov3-small` | Meta DINOv3 ViT-S/16 LVD-1689M, CLS token (timm mirror) | cosine | 384 | 86 | 12 | Apache-2.0 (timm) | **DINOv3 License (Meta custom)** |
| `sscd-skew320` | SSCD on a 320x320 squash of the whole image (fixed shape, as a converted model would take) | cosine | 512 | 98 | 15 | MIT | MIT |
| `sscd-pad320` | SSCD on the whole image letterboxed into 320x320 on its mean colour | cosine | 512 | 98 | 15 | MIT | MIT |
| `dinov2-small-squash` | DINOv2 ViT-S/14 on a 224x224 squash (no crop) | cosine | 384 | 88 | 11 | Apache-2.0 | Apache-2.0 |
| `dinov2-small-pad` | DINOv2 ViT-S/14 letterboxed into 224x224 | cosine | 384 | 88 | 11 | Apache-2.0 | Apache-2.0 |
| `dinov3-small-squash` | DINOv3 ViT-S/16 on a 256x256 squash (no crop) | cosine | 384 | 86 | 12 | Apache-2.0 (timm) | **DINOv3 License (Meta custom)** |

\* The apple-* time is the app's whole `analyze()` call: softening, feature print, aesthetics,
face capture quality and the focus measure. The feature print alone is a fraction of that.

Notes on each:

- **Preprocessing.** Python methods see the image upright (EXIF orientation applied) in RGB,
  with transparency over white, then their own standard transform: open_clip's validation
  transform (CLIP 224 bicubic center crop; MobileCLIP2-S0 256 bilinear center crop), the
  transformers image processor (SigLIP 2: 224x224 squash; DINOv2: short side 256, crop 224),
  SSCD's documented `small_288` (short side 288, no crop), imagededup's `Resize((256,256))` and
  `CenterCrop(224)`, timm's data config for DINOv3 (256 bicubic). Center crops mean those
  models never see the edges of a non-square photo. The `-squash`, `-skew320` and `-pad*`
  variants show the whole image in a fixed square instead: what an on-device model with a
  fixed input shape would see. They show how much each result depends on the input form.
- **clip-b32-openai** is built with `force_quick_gelu=True`. Without it, current open_clip
  builds `ViT-B-32` with plain GELU and loads the OpenAI weights into the wrong activation.
- **mobileclip** is MobileCLIP2-S0 with the image tower reparameterized (same outputs, faster).
  MobileCLIP v1 S0 is not in open_clip. All MobileCLIP and MobileCLIP2 weights are under Apple's
  Machine Learning Research Model license (`LICENSE_MODELS` in apple/ml-mobileclip): scientific
  research only, so the app can't ship them.
- **dinov3-small**: the official `facebook/dinov3-vits16-pretrain-lvd1689m` repo is gated; timm's
  mirror `timm/vit_small_patch16_dinov3.lvd1689m` is not, and carries the same DINOv3 License.
  Read that license before shipping anything built on it.
- **imagededup-cnn** is reimplemented from imagededup 0.3's `MobilenetV3` model (torchvision
  weights, cut at global average pooling) rather than installing imagededup. imagededup's default
  duplicate threshold is cosine similarity 0.9.
- **pdq** fits the image in 512x512 first, as Meta's reference `PDQHasher.fromFile` does. PDQ is
  very sensitive to shifts and crops: on a 512 px picture a 2% reframe flips about 76 of 256 bits,
  while blur or a brightness change flips 0 to 2. The per-image PDQ quality is in the npz as `quality`.
- Hash bits are stored row-major from imagehash's `ImageHash.hash`, and in reference hex-string
  order (most significant bit first) for PDQ.

## Smoke check

`data/smoke` has 12 macOS account pictures, 3 transformed copies (JPEG quality 35, 76% center
crop, mirror image) and one synthetic two-frame near-duplicate (6% reframe, brighter, slightly
blurred). On it every learned embedding, both apple-* methods, ahash and dhash put all 4
duplicate pairs closer than every unrelated pair. whash ties on the crop; phash ranks the crop
and the mirror behind some unrelated pairs; PDQ misses the crop, the mirror and the reframed
pair. `sanity.py --pairs` prints this per method. It is only a check that each method runs and
behaves; 17 images say nothing about which method is best.
