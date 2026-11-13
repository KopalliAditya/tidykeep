# Benchmark datasets

Builders for the datasets in `bench/data/<name>/`. The data is gitignored and never committed;
rebuild it with the commands below. Only public datasets and the images that ship with macOS
are used, never a personal photo library.

```
bench/.venv/bin/python bench/datasets/build_bursts_profile.py   [--force]
bench/.venv/bin/python bench/datasets/build_photo_triage.py     [--force]
bench/.venv/bin/python bench/datasets/build_copies.py           [--force]
bench/.venv/bin/python bench/datasets/build_gopro_bursts.py     [--force]
bench/.venv/bin/python bench/datasets/build_screenshots.py      [--force]
bench/.venv/bin/python bench/datasets/build_photo_triage_tight.py [--force]   # after build_photo_triage
bench/.venv/bin/python bench/datasets/build_california_nd.py    [--force]   # needs the photos, see below
```

The bursts builder needs tkscan (`cd TidykeepKit && swift build -c release --product tkscan`).
The Photo Triage and copies builders read single files out of the 13.6 GB Kaggle zip with HTTP
Range requests (`remotezip.py`). They fetch about 0.9 GB, need no account, and cache what they
read under `bench/data/_raw/`. The GoPro builder reads about 0.25 GB of single frames out of
`GOPRO_Large.zip` on Hugging Face the same way. The screenshots builder downloads one 0.22 GB
parquet shard. Every random choice uses a fixed seed, so a rebuild gives the same files.

## Format (shared by all datasets)

```
bench/data/<name>/truth.json         name, kind, source, license, notes, images, groups, times,
                                     best?, preferences?, pair_agreement?, plus dataset extras
bench/data/<name>/images/            every image, flat, unique names
bench/data/<name>/images/truth.json  tkscan format {"series":[{"files","best"}],"singles"}
bench/data/<name>/images/manifest.json  {"files":{name:{"date": ISO 8601}}}, read by tkscan
```

- `groups` are disjoint lists of 2 or more files.
- Positive pairs are all pairs within a group. Every other pair is negative.
- `times` holds unix seconds. `best` maps a group index (as a string) to a file.
- `preferences` lists `[better, worse]` pairs.
- `unscored_same` (optional) = `{"label", "of": {file: key}}`. Pairs of files with the same key that are not in one group are left out of pair metrics and reported separately.
- `variant_of` (optional) names another dataset with the same images and groups. Only the time-window evaluation uses such a dataset; it reads the other dataset's embeddings.
- `common.write_dataset` checks every invariant before writing. It rejects unlisted or missing files, overlapping groups, missing times, and a best file outside its group.

## Datasets

| name | kind | images | groups | positive pairs | singles | times | best / preferences |
|---|---|---|---|---|---|---|---|
| bursts-profile | series | 106 | 29 | 119 | 14 | tkscan (synthetic) | best for 29 |
| photo-triage | series | 731 | 280 | 711 | 0 | synthetic | best for 195, 292 preferences |
| copies | copies | 601 | 150 | 501 | 150 | synthetic | best = original |
| gopro-bursts | series | 264 | 66 | 396 (+528 unscored) | 0 | synthetic | best for 66 |
| screenshots | copies | 416 | 100 | 100 | 216 | synthetic | best = original |
| photo-triage-tight | series (time window only) | 731 | 280 | 711 | 0 | synthetic, packed | none |
| california-nd | near-duplicate | 701 | (117 at >= 6 votes) | (2450) | (129) | EXIF | pair_agreement |

### bursts-profile

**What it is.** The app's own calibration set: handheld-burst simulations of the 43 macOS user pictures (`/Library/User Pictures/*/*`).

**How it is built.**
- The sources are copied to a flat folder named `Category-Name.heic`.
- `tkscan bursts` then turns each still into 2-5 frames:
  - 90-96% reframing
  - up to 1.5° of tilt
  - up to 0.3 EV of exposure drift
  - motion or focus blur on every frame except the sharp best one
- Every third still becomes a single (seed 7).
- Frames are 1-3 s apart and moments 6-40 s apart.

**Truth.**
- groups = tkscan's series. best = the unblurred frame. times come from tkscan's manifest.
- `images/truth.json` and `images/manifest.json` are kept exactly as tkscan wrote them.

**License.** Apple system images, used for local evaluation only. Do not redistribute.

**Caveats.**
- The app's thresholds were calibrated on this set, so app-pipeline numbers on it are optimistic.
- Many sources are close-up objects on plain backgrounds. Different objects of similar shape, such as the round tennis ball, basketball, yin-yang and Earth, are the hardest negatives.

### photo-triage

**What it is.** Real consecutive shots from personal albums, with human best-shot preferences.

**Source.** Princeton/Adobe Photo Triage: H. Chang, F. Yu, J. Wang, D. Ashley, A. Finkelstein, "Automatic Triage for a Photo Series", ACM TOG (SIGGRAPH) 35(4), 2016. The site phototriage.cs.princeton.edu is offline. The original package, with its README files, is mirrored at https://www.kaggle.com/datasets/ericwolter/triage.

**Subset.**
- All 195 validation series (503 images), plus 85 of the 967 test series drawn with `random.Random(2016)`.
- File names are `pt<series>-<photo>.jpg`.
- The images are about 0.6 MP. The README says "800x800", but the long side is actually 774-1200 px (median 894).

**Truth.**
- groups = the series as released.
- `preferences` = validation pairs from `train_val/val_pairlist.txt` whose official preference ratio is >= 0.7, or <= 0.3 (flipped).
  - That ratio is the dataset's Bradley-Terry-modelled P(photo1 preferred over photo2) from crowd votes.
  - 0.7 is the threshold the dataset's own `test.m` uses.
- `preference_ratio` stores the ratio for every validation pair, keyed `"a|b"` as P(a preferred).
- best = the rank-1 photo of each validation series (`train_val_series.mat`, field RANK). Test series have no preferences and no best. `group_split` says which split each group came from.
- The raw per-vote review JSONs in the mirror do not reproduce the released ratios (r = 0.26), so they are not used.

**Times.** Synthesized, because the release has no capture times. Photos within a series are 1-4 s apart, and series are 2-8 h apart, in series-id order.

**License.** No open license is stated. Images belong to their owners and the dataset authors. Research use only; cite the paper; do not redistribute.

**Caveats.**
- A "series" is one moment, not one near-identical frame. Some positives are different compositions of the same scene: a wide view next to a close-up, or a different person in front. pHash distance within a group reaches 48 of 64 bits.
- Different series can come from the same trip, so a few negatives may be true near-duplicates. The closest cross-series pairs (pHash 12) were checked and are different scenes.

### copies

**What it is.** The "same photo saved twice" duplicates that phones accumulate. These are not bursts.

**Originals.** One random photo from each of 380 random Photo Triage train-split series (seed 1729).
- That split is disjoint from the validation/test series used in photo-triage. The closest cross-dataset pair is 14 pHash bits apart.
- 4 candidates within 14 bits of another candidate were dropped.
- Then 150 originals were chosen to get copies and 150 to be distractors with none.
- About a third of the originals are stored as HEIC via `sips`, like iPhone captures.

**Copies.** 1-3 per original (48 got 1, 53 got 2, 49 got 3), each made with a different transform:

| transform | what it models | how | copies |
|---|---|---|---|
| reencode | messaging apps | JPEG q70 (cap 1600 px; sources are smaller, so it only re-encodes) | 44 |
| heic_jpeg | export / share format change | `sips` JPEG to HEIC (q80) or HEIC to JPEG (q85) | 38 |
| screenshot | screenshot of the photo | letterboxed in a 1179x2556 PNG with a plain status bar and toolbar, 60% dark | 32 |
| crop | crop in the editor | 5-15% cut off per axis, random split between sides | 28 |
| color | colour edit | saturation x1.3, warm shift (R +6-10%, B -6-10%) | 37 |
| downscale | resized copy | long side 640 px (75% if already <= 640; never upscales) | 36 |
| rotate | straighten | 2-3° either way, cropped to the largest upright rectangle | 42 |
| mirror | front-camera selfie | horizontal flip | 44 |

**Names.** Files have neutral random names (`cp<5 digits>.<ext>`), so the name reveals neither the role nor the transform.

**`copies.json` contents.**
- each copy's original, transform, parameters and delay
- `pair_transforms`, which labels every positive pair:
  - original|copy pairs get the copy's transform
  - copy|copy pairs get `"t1+t2"` (200 of the 501 positive pairs)
- each original's role and its source file in Photo Triage

**Truth.** groups = original plus its copies. best = the original.

**Times.** Originals and distractors are spread over 6 months starting 2025-01-01. Each copy is dated 1 hour to 21 days after its original (log-uniform). A capture-time window therefore misses them on purpose.

**License.** Derived from Photo Triage images, under the same terms: local evaluation only, do not redistribute.

**Caveat.** Screenshot copies share their status-bar and toolbar chrome, which makes unrelated screenshots look alike to pHash (the hardest negatives).

### gopro-bursts

**What it is.** Real camera shake and motion blur, the case the app's softening is for. It is held out: no threshold is picked on it.

**Source.** The GoPro deblurring dataset: S. Nah, T. H. Kim, K. M. Lee, "Deep Multi-scale Convolutional Neural Network for Dynamic Scene Deblurring", CVPR 2017. `GOPRO_Large.zip` is mirrored at https://huggingface.co/datasets/snah/GOPRO_Large. It is handheld GoPro video at 240 fps. Each "blur" frame is the average of 7-13 consecutive frames, which looks like a slow shutter with real shake. Each "sharp" frame is the middle one.

**Subset.**
- All 33 clips (train and test) give two moments, at 15% and 80% of the clip.
- A moment is sharp frame i plus blur frames i, i+3 and i+6: one keeper and three shaky shots.
- Frames are saved as JPEG q92 at 1280x720 under neutral names. `gopro.json` maps them back.

**Truth.**
- groups = the 66 moments. best = the sharp frame.
- Pairs from the two moments of one clip are unscored (`unscored_same`, 528 pairs). They show the same scene a few seconds later, and people would disagree on whether that is one series. The evaluation reports how often each method links them.
- Pairs from different clips are negatives. Clips of one recording (`GOPR0384_11_00` to `_05`, for example) show the same place, so those are hard negatives.

**Times.** Synthesized. Frames of a moment are 1-2 s apart in random order. The second moment is 3-8 s after the first. Clips of one recording are 30-120 s apart, and recordings are 1-6 h apart.

**License.** CC BY 4.0, as tagged on the mirror. Cite the paper.

**Caveats.**
- These are video frames, not phone photos. The blur is real, but the noise, resolution and processing are a GoPro's.
- Each blurred frame is centred at most 6 video frames (25 ms) from the sharp one. The shots are therefore better aligned than handheld stills taken 1-2 s apart would be.

### screenshots

**What it is.** Real app screenshots. Different screens of one app must not be called duplicates, while copies of one screen must be.

**Source.** Rico: B. Deka et al., "Rico: A Mobile App Dataset for Building Data-Driven Design Applications", UIST 2017. The screens come through the Screen2Words release mirrored at https://huggingface.co/datasets/bevaya/RICO-Screen2Words. One parquet shard is used: `data/test-00000-of-00002.parquet`, with 2,155 screens of 653 apps.

**Subset.**
- 120 apps with at least two screens are drawn (seed 1080), and up to 3 screens of each are kept. That gives 316 Android screenshots at 1080x1920.
- 100 of them get one copy each, 25 per transform:

| transform | what it models | how |
|---|---|---|
| resave | sent through a messaging app | JPEG q70 at 60% size |
| heic | format change | `sips` JPEG to HEIC (q80) |
| crop_bars | bars cropped off in the editor | top 63 px and bottom 126 px cut off |
| rescreenshot | screenshot of the screenshot | letterboxed into 1179x2556 on black with a status-bar strip and toolbar, PNG |

**Truth.**
- groups = screenshot + its copy. best = the screenshot.
- `app_of` maps every file to its app. 486 negative pairs are two different screens of the same app, with the same bars, colours and layout but different content. These are the hard negatives.
- The closest negatives were checked by eye. They are the same screen in a different state, such as a ticked box, an error banner or a filled-in field. They are real hard negatives, not label noise.

**Times.** Synthesized. One app's screens are 5-40 s apart (one session), sessions are 1-48 h apart, and each copy comes 1 h to 21 days after its screenshot.

**License.** CC BY 4.0, as tagged on the mirror (Rico / Screen2Words). App UIs are (c) their developers. Local evaluation only.

**Caveat.** These are Android screens, mostly from 2017. iOS screens have different chrome, but the hard case is the same: one app, different content.

### photo-triage-tight

**What it is.** photo-triage with the series packed close in time, so that every series has other series inside the app's time window. That is the hard case for the app's linking step: real look-alike shots of different moments taken minutes apart. Photo Triage series ids are consecutive within an album.

**How it is built.**
- The images are hard links to photo-triage's, and the groups are the same.
- Each series starts 10-60 s after the previous one ends (seed 60), in series-id order. The gaps within a series are photo-triage's (1-4 s).

**Use.** Time-window evaluation only (`variant_of = "photo-triage"`). Pair metrics that ignore time would equal photo-triage's. `evaluate.py` splits it in halves by group: the dev half picks each method's window link, and the test half reports it.

**Times.** Synthesized.

### california-nd (builder ready, photos not included)

**Source.** A. Jinda-Apiraksa, V. Vonikakis, S. Winkler, "California-ND: An annotated dataset for near-duplicate detection in personal photo collections", QoMEX 2013. 701 photos from one personal travel collection, judged by 10 observers.

**License.** CC BY-NC-ND 3.0.

**Getting the photos.**
- The annotations are public and are fetched from a GitHub mirror (github.com/NetJagaimo/image_match, `comparative_data/californiaND`).
- The photos are in `californiaND.zip` (http://vintage.winklerbros.net/californiaND.zip, also in the Wayback Machine). Every file in that zip is encrypted, and the authors give the password by email.
- Once you have it, unzip into `bench/data/_raw/californiaND/` so that `Photos/001.jpg`…`701.jpg` exist, and run the builder.

**Truth.**
- `Correlation matrices/gt_subject<k>.npy` holds each observer's grouping as a 701x701 0/1 matrix. It matches the text files.
- votes = the number of observers who put a pair in one group.
- positives = votes >= 6 (a strict majority of 10). groups = connected components of those pairs: 117 groups, 572 grouped images, 129 singles.
- 5 components are non-transitive. Their notes count the member pairs that have fewer than 6 votes.
- `pair_agreement` = votes/10 for the 4609 pairs with at least one vote. best = the first file of each group.
- times = EXIF DateTimeOriginal.

## Not built

- **Real-phone bursts.** No small public set was found. The public HDR+ burst data is large raw DNG frames that are deliberately underexposed and already aligned, which is unlike what a photo library holds.
