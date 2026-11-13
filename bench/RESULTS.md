# Duplicate-photo benchmark: results

This compares the signal Tidykeep uses to find duplicate photos (Apple Vision's feature print of a softened copy) with 13 open-source models and hashes, 19 variants in all once input-form and pooling variants are counted. It uses five public datasets, then runs the strongest embeddings inside the app's own grouping code. It also scores the app's best-shot ranking. Everything ran on one Mac on 2026-11-12. Every number comes from `bench/evaluate.py`. The full output is in `bench/out/results.json`, and the generated tables, copied here unchanged, are in `bench/out/tables.md`.

This version replaces an earlier one after a review. The review's requests that were not done are listed under [Known limitations](#known-limitations).

## In short

- **No single model wins everywhere. SSCD comes closest.** SSCD is Meta's copy-detection model: MIT license, 98 MB fp32.
  - With its variable-size input (short side 288, aspect kept), it is the only method in the statistical top group on all five datasets. Top group here means the 95% CI of its AP gap to the leader includes 0.
  - It ties or leads on synthetic bursts (1.000) and copies (1.000).
  - It ties the leader on real series (0.954 vs 0.960 for DINOv3-small-squash), real camera shake (0.984 vs 0.989 for its own padded form) and real screenshots (0.894 vs 0.912 for SigLIP 2).
  - Other models lead single datasets but fall out of the top group elsewhere.
- **That SSCD result depends on its input form.**
  - A plain Core ML conversion has a fixed square input.
  - At a fixed 320x320, SSCD keeps its scores on photos and on real blur.
  - It loses photo-vs-screenshot copies: recall drops from 1.00 to 0.65 (squashed) or 0.41 (padded).
  - The `sscd` numbers assume a flexible-shape model on the phone, which was not built or measured.
- **Today's signal (the softened Vision print)** depends on the kind of photo.
  - Synthetic blurry bursts: perfect, but this is its calibration set, so in-sample.
  - Held-out real camera shake: it does its job, AP 0.930 against 0.631 for the same print without softening.
  - Sharp real series: it is the weakest learned signal, 0.792 against 0.923 raw and 0.954 for SSCD.
  - Screenshots: also weak, 0.541.
- **Inside the app itself** (tkscan with SSCD as the link signal, at one threshold carried over from other data):
  - 227/280 real series found at pair precision 0.989. Today the app finds 209/280 at 0.989.
  - 66/66 real-blur moments, against 53/66 today.
  - 28/29 synthetic bursts, against 29/29 today (in-sample).
  - On sharp real series, several embeddings (and the raw print) reach similar recall inside the time window. SSCD's edge is that it is at the top on blurry and sharp series at once.
- **Copies made later never meet the time window.** The app groups 0 of 501 copy pairs.
  - A separate library-wide pass fixes this: SSCD at the carried-over threshold with complete linkage groups 150/150 copy sets at pair precision 0.998 on the whole copies set.
  - Plain single linkage chains clusters together (precision 0.952, clusters of up to 8).
  - DINOv3-small makes 0 false calls but has a custom license. DINOv2-small (Apache-2.0) scores 0.992 / 1.000.
- **Real screenshots are not solved by any method tested.**
  - No signal tells a screenshot's copy apart from another screen of the same app at one threshold. At precision ≥ 0.99, at most half of the copies are found (oracle, best 0.50).
  - At the carried-over threshold, SSCD calls 1,705 false pairs (precision 0.055).
  - The app already leaves screenshots out of its scan. A screenshot cleaner would need its own rule, such as a tighter threshold for screen-shaped pairs (precision 1.000, recall about 0.5).
- **Perceptual hashes** (aHash, pHash, dHash, wHash, PDQ) are weak.
  - They score AP 0.03 to 0.16 on real series.
  - They miss mirrored copies and most screenshotted ones.
  - At their carried-over thresholds they find at most 63% of copy pairs (whole set).
- **Keeper choice.**
  - ShotScorer agrees with crowd preferences on 73% of photo pairs (random gets 50%).
  - It picks the crowd's top photo in 51% of series. Random gets 42%, and a 1.2 GB LAION aesthetic model gets 59%; the gap to LAION is not significant.
  - On real camera shake it picks the sharp frame 98.5% of the time.
  - On copies it keeps the original 47% of the time, so copy keepers should come from metadata.
- **Feasibility.**
  - Everything here runs offline, so no photo or result has to leave the phone.
  - iPhone speed, memory and Core ML conversion were not measured.

## Setup

- **Machine.** Apple M3 Max, macOS 27.0.1.
  - Python 3.12 in `bench/.venv`, with versions pinned in `requirements.txt`.
  - PyTorch on MPS for the neural models.
  - The app's own Swift code, through a release build of `tkscan`, for the two Vision methods, the pipeline and the ranking.
- **Data and network.**
  - Only public datasets and the images that ship with macOS were used. No personal photos were read.
  - The network was used only to download datasets, model weights and packages. All inference ran locally.
- **Methods.** 21, defined in `bench/README.md`.
  - `apple-fp2-soft` is what the app uses today. `apple-fp2-raw` is the same Vision print without the softening.
  - Five rows feed an existing model a fixed square instead of its usual input: `sscd-skew320`, `sscd-pad320`, `dinov2-small-squash`, `dinov2-small-pad` and `dinov3-small-squash` (see [Input form](#input-form)).
- **Pairs.**
  - Every pair of images within a dataset is scored. Both images in one group make a duplicate pair; every other pair is negative.
  - The 528 gopro-bursts pairs between the two moments of one clip are left out of the scores and reported separately.
  - Capture times are ignored everywhere except the time-window and app-pipeline sections.
- **Distances.** Smaller always means more alike.
  - Learned embeddings: 1 - cosine, on unit vectors.
  - Vision prints: Euclidean. Their norms are 1 ± 0.5%.
  - Hashes: the number of differing bits.
- **Metrics.**
  - AP (PR-AUC, tie-aware and equal to scikit-learn's) and ROC-AUC.
  - Recall at a false-positive rate of 1e-2 and 1e-3.
  - *Oracle* recall at precision ≥ 0.99 and ≥ 0.95, and best F1. These three pick their threshold on the set they report, so they are for reference only.
- **95% CIs.**
  - 1000 bootstrap resamples of units, seed 1729. A unit is a group, or a single treated as a group of one.
  - Every method uses the same resamples, so differences between methods are paired.
  - Where a score is perfect, the bootstrap interval collapses. The exact Clopper-Pearson lower bound is given instead. It treats pairs as independent, which they are not, so it understates the uncertainty.
- **Threshold transfer.**
  - The groups and singles of bursts-profile and copies are split 50/50 (seed 2026). A pair belongs to a half only if both of its images do.
  - Each method gets one threshold: the largest distance with precision ≥ 0.99 on the pooled dev halves.
  - That threshold is applied unchanged to:
    - the test halves: 57 images and 68 duplicate pairs from bursts-profile, 308 images and 270 duplicate pairs from copies. They are held out, but made by the same generator as the dev halves;
    - the whole of both dev datasets, including the 2,793 + 90,244 pairs that cross the split;
    - all of photo-triage, gopro-bursts and screenshots, which play no part in choosing any of these thresholds.
  - Fusion models are fitted on the same dev halves.
- **Two more dev halves, each used for one thing only.**
  - The screenshots split (208 / 208 images, 50 / 50 copies) sets the screen-shaped threshold in the copy pass.
  - The photo-triage-tight split (367 / 364 images) sets the `window-dev` link inside the time window.
- **Time window.**
  - `series_port.py` is a Python port of the app's SeriesBuilder and Scanner.groups. It gives the same groups as tkscan in 94 of 94 checked runs.
  - It runs every embedding through the window, int8-quantized and compared by Euclidean distance, as the app stores them.
  - Selected embeddings are also run through the Swift code itself, with `tkscan eval --features`.
- **One in-sample exception.** The app's softening and its sensitivity presets were calibrated on all of bursts-profile before this benchmark. `apple-fp2-soft` and the app pipeline are therefore in-sample on bursts-profile.

## Datasets

| Dataset | What it is | Images | Groups | Duplicate pairs | Other pairs | Singles | Truth | Best-shot truth | License |
|---|---|---|---|---|---|---|---|---|---|
| bursts-profile | Synthetic handheld bursts of the 43 macOS account pictures: 2-5 frames, reframed, tilted and exposure-drifted, every frame but one blurred. Frames 1-3 s apart. The app's calibration set. | 106 | 29 | 119 | 5,446 | 14 | group = one burst | best = the one unblurred frame (29 groups) | Apple system images; local evaluation only |
| photo-triage | Real consecutive shots from personal albums (Chang et al., "Automatic Triage for a Photo Series", SIGGRAPH 2016): all 195 validation series plus 85 test series. Times synthesized: 1-4 s apart within a series, 2-8 h between series. | 731 | 280 | 711 | 266,104 | 0 | group = one released series: shots of one moment, often recomposed. "Same series", not "same photo". | 292 crowd preference pairs (preference ratio ≥ 0.7) in 136 series; rank-1 photo of 195 series | research use, no open license; not redistributed |
| photo-triage-tight | The same images and series, re-timed so each series starts 10-60 s after the previous one ends (seed 60). Unrelated scenes from one album then meet inside the app's 60 s window. Time-window runs only. | 731 | 280 | 711 | 266,104 | 0 | as photo-triage | — | as photo-triage |
| copies | 150 Photo Triage train-split originals, each with 1-3 copies (re-encode, HEIC/JPEG, simulated iPhone screenshot, crop, colour, downscale, rotate, mirror), plus 150 distractors. Each copy is dated 1 h to 21 days after its original. | 601 | 150 | 501 (200 of them copy vs copy) | 179,799 | 150 | group = original + its copies | best = the original | derived from Photo Triage; local evaluation only |
| gopro-bursts | Real handheld camera shake and subject motion from the GoPro deblurring set (Nah et al., CVPR 2017). 33 clips x 2 moments; a moment is one sharp frame plus three blurred frames, each an average of 7-13 consecutive 240 fps frames. Times synthesized. Never used for any threshold. | 264 | 66 | 396 | 33,792 | 0 | group = one moment; the 528 pairs between the two moments of a clip (3-8 s apart) are unscored | best = the sharp frame | CC BY 4.0 (Hugging Face mirror tag); cite the paper |
| screenshots | 316 real Android screens of 120 apps (Rico, via Screen2Words), up to 3 per app. 100 of them have one copy: resave (JPEG q70 at 60%), HEIC round trip, status and navigation bars cut off, or a simulated iPhone screenshot of it (letterboxed into 1179x2556). Times synthesized. Never used for the carried-over threshold. | 416 | 100 | 100 | 86,220 (486 are two screens of the same app) | 216 | group = screen + its copy | best = the original screen | CC BY 4.0 (mirror tag); app UIs (c) their developers |
| california-nd | 701 travel photos judged by 10 observers (QoMEX 2013) | not run | | | | | | | CC BY-NC-ND 3.0 |

- **Capture times are synthesized in every dataset.** All time-window results depend on that date model.
  - Real burst-mode frames are fractions of a second apart.
  - A real copy (a saved, downloaded or screenshotted image) gets a new date. Photos' Duplicate command is the exception: it keeps the original's date, and that case is reported separately.
- **There is no real-phone burst set.**
  - gopro-bursts is the nearest held-out real blur. It has real handheld shake, but it comes from a video camera, and each blurred frame is an average of frames rather than one long exposure.
  - bursts-profile is synthetic. photo-triage series are slower, recomposed shots.
- **California-ND was not run.** Its annotations are public, but every photo in the authors' zip is encrypted, and the password is only given by email. The builder (`datasets/build_california_nd.py`) and the scoring path are ready.
- Full build details are in `datasets/README.md`.

## Headline

AP: all pairs of the whole dataset, no threshold, no time window. R@P≥.99 transfer: recall (and the precision actually reached) at the one threshold per method picked for precision ≥ 0.99 on the dev halves of bursts-profile + copies; reported on their test halves (held out, but from the same generator) and on all of photo-triage, gopro-bursts and screenshots (never used for any threshold). The last 5 rows are the same models with a fixed square input.

| Method | bursts-profile AP [95% CI] | bursts-profile R@P≥.99 transfer (P) | photo-triage AP [95% CI] | photo-triage R@P≥.99 transfer (P) | copies AP [95% CI] | copies R@P≥.99 transfer (P) | gopro-bursts AP [95% CI] | gopro-bursts R@P≥.99 transfer (P) | screenshots AP [95% CI] | screenshots R@P≥.99 transfer (P) | ms/img (M3 Max) | model MB | weights | ship? |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 1.000 [1.000, 1.000] | 0.956 (1.00) | 0.792 [0.733, 0.842] | 0.193 (0.99) | 0.877 [0.835, 0.914] | 0.830 (1.00) | 0.930 [0.887, 0.965] | 0.768 (1.00) | 0.541 [0.452, 0.640] | 0.580 (0.14) | 21.0 | 0 (in iOS) | in iOS | yes |
| `apple-fp2-raw` | 0.910 [0.804, 0.977] | 0.456 (1.00) | 0.923 [0.889, 0.951] | 0.814 (0.94) | 0.949 [0.922, 0.972] | 0.889 (0.98) | 0.631 [0.545, 0.723] | 0.530 (0.70) | 0.834 [0.714, 0.940] | 0.970 (0.43) | 18.1 | 0 (in iOS) | in iOS | yes |
| `ahash` | 0.935 [0.834, 0.992] | 0.000 (n/a) | 0.031 [0.022, 0.055] | 0.000 (n/a) | 0.493 [0.415, 0.574] | 0.000 (n/a) | 0.892 [0.830, 0.942] | 0.000 (n/a) | 0.010 [0.007, 0.016] | 0.000 (n/a) | 0.4 | 0 | none (BSD-2 code) | yes |
| `phash` | 0.834 [0.716, 0.939] | 0.559 (1.00) | 0.129 [0.097, 0.164] | 0.096 (0.81) | 0.660 [0.610, 0.711] | 0.615 (0.99) | 0.807 [0.744, 0.867] | 0.631 (1.00) | 0.614 [0.514, 0.722] | 0.740 (0.21) | 0.5 | 0 | none (BSD-2 code) | yes |
| `dhash` | 0.894 [0.822, 0.966] | 0.412 (1.00) | 0.155 [0.113, 0.209] | 0.058 (0.87) | 0.662 [0.612, 0.715] | 0.526 (1.00) | 0.801 [0.731, 0.866] | 0.452 (1.00) | 0.598 [0.510, 0.699] | 0.640 (0.43) | 0.4 | 0 | none (BSD-2 code) | yes |
| `whash` | 0.845 [0.742, 0.969] | 0.000 (n/a) | 0.026 [0.019, 0.045] | 0.000 (n/a) | 0.354 [0.246, 0.509] | 0.000 (n/a) | 0.840 [0.768, 0.906] | 0.000 (n/a) | 0.090 [0.051, 0.168] | 0.000 (n/a) | 8.5 | 0 | none (BSD-2 code) | yes |
| `pdq` | 0.590 [0.468, 0.730] | 0.397 (1.00) | 0.102 [0.074, 0.135] | 0.069 (0.98) | 0.616 [0.563, 0.671] | 0.552 (0.99) | 0.625 [0.552, 0.701] | 0.457 (1.00) | 0.579 [0.488, 0.681] | 0.630 (0.13) | 5.4 | 0 | none (BSD-3 code) | yes |
| `imagededup-cnn` | 1.000 [0.998, 1.000] | 0.853 (1.00) | 0.872 [0.834, 0.906] | 0.449 (0.99) | 0.939 [0.911, 0.968] | 0.870 (1.00) | 0.873 [0.817, 0.929] | 0.649 (0.99) | 0.727 [0.653, 0.814] | 0.950 (0.05) | 7.8 | 4 | BSD-3 (ImageNet-trained) | check ImageNet terms |
| `clip-b32-openai` | 0.983 [0.954, 1.000] | 0.882 (1.00) | 0.905 [0.849, 0.947] | 0.705 (0.92) | 0.996 [0.991, 0.999] | 0.993 (0.99) | 0.810 [0.745, 0.872] | 0.753 (0.69) | 0.501 [0.295, 0.866] | 0.970 (0.31) | 12.2 | 351 | MIT | yes |
| `mobileclip` | 1.000 [0.999, 1.000] | 0.971 (1.00) | 0.921 [0.879, 0.954] | 0.729 (0.95) | 0.999 [0.997, 1.000] | 1.000 (0.98) | 0.874 [0.818, 0.929] | 0.735 (0.94) | 0.427 [0.239, 0.824] | 0.990 (0.32) | 12.8 | 46 | Apple research-only | no |
| `siglip2-base` | 1.000 [0.999, 1.000] | 0.971 (1.00) | 0.941 [0.895, 0.971] | 0.831 (0.92) | 0.937 [0.908, 0.963] | 0.856 (0.97) | 0.800 [0.720, 0.879] | 0.783 (0.60) | 0.912 [0.814, 0.985] | 1.000 (0.52) | 13.6 | 372 | Apache-2.0 | yes |
| `dinov2-small` | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.910 [0.862, 0.946] | 0.689 (0.95) | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.877 [0.805, 0.941] | 0.727 (0.90) | 0.340 [0.189, 0.677] | 1.000 (0.01) | 12.3 | 88 | Apache-2.0 | yes |
| `dinov2-small-mean` | 0.999 [0.996, 1.000] | 1.000 (1.00) | 0.911 [0.867, 0.946] | 0.700 (0.96) | 1.000 [0.998, 1.000] | 1.000 (1.00) | 0.910 [0.859, 0.959] | 0.833 (0.90) | 0.386 [0.215, 0.736] | 1.000 (0.02) | 10.4 | 88 | Apache-2.0 | yes |
| `dinov2-base` | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.909 [0.855, 0.949] | 0.616 (0.95) | 1.000 [1.000, 1.000] | 0.996 (1.00) | 0.909 [0.850, 0.959] | 0.657 (0.98) | 0.375 [0.214, 0.719] | 1.000 (0.03) | 17.0 | 346 | Apache-2.0 | yes |
| `sscd` | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.954 [0.928, 0.974] | 0.717 (0.99) | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.984 [0.946, 1.000] | 0.955 (0.90) | 0.894 [0.813, 0.967] | 1.000 (0.06) | 15.6 | 98 | MIT | yes |
| `dinov3-small` | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.949 [0.910, 0.975] | 0.584 (0.98) | 1.000 [1.000, 1.000] | 0.993 (1.00) | 0.951 [0.895, 0.986] | 0.780 (0.97) | 0.495 [0.277, 0.869] | 0.980 (0.23) | 12.3 | 86 | DINOv3 License (custom) | read license |
| `sscd-skew320` | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.953 [0.927, 0.974] | 0.516 (1.00) | 0.985 [0.967, 0.997] | 0.941 (1.00) | 0.987 [0.959, 1.000] | 0.902 (0.95) | 0.908 [0.836, 0.972] | 1.000 (0.31) | 15.6 | 98 | MIT | yes |
| `sscd-pad320` | 1.000 [1.000, 1.000] | 0.971 (1.00) | 0.946 [0.920, 0.968] | 0.440 (1.00) | 0.978 [0.955, 0.993] | 0.907 (1.00) | 0.989 [0.961, 1.000] | 0.904 (0.96) | 0.871 [0.798, 0.948] | 1.000 (0.27) | 15.7 | 98 | MIT | yes |
| `dinov2-small-squash` | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.919 [0.870, 0.954] | 0.814 (0.89) | 0.995 [0.989, 0.999] | 0.978 (0.99) | 0.884 [0.804, 0.959] | 0.874 (0.75) | 0.597 [0.514, 0.694] | 1.000 (0.00) | 12.1 | 88 | Apache-2.0 | yes |
| `dinov2-small-pad` | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.921 [0.876, 0.955] | 0.726 (0.95) | 0.992 [0.983, 0.998] | 0.937 (1.00) | 0.884 [0.806, 0.954] | 0.838 (0.77) | 0.541 [0.456, 0.642] | 1.000 (0.00) | 11.9 | 88 | Apache-2.0 | yes |
| `dinov3-small-squash` | 1.000 [1.000, 1.000] | 1.000 (1.00) | 0.960 [0.925, 0.983] | 0.840 (0.96) | 0.999 [0.997, 1.000] | 1.000 (0.98) | 0.943 [0.890, 0.983] | 0.937 (0.73) | 0.863 [0.783, 0.942] | 1.000 (0.02) | 12.3 | 86 | DINOv3 License (custom) | read license |

- **Columns.**
  - ms/img is the photo-triage column of the speed table. For the `apple-*` methods it is the app's whole `analyze()` call: softening, feature print, aesthetics, face quality and focus. For the others it is one forward pass at batch 1 on MPS.
  - None of these are iPhone numbers.
  - Model MB is the fp32 size of the image encoder. The Vision print ships inside iOS, so it costs the app 0 MB.
- **Hashes.** They have no learned weights. aHash and wHash never reach precision 0.99 on the dev halves at any threshold, so they have no transfer threshold.
- **Screenshot precision.** At the carried-over threshold, every method's precision on screenshots is low, from 0.00 to 0.52. Recall there means little without it; see [Screenshots](#screenshots).

## Input form

A Core ML model on the phone has a fixed input shape unless built with flexible shapes, so the aspect-kept SSCD input (`sscd`) is not what a simple conversion would ship. AP per dataset; copies 'screenshot' = recall of a photo vs its screenshot on the copies test half at the transfer threshold; photo-triage recomposed = AP of the least alike third of its series (see below); window = pair P / R on the photo-triage-tight test half inside the app's time window, link calibrated on its dev half.

| Model | input | method | bursts-profile AP | photo-triage AP | copies AP | gopro-bursts AP | screenshots AP | copies: photo vs its screenshot, R | photo-triage recomposed AP | in-window P / R |
|---|---|---|---|---|---|---|---|---|---|---|
| SSCD | short side 288, aspect kept (variable size) | `sscd` | 1.000 | 0.954 | 1.000 | 0.984 | 0.894 | 1.00 | 0.843 | 0.986 / 0.790 |
| SSCD | squashed to 320x320 | `sscd-skew320` | 1.000 | 0.953 | 0.985 | 0.987 | 0.908 | 0.65 | 0.845 | 0.986 / 0.787 |
| SSCD | padded to a 320x320 square | `sscd-pad320` | 1.000 | 0.946 | 0.978 | 0.989 | 0.871 | 0.41 | 0.830 | 0.986 / 0.804 |
| DINOv2-small | short side 256, center crop 224 | `dinov2-small` | 1.000 | 0.910 | 1.000 | 0.877 | 0.340 | 1.00 | 0.701 | 0.986 / 0.798 |
| DINOv2-small | squashed to 224x224 | `dinov2-small-squash` | 1.000 | 0.919 | 0.995 | 0.884 | 0.597 | 0.88 | 0.739 | 0.985 / 0.755 |
| DINOv2-small | padded to a 224x224 square | `dinov2-small-pad` | 1.000 | 0.921 | 0.992 | 0.884 | 0.541 | 0.65 | 0.741 | 0.984 / 0.695 |
| DINOv3-small | short side 256, center crop 256 | `dinov3-small` | 1.000 | 0.949 | 1.000 | 0.951 | 0.495 | 1.00 | 0.799 | 0.984 / 0.720 |
| DINOv3-small | squashed to 256x256 | `dinov3-small-squash` | 1.000 | 0.960 | 0.999 | 0.943 | 0.863 | 1.00 | 0.837 | 0.985 / 0.744 |

- **What the phone would run.** A Core ML model has a fixed input shape unless it is built with flexible shapes, either a set of enumerated sizes or a size range.
  - The `sscd` rows assume aspect-kept input on the phone, so they need a flexible-shape model. Its speed, and whether it runs on the Neural Engine, were not measured.
  - With a single fixed square input, read the `sscd-skew320` rows instead. Every SSCD recommendation below that touches screenshots depends on this choice.
- **Fixed-square SSCD.**
  - It matches the variable-size form on bursts (1.000), real series (0.953 squashed / 0.946 padded), real blur (0.987 / 0.989) and screenshots (0.908 / 0.871).
  - It loses on copies: AP 0.985 / 0.978, and photo-vs-screenshot copies fall to 0.65 / 0.41 recall at the carried-over threshold.
  - For SSCD, squashing beats padding except on real blur and in-window recall.
- **DINOv3-small-squash.** It keeps 1.00 on screenshot copies and leads on real series (0.960). It is behind on real blur (0.943), and on the whole copies set it makes 17 false calls across the split. Its license is custom.
- **DINOv2-small.** Its standard center crop is its worst form on screenshots (0.340), because the crop cuts most of a tall screen away. Squashed, it scores 0.597.
- **Inside the time window,** every input form lands at recall 0.69-0.80 at about the same pair precision (0.984-0.986).

## Per-dataset results (all pairs, no time window)

### bursts-profile

106 images, 29 groups, 14 singles, 119 duplicate pairs, 5446 other pairs. Sorted by AP. Differences are paired (same group resamples); top = `apple-fp2-soft`. R@FPR = recall at a false-positive rate of 1e-2 / 1e-3 (the looser regime inside a time window). R@P≥.99, R@P≥.95 and best F1 are ORACLE numbers (threshold picked on this dataset).

| Method | AP [95% CI] | AP − apple-fp2-soft [95% CI] | AP − top [95% CI] | ROC-AUC | R@FPR 1e-2 | R@FPR 1e-3 | oracle R@P≥.99 @ thr | oracle R@P≥.95 | oracle best F1 @ thr |
|---|---|---|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 1.000 [1.000, 1.000] | — | — | 1.000 | 1.000 | 1.000 | 1.000 @ 0.450 | 1.000 | 1.000 @ 0.450 |
| `dinov2-small` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.245 | 1.000 | 1.000 @ 0.245 |
| `dinov2-base` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.180 | 1.000 | 1.000 @ 0.180 |
| `sscd` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.564 | 1.000 | 1.000 @ 0.564 |
| `dinov3-small` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.186 | 1.000 | 1.000 @ 0.186 |
| `sscd-skew320` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.518 | 1.000 | 1.000 @ 0.518 |
| `sscd-pad320` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.518 | 1.000 | 1.000 @ 0.518 |
| `dinov2-small-squash` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.255 | 1.000 | 1.000 @ 0.255 |
| `dinov2-small-pad` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.255 | 1.000 | 1.000 @ 0.255 |
| `dinov3-small-squash` | 1.000 [1.000, 1.000] | 0.000 [-0.000, 0.000] | 0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.186 | 1.000 | 1.000 @ 0.186 |
| `siglip2-base` | 1.000 [0.999, 1.000] | -0.000 [-0.001, 0.000] | -0.000 [-0.001, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.121 | 1.000 | 0.996 @ 0.121 |
| `mobileclip` | 1.000 [0.999, 1.000] | -0.000 [-0.001, 0.000] | -0.000 [-0.001, 0.000] | 1.000 | 1.000 | 1.000 | 0.992 @ 0.183 | 1.000 | 0.992 @ 0.185 |
| `imagededup-cnn` | 1.000 [0.998, 1.000] | -0.000 [-0.002, 0.000] | -0.000 [-0.002, 0.000] | 1.000 | 1.000 | 1.000 | 0.992 @ 0.181 | 1.000 | 0.992 @ 0.181 |
| `dinov2-small-mean` | 0.999 [0.996, 1.000] | -0.001 [-0.004, 0.000] | -0.001 [-0.004, 0.000] | 1.000 | 1.000 | 0.992 | 0.992 @ 0.140 | 0.992 | 0.996 @ 0.140 |
| `clip-b32-openai` | 0.983 [0.954, 1.000] | -0.017 [-0.046, -0.000] | -0.017 [-0.046, -0.000] | 1.000 | 0.983 | 0.899 | 0.891 @ 0.082 | 0.899 | 0.938 @ 0.082 |
| `ahash` | 0.935 [0.834, 0.992] | -0.065 [-0.166, -0.008] | -0.065 [-0.166, -0.008] | 0.999 | 0.966 | 0.706 | 0.227 @ 2 bits | 0.487 | 0.892 @ 11 bits |
| `apple-fp2-raw` | 0.910 [0.804, 0.977] | -0.090 [-0.196, -0.023] | -0.090 [-0.196, -0.023] | 0.997 | 0.916 | 0.681 | 0.471 @ 0.528 | 0.681 | 0.825 @ 0.720 |
| `dhash` | 0.894 [0.822, 0.966] | -0.106 [-0.178, -0.034] | -0.106 [-0.178, -0.034] | 0.982 | 0.891 | 0.748 | 0.605 @ 12 bits | 0.664 | 0.849 @ 15 bits |
| `whash` | 0.845 [0.742, 0.969] | -0.155 [-0.258, -0.031] | -0.155 [-0.258, -0.031] | 0.996 | 0.924 | 0.336 | 0.336 @ 4 bits | 0.336 | 0.803 @ 12 bits |
| `phash` | 0.834 [0.716, 0.939] | -0.166 [-0.284, -0.061] | -0.166 [-0.284, -0.061] | 0.982 | 0.798 | 0.697 | 0.269 @ 8 bits | 0.597 | 0.802 @ 16 bits |
| `pdq` | 0.590 [0.468, 0.730] | -0.410 [-0.532, -0.270] | -0.410 [-0.532, -0.270] | 0.814 | 0.555 | 0.445 | 0.403 @ 80 bits | 0.429 | 0.635 @ 98 bits |

- **Synthetic and in-sample** for `apple-fp2-soft`. 14 methods are statistically tied at the top, so this set ranks almost nothing.
- **The raw print** is behind at 0.910, a gap of −0.090 [−0.196, −0.023] to the softened print. On blur made this way, softening helps.

### photo-triage

731 images, 280 groups, 0 singles, 711 duplicate pairs, 266104 other pairs. Sorted by AP. Differences are paired (same group resamples); top = `dinov3-small-squash`. R@FPR = recall at a false-positive rate of 1e-2 / 1e-3 (the looser regime inside a time window). R@P≥.99, R@P≥.95 and best F1 are ORACLE numbers (threshold picked on this dataset).

| Method | AP [95% CI] | AP − apple-fp2-soft [95% CI] | AP − top [95% CI] | ROC-AUC | R@FPR 1e-2 | R@FPR 1e-3 | oracle R@P≥.99 @ thr | oracle R@P≥.95 | oracle best F1 @ thr |
|---|---|---|---|---|---|---|---|---|---|
| `dinov3-small-squash` | 0.960 [0.925, 0.983] | 0.168 [0.125, 0.217] | — | 1.000 | 0.999 | 0.962 | 0.495 @ 0.164 | 0.855 | 0.912 @ 0.389 |
| `sscd` | 0.954 [0.928, 0.974] | 0.162 [0.119, 0.213] | -0.006 [-0.024, 0.013] | 0.996 | 0.976 | 0.956 | 0.679 @ 0.523 | 0.890 | 0.926 @ 0.751 |
| `sscd-skew320` | 0.953 [0.927, 0.974] | 0.161 [0.118, 0.214] | -0.007 [-0.025, 0.012] | 0.994 | 0.973 | 0.954 | 0.720 @ 0.574 | 0.897 | 0.927 @ 0.746 |
| `dinov3-small` | 0.949 [0.910, 0.975] | 0.157 [0.114, 0.207] | -0.011 [-0.019, -0.004] | 1.000 | 0.993 | 0.947 | 0.511 @ 0.163 | 0.828 | 0.901 @ 0.400 |
| `sscd-pad320` | 0.946 [0.920, 0.968] | 0.154 [0.112, 0.204] | -0.014 [-0.034, 0.008] | 0.995 | 0.962 | 0.947 | 0.700 @ 0.532 | 0.909 | 0.929 @ 0.687 |
| `siglip2-base` | 0.941 [0.895, 0.971] | 0.149 [0.098, 0.201] | -0.019 [-0.044, -0.000] | 1.000 | 0.996 | 0.954 | 0.287 @ 0.043 | 0.748 | 0.894 @ 0.129 |
| `apple-fp2-raw` | 0.923 [0.889, 0.951] | 0.131 [0.089, 0.185] | -0.037 [-0.062, -0.007] | 0.998 | 0.970 | 0.916 | 0.536 @ 0.449 | 0.783 | 0.875 @ 0.587 |
| `dinov2-small-pad` | 0.921 [0.876, 0.955] | 0.129 [0.082, 0.178] | -0.039 [-0.060, -0.019] | 0.999 | 0.989 | 0.910 | 0.477 @ 0.157 | 0.716 | 0.860 @ 0.335 |
| `mobileclip` | 0.921 [0.879, 0.954] | 0.128 [0.085, 0.179] | -0.039 [-0.063, -0.016] | 0.999 | 0.986 | 0.904 | 0.367 @ 0.078 | 0.730 | 0.857 @ 0.188 |
| `dinov2-small-squash` | 0.919 [0.870, 0.954] | 0.127 [0.079, 0.176] | -0.041 [-0.064, -0.022] | 0.999 | 0.990 | 0.916 | 0.384 @ 0.125 | 0.685 | 0.856 @ 0.353 |
| `dinov2-small-mean` | 0.911 [0.867, 0.946] | 0.119 [0.075, 0.167] | -0.049 [-0.077, -0.025] | 0.999 | 0.969 | 0.906 | 0.496 @ 0.104 | 0.765 | 0.859 @ 0.205 |
| `dinov2-small` | 0.910 [0.862, 0.946] | 0.118 [0.069, 0.169] | -0.050 [-0.074, -0.028] | 0.999 | 0.983 | 0.896 | 0.444 @ 0.149 | 0.695 | 0.852 @ 0.355 |
| `dinov2-base` | 0.909 [0.855, 0.949] | 0.116 [0.062, 0.175] | -0.051 [-0.085, -0.022] | 1.000 | 0.996 | 0.909 | 0.363 @ 0.123 | 0.602 | 0.827 @ 0.402 |
| `clip-b32-openai` | 0.905 [0.849, 0.947] | 0.113 [0.057, 0.170] | -0.055 [-0.089, -0.026] | 0.999 | 0.990 | 0.907 | 0.329 @ 0.057 | 0.612 | 0.848 @ 0.140 |
| `imagededup-cnn` | 0.872 [0.834, 0.906] | 0.080 [0.035, 0.132] | -0.088 [-0.121, -0.053] | 0.989 | 0.931 | 0.854 | 0.606 @ 0.148 | 0.740 | 0.843 @ 0.199 |
| `apple-fp2-soft` | 0.792 [0.733, 0.842] | — | -0.168 [-0.217, -0.125] | 0.993 | 0.910 | 0.751 | 0.336 @ 0.427 | 0.551 | 0.754 @ 0.597 |
| `dhash` | 0.155 [0.113, 0.209] | -0.637 [-0.691, -0.577] | -0.805 [-0.852, -0.751] | 0.739 | 0.278 | 0.186 | 0.038 @ 7 bits | 0.038 | 0.246 @ 15 bits |
| `phash` | 0.129 [0.097, 0.164] | -0.663 [-0.717, -0.605] | -0.831 [-0.870, -0.785] | 0.707 | 0.207 | 0.125 | 0.059 @ 10 bits | 0.059 | 0.207 @ 16 bits |
| `pdq` | 0.102 [0.074, 0.135] | -0.690 [-0.742, -0.630] | -0.858 [-0.894, -0.815] | 0.579 | 0.138 | 0.103 | 0.066 @ 82 bits | 0.076 | 0.163 @ 98 bits |
| `ahash` | 0.031 [0.022, 0.055] | -0.762 [-0.806, -0.704] | -0.929 [-0.951, -0.890] | 0.837 | 0.177 | 0.042 | 0.000 @ none | 0.000 | 0.085 @ 5 bits |
| `whash` | 0.026 [0.019, 0.045] | -0.766 [-0.813, -0.706] | -0.934 [-0.955, -0.897] | 0.828 | 0.124 | 0.028 | 0.000 @ none | 0.000 | 0.077 @ 4 bits |

- **Truth here is "same series".** That means shots of one moment, often recomposed, not exact duplicates. Recall on this set is *series recall*. See the split into thirds below.
- **Top group** (95% CI of the gap includes 0): DINOv3-small-squash 0.960, SSCD 0.954 (−0.006 [−0.024, 0.013]), SSCD-skew320 0.953 and SSCD-pad320 0.946.
- **Just below**, with gap CIs ending at −0.004 and −0.000: DINOv3-small with its crop (0.949) and SigLIP 2 (0.941).
- **The softened print** comes 16th of 21 (0.792). The raw print beats it by +0.131 [0.089, 0.185], so on sharp photos the softening costs recall.

### photo-triage: series recall by how alike a series' frames are

photo-triage truth is 'same series' (shots of one moment, often recomposed), not 'same photo'. Its duplicate pairs are split into thirds by (pHash + dHash differing bits) / 2 (cuts 23.5 and 30 bits); each cell is AP of that third against all unrelated pairs / recall of that third at the transfer threshold. Sorted by the recomposed third.

| Method | near-identical (n=241) | middle (n=255) | recomposed (n=215) |
|---|---|---|---|
| `sscd-skew320` | 0.993 / 0.84 | 0.928 / 0.41 | 0.845 / 0.28 |
| `sscd` | 0.992 / 0.93 | 0.930 / 0.71 | 0.843 / 0.50 |
| `dinov3-small-squash` | 0.979 / 0.97 | 0.911 / 0.83 | 0.837 / 0.71 |
| `sscd-pad320` | 0.994 / 0.78 | 0.928 / 0.33 | 0.830 / 0.20 |
| `dinov3-small` | 0.979 / 0.84 | 0.892 / 0.52 | 0.799 / 0.37 |
| `apple-fp2-raw` | 0.975 / 0.97 | 0.864 / 0.78 | 0.766 / 0.68 |
| `siglip2-base` | 0.962 / 0.97 | 0.870 / 0.81 | 0.766 / 0.71 |
| `dinov2-small-pad` | 0.962 / 0.93 | 0.838 / 0.69 | 0.741 / 0.53 |
| `dinov2-small-squash` | 0.951 / 0.93 | 0.832 / 0.80 | 0.739 / 0.70 |
| `mobileclip` | 0.963 / 0.91 | 0.854 / 0.72 | 0.705 / 0.53 |
| `dinov2-small` | 0.953 / 0.89 | 0.826 / 0.67 | 0.701 / 0.49 |
| `dinov2-small-mean` | 0.974 / 0.94 | 0.842 / 0.67 | 0.692 / 0.47 |
| `clip-b32-openai` | 0.924 / 0.85 | 0.820 / 0.71 | 0.692 / 0.54 |
| `dinov2-base` | 0.939 / 0.80 | 0.819 / 0.61 | 0.676 / 0.42 |
| `imagededup-cnn` | 0.970 / 0.78 | 0.808 / 0.35 | 0.660 / 0.20 |
| `apple-fp2-soft` | 0.922 / 0.44 | 0.660 / 0.11 | 0.479 / 0.01 |
| `ahash` | 0.037 / 0.00 | 0.006 / 0.00 | 0.003 / 0.00 |
| `whash` | 0.029 / 0.00 | 0.006 / 0.00 | 0.002 / 0.00 |
| `pdq` | 0.288 / 0.20 | 0.001 / 0.00 | 0.001 / 0.00 |
| `dhash` | 0.431 / 0.17 | 0.003 / 0.00 | 0.001 / 0.00 |
| `phash` | 0.364 / 0.28 | 0.002 / 0.00 | 0.001 / 0.00 |

- **Near-identical third.** Most learned methods score AP 0.95-0.99. The softened print is behind here too: AP 0.922 and series recall 0.44 at its carried-over threshold, against 0.975 / 0.97 for the raw print and 0.992 / 0.93 for SSCD.
- **Recomposed third.** This is where the methods separate. SSCD scores 0.843, DINOv3-small-squash 0.837 and the raw print 0.766. The softened print scores 0.479 and finds 1% of these pairs at its threshold.
  - A duplicate cleaner may not want to group recomposed shots at all, so the softened print's low overall AP is partly a choice of what counts.
  - Its gap on the near-identical third is not a choice.
- **Hashes** only work on the near-identical third (AP ≤ 0.43), and fail on the rest.

### copies

601 images, 150 groups, 150 singles, 501 duplicate pairs, 179799 other pairs. Sorted by AP. Differences are paired (same group resamples); top = `dinov3-small`. R@FPR = recall at a false-positive rate of 1e-2 / 1e-3 (the looser regime inside a time window). R@P≥.99, R@P≥.95 and best F1 are ORACLE numbers (threshold picked on this dataset).

| Method | AP [95% CI] | AP − apple-fp2-soft [95% CI] | AP − top [95% CI] | ROC-AUC | R@FPR 1e-2 | R@FPR 1e-3 | oracle R@P≥.99 @ thr | oracle R@P≥.95 | oracle best F1 @ thr |
|---|---|---|---|---|---|---|---|---|---|
| `dinov3-small` | 1.000 [1.000, 1.000] | 0.123 [0.086, 0.165] | — | 1.000 | 1.000 | 1.000 | 1.000 @ 0.227 | 1.000 | 1.000 @ 0.227 |
| `sscd` | 1.000 [1.000, 1.000] | 0.123 [0.086, 0.165] | -0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.532 | 1.000 | 0.999 @ 0.532 |
| `dinov2-small` | 1.000 [1.000, 1.000] | 0.123 [0.086, 0.165] | -0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 1.000 @ 0.173 | 1.000 | 0.999 @ 0.173 |
| `dinov2-base` | 1.000 [1.000, 1.000] | 0.123 [0.086, 0.164] | -0.000 [-0.000, 0.000] | 1.000 | 1.000 | 1.000 | 0.996 @ 0.213 | 1.000 | 0.995 @ 0.147 |
| `dinov2-small-mean` | 1.000 [0.998, 1.000] | 0.122 [0.086, 0.164] | -0.000 [-0.002, 0.000] | 1.000 | 1.000 | 1.000 | 0.994 @ 0.166 | 1.000 | 0.992 @ 0.166 |
| `dinov3-small-squash` | 0.999 [0.997, 1.000] | 0.122 [0.086, 0.163] | -0.001 [-0.003, -0.000] | 1.000 | 1.000 | 1.000 | 0.974 @ 0.276 | 0.998 | 0.983 @ 0.276 |
| `mobileclip` | 0.999 [0.997, 1.000] | 0.122 [0.086, 0.163] | -0.001 [-0.003, -0.000] | 1.000 | 1.000 | 1.000 | 0.974 @ 0.116 | 0.994 | 0.985 @ 0.116 |
| `clip-b32-openai` | 0.996 [0.991, 0.999] | 0.119 [0.083, 0.161] | -0.004 [-0.009, -0.001] | 1.000 | 1.000 | 1.000 | 0.938 @ 0.084 | 0.980 | 0.975 @ 0.111 |
| `dinov2-small-squash` | 0.995 [0.989, 0.999] | 0.118 [0.083, 0.157] | -0.005 [-0.011, -0.001] | 1.000 | 1.000 | 1.000 | 0.944 @ 0.205 | 0.966 | 0.969 @ 0.205 |
| `dinov2-small-pad` | 0.992 [0.983, 0.998] | 0.115 [0.080, 0.152] | -0.008 [-0.017, -0.002] | 1.000 | 1.000 | 0.998 | 0.916 @ 0.231 | 0.950 | 0.962 @ 0.274 |
| `sscd-skew320` | 0.985 [0.967, 0.997] | 0.108 [0.079, 0.143] | -0.015 [-0.033, -0.003] | 1.000 | 1.000 | 0.988 | 0.924 @ 0.426 | 0.924 | 0.960 @ 0.426 |
| `sscd-pad320` | 0.978 [0.955, 0.993] | 0.100 [0.076, 0.129] | -0.022 [-0.045, -0.007] | 1.000 | 1.000 | 0.954 | 0.896 @ 0.350 | 0.918 | 0.947 @ 0.365 |
| `apple-fp2-raw` | 0.949 [0.922, 0.972] | 0.072 [0.043, 0.103] | -0.051 [-0.078, -0.028] | 0.998 | 0.980 | 0.938 | 0.856 @ 0.518 | 0.884 | 0.922 @ 0.543 |
| `imagededup-cnn` | 0.939 [0.911, 0.968] | 0.062 [0.035, 0.092] | -0.061 [-0.089, -0.032] | 0.994 | 0.956 | 0.920 | 0.890 @ 0.128 | 0.916 | 0.944 @ 0.180 |
| `siglip2-base` | 0.937 [0.908, 0.963] | 0.060 [0.032, 0.092] | -0.063 [-0.092, -0.037] | 0.999 | 0.966 | 0.922 | 0.840 @ 0.078 | 0.866 | 0.911 @ 0.096 |
| `apple-fp2-soft` | 0.877 [0.835, 0.914] | — | -0.123 [-0.165, -0.086] | 0.978 | 0.888 | 0.858 | 0.848 @ 0.370 | 0.848 | 0.917 @ 0.370 |
| `dhash` | 0.662 [0.612, 0.715] | -0.215 [-0.265, -0.161] | -0.338 [-0.388, -0.285] | 0.912 | 0.709 | 0.633 | 0.551 @ 9 bits | 0.563 | 0.722 @ 11 bits |
| `phash` | 0.660 [0.610, 0.711] | -0.217 [-0.272, -0.160] | -0.340 [-0.390, -0.289] | 0.881 | 0.679 | 0.641 | 0.603 @ 12 bits | 0.629 | 0.768 @ 14 bits |
| `pdq` | 0.616 [0.563, 0.671] | -0.261 [-0.313, -0.206] | -0.384 [-0.437, -0.329] | 0.843 | 0.631 | 0.607 | 0.549 @ 74 bits | 0.577 | 0.726 @ 86 bits |
| `ahash` | 0.493 [0.415, 0.574] | -0.385 [-0.452, -0.312] | -0.507 [-0.585, -0.426] | 0.907 | 0.653 | 0.473 | 0.000 @ none | 0.000 | 0.560 @ 2 bits |
| `whash` | 0.354 [0.246, 0.509] | -0.523 [-0.631, -0.382] | -0.646 [-0.754, -0.491] | 0.908 | 0.631 | 0.445 | 0.000 @ none | 0.000 | 0.502 @ 2 bits |

- **Top group:** DINOv3-small, SSCD, DINOv2-small, DINOv2-base and DINOv2-small-mean, all at 1.000. The copies are synthetic edits, so this is the easiest of the five sets for learned models.
- **The softened print** scores 0.877. Its main misses are screenshots and copy-vs-copy pairs (see [Copies by transform](#copies-by-transform)).

### gopro-bursts

264 images, 66 groups, 0 singles, 396 duplicate pairs, 33792 other pairs. 528 pairs left unscored (two moments of one clip). Sorted by AP. Differences are paired (same group resamples); top = `sscd-pad320`. R@FPR = recall at a false-positive rate of 1e-2 / 1e-3 (the looser regime inside a time window). R@P≥.99, R@P≥.95 and best F1 are ORACLE numbers (threshold picked on this dataset).

| Method | AP [95% CI] | AP − apple-fp2-soft [95% CI] | AP − top [95% CI] | ROC-AUC | R@FPR 1e-2 | R@FPR 1e-3 | oracle R@P≥.99 @ thr | oracle R@P≥.95 | oracle best F1 @ thr |
|---|---|---|---|---|---|---|---|---|---|
| `sscd-pad320` | 0.989 [0.961, 1.000] | 0.060 [0.030, 0.097] | — | 1.000 | 1.000 | 0.962 | 0.823 @ 0.292 | 0.919 | 0.941 @ 0.464 |
| `sscd-skew320` | 0.987 [0.959, 1.000] | 0.058 [0.028, 0.092] | -0.002 [-0.006, 0.001] | 1.000 | 0.997 | 0.944 | 0.826 @ 0.337 | 0.902 | 0.937 @ 0.470 |
| `sscd` | 0.984 [0.946, 1.000] | 0.054 [0.023, 0.092] | -0.006 [-0.017, 0.000] | 1.000 | 1.000 | 0.934 | 0.780 @ 0.342 | 0.889 | 0.929 @ 0.566 |
| `dinov3-small` | 0.951 [0.895, 0.986] | 0.021 [-0.021, 0.060] | -0.039 [-0.074, -0.012] | 0.997 | 0.972 | 0.856 | 0.581 @ 0.138 | 0.831 | 0.890 @ 0.229 |
| `dinov3-small-squash` | 0.943 [0.890, 0.983] | 0.013 [-0.023, 0.054] | -0.047 [-0.081, -0.015] | 0.998 | 0.975 | 0.838 | 0.636 @ 0.126 | 0.783 | 0.877 @ 0.211 |
| `apple-fp2-soft` | 0.930 [0.887, 0.965] | — | -0.060 [-0.097, -0.030] | 0.990 | 0.929 | 0.869 | 0.821 @ 0.393 | 0.861 | 0.909 @ 0.420 |
| `dinov2-small-mean` | 0.910 [0.859, 0.959] | -0.019 [-0.060, 0.019] | -0.079 [-0.131, -0.035] | 0.992 | 0.914 | 0.821 | 0.674 @ 0.117 | 0.793 | 0.871 @ 0.180 |
| `dinov2-base` | 0.909 [0.850, 0.959] | -0.020 [-0.062, 0.021] | -0.080 [-0.123, -0.040] | 0.993 | 0.937 | 0.785 | 0.606 @ 0.199 | 0.732 | 0.849 @ 0.317 |
| `ahash` | 0.892 [0.830, 0.942] | -0.038 [-0.088, 0.009] | -0.097 [-0.157, -0.049] | 0.990 | 0.902 | 0.831 | 0.674 @ 9 bits | 0.740 | 0.872 @ 11 bits |
| `dinov2-small-squash` | 0.884 [0.804, 0.959] | -0.046 [-0.112, 0.024] | -0.106 [-0.179, -0.039] | 0.996 | 0.919 | 0.657 | 0.528 @ 0.128 | 0.604 | 0.815 @ 0.287 |
| `dinov2-small-pad` | 0.884 [0.806, 0.954] | -0.046 [-0.110, 0.020] | -0.106 [-0.176, -0.044] | 0.993 | 0.939 | 0.677 | 0.500 @ 0.122 | 0.598 | 0.805 @ 0.242 |
| `dinov2-small` | 0.877 [0.805, 0.941] | -0.052 [-0.112, 0.006] | -0.112 [-0.179, -0.055] | 0.990 | 0.904 | 0.740 | 0.500 @ 0.161 | 0.646 | 0.813 @ 0.249 |
| `mobileclip` | 0.874 [0.818, 0.929] | -0.055 [-0.101, -0.017] | -0.115 [-0.168, -0.066] | 0.987 | 0.894 | 0.765 | 0.626 @ 0.122 | 0.712 | 0.834 @ 0.168 |
| `imagededup-cnn` | 0.873 [0.817, 0.929] | -0.056 [-0.096, -0.016] | -0.116 [-0.169, -0.066] | 0.977 | 0.876 | 0.806 | 0.646 @ 0.112 | 0.758 | 0.853 @ 0.176 |
| `whash` | 0.840 [0.768, 0.906] | -0.089 [-0.156, -0.027] | -0.149 [-0.225, -0.081] | 0.986 | 0.841 | 0.742 | 0.629 @ 8 bits | 0.629 | 0.822 @ 10 bits |
| `clip-b32-openai` | 0.810 [0.745, 0.872] | -0.120 [-0.175, -0.071] | -0.179 [-0.240, -0.120] | 0.980 | 0.813 | 0.689 | 0.591 @ 0.080 | 0.649 | 0.781 @ 0.093 |
| `phash` | 0.807 [0.744, 0.867] | -0.123 [-0.167, -0.078] | -0.182 [-0.245, -0.126] | 0.952 | 0.806 | 0.702 | 0.702 @ 16 bits | 0.702 | 0.822 @ 16 bits |
| `dhash` | 0.801 [0.731, 0.866] | -0.128 [-0.188, -0.075] | -0.188 [-0.258, -0.125] | 0.950 | 0.808 | 0.699 | 0.649 @ 14 bits | 0.699 | 0.809 @ 16 bits |
| `siglip2-base` | 0.800 [0.720, 0.879] | -0.129 [-0.198, -0.067] | -0.189 [-0.268, -0.117] | 0.979 | 0.828 | 0.644 | 0.374 @ 0.047 | 0.545 | 0.749 @ 0.081 |
| `apple-fp2-raw` | 0.631 [0.545, 0.723] | -0.299 [-0.372, -0.220] | -0.359 [-0.440, -0.273] | 0.952 | 0.659 | 0.460 | 0.278 @ 0.402 | 0.379 | 0.609 @ 0.565 |
| `pdq` | 0.625 [0.552, 0.701] | -0.305 [-0.367, -0.238] | -0.365 [-0.437, -0.289] | 0.811 | 0.616 | 0.581 | 0.535 @ 94 bits | 0.561 | 0.714 @ 98 bits |

- **Held-out real camera shake.** No threshold, link or setting was chosen on this set.
- **Top group:** the three SSCD input forms (0.984-0.989). Next come DINOv3-small (0.951) and the softened print (0.930).
- **Softening.** On this blur, softening helps the Vision print a lot: the raw print scores 0.631, a gap of −0.299 [−0.372, −0.220].
- **Other models.** DINOv2, SigLIP 2 and CLIP fall to 0.80-0.91. Hashes do much better here (aHash 0.892, pHash 0.807) than on real series, because the frames are not recomposed.

### screenshots

416 images, 100 groups, 216 singles, 100 duplicate pairs, 86220 other pairs. Sorted by AP. Differences are paired (same group resamples); top = `siglip2-base`. R@FPR = recall at a false-positive rate of 1e-2 / 1e-3 (the looser regime inside a time window). R@P≥.99, R@P≥.95 and best F1 are ORACLE numbers (threshold picked on this dataset).

| Method | AP [95% CI] | AP − apple-fp2-soft [95% CI] | AP − top [95% CI] | ROC-AUC | R@FPR 1e-2 | R@FPR 1e-3 | oracle R@P≥.99 @ thr | oracle R@P≥.95 | oracle best F1 @ thr |
|---|---|---|---|---|---|---|---|---|---|
| `siglip2-base` | 0.912 [0.814, 0.985] | 0.371 [0.244, 0.489] | — | 1.000 | 1.000 | 0.990 | 0.390 @ 0.003 | 0.430 | 0.894 @ 0.068 |
| `sscd-skew320` | 0.908 [0.836, 0.972] | 0.367 [0.267, 0.479] | -0.004 [-0.068, 0.075] | 1.000 | 1.000 | 0.990 | 0.420 @ 0.013 | 0.480 | 0.859 @ 0.184 |
| `sscd` | 0.894 [0.813, 0.967] | 0.353 [0.237, 0.466] | -0.018 [-0.068, 0.034] | 1.000 | 1.000 | 1.000 | 0.320 @ 0.007 | 0.490 | 0.824 @ 0.206 |
| `sscd-pad320` | 0.871 [0.798, 0.948] | 0.331 [0.234, 0.440] | -0.041 [-0.102, 0.015] | 1.000 | 1.000 | 0.990 | 0.440 @ 0.008 | 0.480 | 0.807 @ 0.196 |
| `dinov3-small-squash` | 0.863 [0.783, 0.942] | 0.322 [0.222, 0.426] | -0.049 [-0.114, 0.009] | 1.000 | 1.000 | 0.950 | 0.460 @ 0.008 | 0.480 | 0.811 @ 0.075 |
| `apple-fp2-raw` | 0.834 [0.714, 0.940] | 0.294 [0.143, 0.433] | -0.078 [-0.133, -0.023] | 1.000 | 0.990 | 0.970 | 0.130 @ 0.091 | 0.190 | 0.813 @ 0.474 |
| `imagededup-cnn` | 0.727 [0.653, 0.814] | 0.186 [0.120, 0.267] | -0.185 [-0.285, -0.085] | 0.997 | 0.900 | 0.750 | 0.460 @ 0.003 | 0.460 | 0.687 @ 0.041 |
| `phash` | 0.614 [0.514, 0.722] | 0.074 [0.021, 0.142] | -0.298 [-0.432, -0.177] | 0.966 | 0.820 | 0.620 | 0.360 @ 0 bits | 0.490 | 0.653 @ 2 bits |
| `dhash` | 0.598 [0.510, 0.699] | 0.058 [0.004, 0.119] | -0.314 [-0.424, -0.192] | 0.989 | 0.800 | 0.640 | 0.290 @ 0 bits | 0.460 | 0.637 @ 3 bits |
| `dinov2-small-squash` | 0.597 [0.514, 0.694] | 0.056 [0.015, 0.112] | -0.315 [-0.424, -0.198] | 0.991 | 0.830 | 0.570 | 0.440 @ 0.002 | 0.470 | 0.645 @ 0.004 |
| `pdq` | 0.579 [0.488, 0.681] | 0.038 [0.003, 0.085] | -0.333 [-0.454, -0.211] | 0.889 | 0.710 | 0.600 | 0.500 @ 4 bits | 0.500 | 0.667 @ 4 bits |
| `dinov2-small-pad` | 0.541 [0.456, 0.642] | 0.000 [-0.029, 0.037] | -0.371 [-0.486, -0.249] | 0.972 | 0.660 | 0.530 | 0.480 @ 0.002 | 0.480 | 0.649 @ 0.002 |
| `apple-fp2-soft` | 0.541 [0.452, 0.640] | — | -0.371 [-0.489, -0.244] | 0.983 | 0.690 | 0.510 | 0.480 @ 0.067 | 0.500 | 0.658 @ 0.093 |
| `clip-b32-openai` | 0.501 [0.295, 0.866] | -0.039 [-0.260, 0.320] | -0.411 [-0.630, -0.055] | 0.999 | 1.000 | 0.770 | 0.000 @ none | 0.000 | 0.682 @ 0.039 |
| `dinov3-small` | 0.495 [0.277, 0.869] | -0.045 [-0.273, 0.342] | -0.417 [-0.643, -0.047] | 0.999 | 1.000 | 0.910 | 0.010 @ 0.000 | 0.010 | 0.714 @ 0.038 |
| `mobileclip` | 0.427 [0.239, 0.824] | -0.113 [-0.318, 0.285] | -0.485 [-0.687, -0.091] | 0.999 | 1.000 | 0.890 | 0.010 @ 0.000 | 0.010 | 0.659 @ 0.053 |
| `dinov2-small-mean` | 0.386 [0.215, 0.736] | -0.154 [-0.355, 0.207] | -0.526 [-0.711, -0.166] | 0.999 | 1.000 | 0.760 | 0.000 @ none | 0.000 | 0.641 @ 0.022 |
| `dinov2-base` | 0.375 [0.214, 0.719] | -0.165 [-0.358, 0.184] | -0.537 [-0.716, -0.190] | 0.999 | 0.980 | 0.840 | 0.000 @ none | 0.000 | 0.637 @ 0.027 |
| `dinov2-small` | 0.340 [0.189, 0.677] | -0.201 [-0.378, 0.139] | -0.572 [-0.741, -0.227] | 0.998 | 0.990 | 0.680 | 0.000 @ none | 0.000 | 0.576 @ 0.018 |
| `whash` | 0.090 [0.051, 0.168] | -0.450 [-0.529, -0.365] | -0.822 [-0.903, -0.708] | 0.926 | 0.550 | 0.000 | 0.000 @ none | 0.000 | 0.238 @ 0 bits |
| `ahash` | 0.010 [0.007, 0.016] | -0.530 [-0.627, -0.442] | -0.902 [-0.974, -0.802] | 0.884 | 0.000 | 0.000 | 0.000 @ none | 0.000 | 0.029 @ 0 bits |

- **Top group:** SigLIP 2 0.912, SSCD-skew320 0.908, SSCD 0.894, SSCD-pad320 0.871 and DINOv3-small-squash 0.863. These CIs are wide, because there are only 100 duplicate pairs.
- **Center-cropped models collapse** (0.34-0.50), because the crop keeps only the middle of a tall screen.
- **Ranking is not usability.** At precision ≥ 0.99, oracle recall is at most 0.50 for every method (PDQ 0.500, DINOv2-small-pad 0.480, softened print 0.480, SSCD 0.320).

## Threshold transfer

### Threshold transfer (pair level)

One threshold per method, picked for precision ≥ 0.99 on the pooled dev halves, applied unchanged. FP/M = false duplicate calls per million unrelated pairs. Bootstrap CIs resample groups; where a score is perfect the bootstrap interval collapses, so the exact (Clopper-Pearson) 95% lower bound is given instead (pairs are not independent, so it is a floor on the uncertainty).

| Method | threshold | dev P / R | bursts-profile (test) P [CI] | R [CI] | FP/M | copies (test) P [CI] | R [CI] | FP/M | photo-triage (all) P [CI] | R [CI] | FP/M | gopro-bursts (all) P [CI] | R [CI] | FP/M | screenshots (all) P [CI] | R [CI] | FP/M |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 0.364 | 1.000 / 0.890 | 1.000 [1.000, 1.000] (CP ≥0.945) | 0.956 [0.875, 1.000] | 0 | 1.000 [1.000, 1.000] (CP ≥0.984) | 0.830 [0.766, 0.892] | 0 | 0.993 [0.960, 1.000] | 0.193 [0.151, 0.242] | 4 | 1.000 [1.000, 1.000] (CP ≥0.988) | 0.768 [0.682, 0.849] | 0 | 0.144 [0.094, 0.238] | 0.580 [0.485, 0.670] | 4013 |
| `apple-fp2-raw` | 0.575 | 0.992 / 0.830 | 1.000 [1.000, 1.000] (CP ≥0.888) | 0.456 [0.250, 0.628] | 0 | 0.976 [0.916, 1.000] | 0.889 [0.830, 0.943] | 128 | 0.941 [0.866, 0.986] | 0.814 [0.765, 0.857] | 135 | 0.702 [0.523, 0.926] | 0.530 [0.452, 0.614] | 2634 | 0.431 [0.318, 0.601] | 0.970 [0.931, 1.000] | 1485 |
| `ahash` | none | n/a / 0.000 | n/a | 0.000 [0.000, 0.000] | 0 | n/a | 0.000 [0.000, 0.000] | 0 | n/a | 0.000 [0.000, 0.000] | 0 | n/a | 0.000 [0.000, 0.000] | 0 | n/a | 0.000 [0.000, 0.000] | 0 |
| `phash` | 14 bits | 0.995 / 0.645 | 1.000 [1.000, 1.000] (CP ≥0.907) | 0.559 [0.417, 0.736] | 0 | 0.988 [0.930, 1.000] | 0.615 [0.543, 0.689] | 43 | 0.810 [0.667, 0.937] | 0.096 [0.071, 0.123] | 60 | 0.996 [0.976, 1.000] | 0.631 [0.558, 0.707] | 30 | 0.210 [0.145, 0.308] | 0.740 [0.660, 0.822] | 3236 |
| `dhash` | 9 bits | 0.994 / 0.564 | 1.000 [1.000, 1.000] (CP ≥0.877) | 0.412 [0.305, 0.564] | 0 | 1.000 [1.000, 1.000] (CP ≥0.974) | 0.526 [0.443, 0.613] | 0 | 0.872 [0.636, 1.000] | 0.058 [0.036, 0.080] | 23 | 1.000 [1.000, 1.000] (CP ≥0.980) | 0.452 [0.384, 0.523] | 0 | 0.427 [0.277, 0.639] | 0.640 [0.547, 0.728] | 997 |
| `whash` | none | n/a / 0.000 | n/a | 0.000 [0.000, 0.000] | 0 | n/a | 0.000 [0.000, 0.000] | 0 | n/a | 0.000 [0.000, 0.000] | 0 | n/a | 0.000 [0.000, 0.000] | 0 | n/a | 0.000 [0.000, 0.000] | 0 |
| `pdq` | 84 bits | 0.994 / 0.571 | 1.000 [1.000, 1.000] (CP ≥0.872) | 0.397 [0.270, 0.529] | 0 | 0.993 [0.961, 1.000] | 0.552 [0.477, 0.626] | 21 | 0.980 [0.893, 1.000] | 0.069 [0.046, 0.094] | 4 | 1.000 [1.000, 1.000] (CP ≥0.980) | 0.457 [0.391, 0.533] | 0 | 0.132 [0.089, 0.203] | 0.630 [0.541, 0.720] | 4825 |
| `imagededup-cnn` | 0.114 | 1.000 / 0.890 | 1.000 [1.000, 1.000] (CP ≥0.938) | 0.853 [0.712, 0.957] | 0 | 0.996 [0.975, 1.000] | 0.870 [0.807, 0.929] | 21 | 0.994 [0.961, 1.000] | 0.449 [0.391, 0.510] | 8 | 0.988 [0.945, 1.000] | 0.649 [0.556, 0.745] | 89 | 0.046 [0.033, 0.071] | 0.950 [0.904, 0.990] | 22791 |
| `clip-b32-openai` | 0.112 | 0.993 / 0.961 | 1.000 [1.000, 1.000] (CP ≥0.940) | 0.882 [0.803, 0.978] | 0 | 0.989 [0.945, 1.000] | 0.993 [0.974, 1.000] | 64 | 0.919 [0.813, 0.989] | 0.705 [0.651, 0.758] | 165 | 0.693 [0.523, 0.900] | 0.753 [0.682, 0.821] | 3906 | 0.307 [0.179, 0.576] | 0.970 [0.933, 1.000] | 2540 |
| `mobileclip` | 0.159 | 0.993 / 0.982 | 1.000 [1.000, 1.000] (CP ≥0.946) | 0.971 [0.915, 1.000] | 0 | 0.982 [0.921, 1.000] | 1.000 [1.000, 1.000] (CP ≥0.986) | 106 | 0.950 [0.861, 0.998] | 0.729 [0.666, 0.780] | 101 | 0.936 [0.828, 1.000] | 0.735 [0.657, 0.808] | 592 | 0.315 [0.200, 0.510] | 0.990 [0.969, 1.000] | 2494 |
| `siglip2-base` | 0.111 | 0.992 / 0.894 | 1.000 [1.000, 1.000] (CP ≥0.946) | 0.971 [0.915, 1.000] | 0 | 0.975 [0.915, 1.000] | 0.856 [0.792, 0.918] | 128 | 0.921 [0.823, 0.983] | 0.831 [0.788, 0.869] | 192 | 0.595 [0.430, 0.855] | 0.783 [0.715, 0.851] | 6244 | 0.515 [0.382, 0.683] | 1.000 [1.000, 1.000] (CP ≥0.964) | 1090 |
| `dinov2-small` | 0.245 | 0.993 / 1.000 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 1.000 [1.000, 1.000] (CP ≥0.986) | 1.000 [1.000, 1.000] (CP ≥0.986) | 0 | 0.950 [0.860, 0.996] | 0.689 [0.632, 0.745] | 98 | 0.903 [0.755, 1.000] | 0.727 [0.652, 0.801] | 917 | 0.012 [0.009, 0.016] | 1.000 [1.000, 1.000] (CP ≥0.964) | 98759 |
| `dinov2-small-mean` | 0.166 | 0.993 / 0.986 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 1.000 [1.000, 1.000] (CP ≥0.986) | 1.000 [1.000, 1.000] (CP ≥0.986) | 0 | 0.961 [0.890, 1.000] | 0.700 [0.641, 0.754] | 75 | 0.899 [0.724, 1.000] | 0.833 [0.763, 0.899] | 1095 | 0.019 [0.014, 0.026] | 1.000 [1.000, 1.000] (CP ≥0.964) | 60984 |
| `dinov2-base` | 0.217 | 0.993 / 1.000 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 1.000 [1.000, 1.000] (CP ≥0.986) | 0.996 [0.988, 1.000] | 0 | 0.946 [0.865, 0.993] | 0.616 [0.553, 0.670] | 94 | 0.977 [0.876, 1.000] | 0.657 [0.568, 0.745] | 178 | 0.034 [0.025, 0.052] | 1.000 [1.000, 1.000] (CP ≥0.964) | 32498 |
| `sscd` | 0.564 | 1.000 / 1.000 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 1.000 [1.000, 1.000] (CP ≥0.986) | 1.000 [1.000, 1.000] (CP ≥0.986) | 0 | 0.986 [0.940, 1.000] | 0.717 [0.655, 0.770] | 26 | 0.902 [0.715, 1.000] | 0.955 [0.919, 0.985] | 1213 | 0.055 [0.040, 0.077] | 1.000 [1.000, 1.000] (CP ≥0.964) | 19775 |
| `dinov3-small` | 0.193 | 1.000 / 1.000 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 1.000 [1.000, 1.000] (CP ≥0.986) | 0.993 [0.976, 1.000] | 0 | 0.983 [0.939, 1.000] | 0.584 [0.523, 0.641] | 26 | 0.975 [0.884, 1.000] | 0.780 [0.702, 0.854] | 237 | 0.226 [0.146, 0.362] | 0.980 [0.949, 1.000] | 3897 |
| `sscd-skew320` | 0.426 | 1.000 / 0.918 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 1.000 [1.000, 1.000] (CP ≥0.986) | 0.941 [0.892, 0.983] | 0 | 0.997 [0.984, 1.000] | 0.516 [0.454, 0.576] | 4 | 0.952 [0.823, 1.000] | 0.902 [0.848, 0.947] | 533 | 0.308 [0.222, 0.430] | 1.000 [1.000, 1.000] (CP ≥0.964) | 2610 |
| `sscd-pad320` | 0.355 | 0.992 / 0.908 | 1.000 [1.000, 1.000] (CP ≥0.946) | 0.971 [0.929, 1.000] | 0 | 1.000 [1.000, 1.000] (CP ≥0.985) | 0.907 [0.848, 0.957] | 0 | 0.997 [0.982, 1.000] | 0.440 [0.376, 0.501] | 4 | 0.960 [0.844, 1.000] | 0.904 [0.843, 0.952] | 444 | 0.267 [0.193, 0.377] | 1.000 [1.000, 1.000] (CP ≥0.964) | 3190 |
| `dinov2-small-squash` | 0.308 | 0.993 / 0.975 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 0.992 [0.967, 1.000] | 0.978 [0.946, 1.000] | 43 | 0.891 [0.775, 0.974] | 0.814 [0.760, 0.858] | 267 | 0.754 [0.540, 0.981] | 0.874 [0.813, 0.927] | 3344 | 0.002 [0.002, 0.003] | 1.000 [1.000, 1.000] (CP ≥0.964) | 475818 |
| `dinov2-small-pad` | 0.256 | 0.993 / 0.950 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 1.000 [1.000, 1.000] (CP ≥0.986) | 0.937 [0.890, 0.979] | 0 | 0.947 [0.858, 0.993] | 0.726 [0.668, 0.777] | 109 | 0.767 [0.555, 0.997] | 0.838 [0.778, 0.897] | 2989 | 0.002 [0.002, 0.003] | 1.000 [1.000, 1.000] (CP ≥0.964) | 488181 |
| `dinov3-small-squash` | 0.326 | 1.000 / 0.996 | 1.000 [1.000, 1.000] (CP ≥0.947) | 1.000 [1.000, 1.000] (CP ≥0.947) | 0 | 0.978 [0.896, 1.000] | 1.000 [1.000, 1.000] (CP ≥0.986) | 128 | 0.955 [0.875, 0.998] | 0.840 [0.795, 0.875] | 105 | 0.732 [0.542, 0.953] | 0.937 [0.894, 0.972] | 4025 | 0.016 [0.012, 0.022] | 1.000 [1.000, 1.000] (CP ≥0.964) | 71874 |

- **Test halves.** On the held-out halves of the generator data, SSCD, DINOv2-small, DINOv2-base and DINOv3-small all keep precision 1.000, with Clopper-Pearson lower bounds of 0.947 (bursts) and 0.986 (copies), and recall near 1.
- **Real series (never used).**
  - The most conservative signals keep precision ≥ 0.98: the softened print (0.993, recall 0.193), SSCD (0.986, recall 0.717), DINOv3-small (0.983, recall 0.584), the fixed-square SSCD forms (0.997) and imagededup-cnn (0.994).
  - The others drop to 0.81-0.96.
- **Real blur.** SSCD finds 0.955 of the pairs at precision 0.902. All 41 of its false calls are between clips of the same recording, which show the same place. The softened print keeps precision 1.000 at recall 0.768.
- **Screenshots.** Precision collapses for every method (0.002-0.52).

### Transfer threshold on the whole dev datasets

The test half leaves out pairs with one image in each half; those are all unrelated pairs, so false calls between the halves only show here. Last column: of the unscored gopro pairs (the other moment of the same clip, seconds later), the share called duplicates.

| Method | bursts-profile full set P / R | bursts-profile false calls on cross-split pairs | copies full set P / R | copies false calls on cross-split pairs | gopro: share of other-moment pairs linked |
|---|---|---|---|---|---|
| `apple-fp2-soft` | 1.000 / 0.975 | 0 of 2793 | 0.998 / 0.846 | 1 of 90244 | 0.087 |
| `apple-fp2-raw` | 0.984 / 0.529 | 1 of 2793 | 0.955 / 0.882 | 13 of 90244 | 0.335 |
| `ahash` | n/a / 0.000 | 0 of 2793 | n/a / 0.000 | 0 of 90244 | 0.000 |
| `phash` | 0.986 / 0.597 | 1 of 2793 | 0.987 / 0.629 | 1 of 90244 | 0.030 |
| `dhash` | 1.000 / 0.445 | 0 of 2793 | 0.993 / 0.551 | 1 of 90244 | 0.011 |
| `whash` | n/a / 0.000 | 0 of 2793 | n/a / 0.000 | 0 of 90244 | 0.000 |
| `pdq` | 0.962 / 0.429 | 2 of 2793 | 0.983 / 0.571 | 3 of 90244 | 0.023 |
| `imagededup-cnn` | 1.000 / 0.908 | 0 of 2793 | 0.993 / 0.870 | 2 of 90244 | 0.182 |
| `clip-b32-openai` | 0.917 / 0.924 | 10 of 2793 | 0.974 / 0.976 | 8 of 90244 | 0.345 |
| `mobileclip` | 1.000 / 0.983 | 0 of 2793 | 0.973 / 0.990 | 7 of 90244 | 0.242 |
| `siglip2-base` | 1.000 / 0.983 | 0 of 2793 | 0.952 / 0.862 | 14 of 90244 | 0.496 |
| `dinov2-small` | 1.000 / 1.000 | 0 of 2793 | 0.992 / 1.000 | 2 of 90244 | 0.311 |
| `dinov2-small-mean` | 1.000 / 0.992 | 0 of 2793 | 0.990 / 0.994 | 3 of 90244 | 0.402 |
| `dinov2-base` | 1.000 / 1.000 | 0 of 2793 | 0.984 / 0.998 | 6 of 90244 | 0.239 |
| `sscd` | 1.000 / 1.000 | 0 of 2793 | 0.994 / 1.000 | 3 of 90244 | 0.595 |
| `dinov3-small` | 1.000 / 1.000 | 0 of 2793 | 1.000 / 0.996 | 0 of 90244 | 0.235 |
| `sscd-skew320` | 1.000 / 0.992 | 0 of 2793 | 0.998 / 0.924 | 1 of 90244 | 0.271 |
| `sscd-pad320` | 1.000 / 0.975 | 0 of 2793 | 0.989 / 0.900 | 3 of 90244 | 0.239 |
| `dinov2-small-squash` | 0.952 / 1.000 | 6 of 2793 | 0.938 / 0.974 | 28 of 90244 | 0.585 |
| `dinov2-small-pad` | 1.000 / 1.000 | 0 of 2793 | 0.979 / 0.938 | 8 of 90244 | 0.502 |
| `dinov3-small-squash` | 1.000 / 1.000 | 0 of 2793 | 0.956 / 0.998 | 17 of 90244 | 0.661 |

- `sscd` false pairs on all of copies: cp34002.png / cp64198.png at 0.511, cp62982.jpg / cp65973.jpg at 0.535, cp20507.png / cp59099.png at 0.543
- `sscd-skew320` false pairs on all of copies: cp23731.png / cp67774.png at 0.415
- `dinov2-small` false pairs on all of copies: cp62982.jpg / cp65973.jpg at 0.168, cp58957.jpg / cp76465.jpg at 0.186, cp26701.jpg / cp47660.jpg at 0.193, cp26701.jpg / cp95697.jpg at 0.207
- `dinov3-small` false pairs on all of copies: none
- `apple-fp2-soft` false pairs on all of copies: cp20507.png / cp59099.png at 0.358

- **The test-half score was optimistic for SSCD.** On the whole copies set it scores precision 0.994, not 1.000.
  - Its 3 false pairs all cross the split, at distances 0.511-0.543, just inside the 0.564 threshold.
  - DINOv3-small makes no false calls (1.000 / 0.996). DINOv2-small makes 4 (0.992 / 1.000).
- **Squashed inputs pay the most here.** DINOv2-small-squash makes 28 false calls across the split, DINOv3-small-squash 17.
- **The last column** is the share of GoPro pairs from the same clip a few seconds later that each method calls duplicates. SSCD calls 60% of them. For a cleaner that is arguably right (same scene), but the scores leave these pairs out.

### Threshold transfer (group level: single-linkage clusters at the transfer threshold)

| Method | bursts-profile (test) pair P / R, exact groups, largest cluster | copies (test) pair P / R, exact groups, largest cluster | photo-triage (all) pair P / R, exact groups, largest cluster | gopro-bursts (all) pair P / R, exact groups, largest cluster | screenshots (all) pair P / R, exact groups, largest cluster |
|---|---|---|---|---|---|
| `apple-fp2-soft` | 1.000 / 1.000, 15/15, 5 | 1.000 / 0.833, 58/75, 4 | 0.988 / 0.224, 54/280, 8 | 1.000 / 0.803, 48/66, 4 | 0.012 / 0.590, 30/100, 97 |
| `apple-fp2-raw` | 1.000 / 0.529, 4/15, 5 | 0.969 / 0.919, 64/75, 4 | 0.822 / 0.852, 209/280, 12 | 0.345 / 0.636, 18/66, 27 | 0.056 / 0.970, 63/100, 56 |
| `ahash` | n/a / 0.000, 0/15, 0 | n/a / 0.000, 0/75, 0 | n/a / 0.000, 0/280, 0 | n/a / 0.000, 0/66, 0 | n/a / 0.000, 0/100, 0 |
| `phash` | 1.000 / 0.691, 8/15, 5 | 0.982 / 0.619, 37/75, 4 | 0.711 / 0.097, 27/280, 5 | 0.986 / 0.722, 38/66, 5 | 0.012 / 0.760, 44/100, 110 |
| `dhash` | 1.000 / 0.471, 4/15, 4 | 1.000 / 0.526, 34/75, 4 | 0.842 / 0.068, 13/280, 4 | 1.000 / 0.518, 22/66, 4 | 0.189 / 0.640, 48/100, 22 |
| `whash` | n/a / 0.000, 0/15, 0 | n/a / 0.000, 0/75, 0 | n/a / 0.000, 0/280, 0 | n/a / 0.000, 0/66, 0 | n/a / 0.000, 0/100, 0 |
| `pdq` | 1.000 / 0.500, 4/15, 5 | 0.993 / 0.552, 32/75, 4 | 0.980 / 0.069, 19/280, 3 | 1.000 / 0.520, 23/66, 4 | 0.014 / 0.630, 36/100, 90 |
| `imagededup-cnn` | 1.000 / 0.926, 13/15, 5 | 0.992 / 0.878, 62/75, 4 | 0.978 / 0.496, 125/280, 8 | 0.921 / 0.707, 37/66, 10 | 0.006 / 0.960, 40/100, 183 |
| `clip-b32-openai` | 1.000 / 1.000, 15/15, 5 | 0.982 / 1.000, 74/75, 4 | 0.867 / 0.790, 185/280, 8 | 0.218 / 0.838, 30/66, 46 | 0.197 / 0.970, 79/100, 28 |
| `mobileclip` | 1.000 / 1.000, 15/15, 5 | 0.968 / 1.000, 74/75, 5 | 0.920 / 0.762, 185/280, 8 | 0.755 / 0.808, 39/66, 12 | 0.101 / 1.000, 74/100, 41 |
| `siglip2-base` | 1.000 / 1.000, 15/15, 5 | 0.967 / 0.859, 60/75, 4 | 0.848 / 0.868, 212/280, 11 | 0.155 / 0.854, 26/66, 59 | 0.307 / 1.000, 73/100, 16 |
| `dinov2-small` | 1.000 / 1.000, 15/15, 5 | 1.000 / 1.000, 75/75, 4 | 0.904 / 0.724, 181/280, 8 | 0.623 / 0.801, 37/66, 20 | 0.003 / 1.000, 23/100, 278 |
| `dinov2-small-mean` | 1.000 / 1.000, 15/15, 5 | 1.000 / 1.000, 75/75, 4 | 0.933 / 0.740, 185/280, 8 | 0.733 / 0.886, 48/66, 16 | 0.003 / 1.000, 21/100, 263 |
| `dinov2-base` | 1.000 / 1.000, 15/15, 5 | 1.000 / 1.000, 75/75, 4 | 0.883 / 0.669, 157/280, 8 | 0.948 / 0.730, 39/66, 8 | 0.005 / 1.000, 36/100, 195 |
| `sscd` | 1.000 / 1.000, 15/15, 5 | 1.000 / 1.000, 75/75, 4 | 0.972 / 0.772, 204/280, 8 | 0.860 / 0.990, 61/66, 16 | 0.003 / 1.000, 25/100, 261 |
| `dinov3-small` | 1.000 / 1.000, 15/15, 5 | 1.000 / 1.000, 75/75, 4 | 0.972 / 0.644, 158/280, 8 | 0.913 / 0.848, 50/66, 12 | 0.098 / 0.980, 58/100, 36 |
| `sscd-skew320` | 1.000 / 1.000, 15/15, 5 | 1.000 / 0.941, 69/75, 4 | 0.991 / 0.591, 143/280, 8 | 0.855 / 0.949, 57/66, 16 | 0.025 / 1.000, 56/100, 89 |
| `sscd-pad320` | 1.000 / 1.000, 15/15, 5 | 1.000 / 0.907, 65/75, 4 | 0.997 / 0.505, 120/280, 8 | 0.921 / 0.944, 58/66, 12 | 0.017 / 1.000, 53/100, 107 |
| `dinov2-small-squash` | 1.000 / 1.000, 15/15, 5 | 0.985 / 0.978, 72/75, 4 | 0.805 / 0.855, 208/280, 11 | 0.576 / 0.934, 45/66, 20 | 0.002 / 1.000, 12/100, 349 |
| `dinov2-small-pad` | 1.000 / 1.000, 15/15, 5 | 1.000 / 0.941, 69/75, 4 | 0.897 / 0.774, 193/280, 8 | 0.559 / 0.922, 47/66, 24 | 0.002 / 1.000, 10/100, 348 |
| `dinov3-small-squash` | 1.000 / 1.000, 15/15, 5 | 0.975 / 1.000, 74/75, 5 | 0.925 / 0.880, 225/280, 8 | 0.600 / 0.970, 48/66, 20 | 0.003 / 1.000, 29/100, 247 |

- **Single linkage chains clusters together.**
  - On screenshots, SSCD's largest cluster has 261 images. On real blur it has 16, which is clips of one recording merged.
  - The [copy pass](#copy-pass-linkage-rules) section tests rules that stop this.
- **On real series,** SSCD reproduces 204/280 series exactly, against 54/280 for the softened print.

### The app's fixed link thresholds applied to all pairs (no time window)

Pair precision / recall on whole datasets. bursts-profile was used to calibrate these thresholds.

| Signal | preset | bursts-profile | photo-triage | copies | gopro-bursts | screenshots |
|---|---|---|---|---|---|---|
| `apple-fp2-soft` | strict (link 0.40) | 1.000 / 0.992 | 0.995 / 0.267 | 0.995 / 0.848 | 0.988 / 0.831 | 0.082 / 0.670 |
| `apple-fp2-soft` | balanced (link 0.55) | 1.000 / 1.000 | 0.927 / 0.589 | 0.918 / 0.852 | 0.377 / 0.939 | 0.012 / 0.940 |
| `apple-fp2-soft` | loose (link 0.70) | 0.960 / 1.000 | 0.312 / 0.872 | 0.362 / 0.876 | 0.062 / 0.975 | 0.003 / 1.000 |
| `apple-fp2-raw` | strict (link 0.40) | 1.000 / 0.261 | 0.996 / 0.385 | 1.000 / 0.814 | 0.991 / 0.275 | 0.798 / 0.710 |
| `apple-fp2-raw` | balanced (link 0.55) | 0.983 / 0.479 | 0.952 / 0.778 | 0.978 / 0.870 | 0.760 / 0.495 | 0.571 / 0.960 |
| `apple-fp2-raw` | loose (link 0.70) | 0.881 / 0.748 | 0.549 / 0.934 | 0.628 / 0.942 | 0.278 / 0.710 | 0.019 / 1.000 |

- **Without the window,** the app's balanced link would be imprecise on real series (0.927), real blur (0.377) and screenshots (0.012). The capture-time window is what keeps the app's precision high.

## Copies by transform

Recall on the copies test half at the transfer threshold (n = pairs), and in parentheses ROC-AUC of that transform's pairs against all unrelated pairs on the whole set (threshold-free). With n = 15-25 pairs a recall of 1.00 has a Clopper-Pearson 95% lower bound of 0.78-0.86. Single transforms are original vs copy.

| Method | color (n=19) | crop (n=15) | downscale (n=19) | heic_jpeg (n=21) | mirror (n=25) | reencode (n=19) | rotate (n=23) | screenshot (n=17) | copy vs copy (n=112) | copy vs copy, one is a screenshot (n=28) |
|---|---|---|---|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.00 (0.843) | 0.74 (0.970) | 0.00 (0.863) |
| `apple-fp2-raw` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.95 (1.000) | 1.00 (1.000) | 0.53 (0.992) | 0.81 (0.997) | 0.25 (0.988) |
| `ahash` | 0.00 (1.000) | 0.00 (0.990) | 0.00 (1.000) | 0.00 (1.000) | 0.00 (0.811) | 0.00 (1.000) | 0.00 (0.998) | 0.00 (0.629) | 0.00 (0.870) | 0.00 (0.638) |
| `phash` | 1.00 (1.000) | 0.73 (0.987) | 1.00 (1.000) | 1.00 (1.000) | 0.00 (0.502) | 1.00 (1.000) | 1.00 (1.000) | 0.24 (0.909) | 0.45 (0.829) | 0.18 (0.845) |
| `dhash` | 1.00 (1.000) | 0.33 (0.990) | 1.00 (1.000) | 1.00 (1.000) | 0.00 (0.676) | 1.00 (1.000) | 0.83 (1.000) | 0.00 (0.867) | 0.36 (0.874) | 0.00 (0.831) |
| `whash` | 0.00 (1.000) | 0.00 (0.990) | 0.00 (1.000) | 0.00 (1.000) | 0.00 (0.811) | 0.00 (1.000) | 0.00 (0.997) | 0.00 (0.610) | 0.00 (0.877) | 0.00 (0.666) |
| `pdq` | 1.00 (1.000) | 0.33 (0.875) | 1.00 (1.000) | 1.00 (1.000) | 0.00 (0.499) | 1.00 (1.000) | 0.96 (1.000) | 0.06 (0.761) | 0.38 (0.772) | 0.04 (0.712) |
| `imagededup-cnn` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.24 (0.956) | 0.80 (0.992) | 0.21 (0.965) |
| `clip-b32-openai` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.94 (1.000) | 0.99 (1.000) | 0.96 (1.000) |
| `mobileclip` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `siglip2-base` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.18 (0.994) | 0.78 (0.999) | 0.11 (0.993) |
| `dinov2-small` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `dinov2-small-mean` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `dinov2-base` | 1.00 (1.000) | 0.93 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `sscd` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `dinov3-small` | 1.00 (1.000) | 0.93 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.99 (1.000) | 1.00 (1.000) |
| `sscd-skew320` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.65 (1.000) | 0.91 (1.000) | 0.64 (1.000) |
| `sscd-pad320` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.41 (0.999) | 0.87 (1.000) | 0.46 (0.999) |
| `dinov2-small-squash` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.88 (1.000) | 0.96 (1.000) | 0.86 (1.000) |
| `dinov2-small-pad` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 0.65 (1.000) | 0.90 (1.000) | 0.61 (1.000) |
| `dinov3-small-squash` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |

- **Every transform found.** SSCD, DINOv2-small and -small-mean, MobileCLIP and DINOv3-small-squash find every transform, including copy-vs-copy pairs, at the carried-over threshold.
- **The softened print** finds no screenshot copies (0/17) and 74% of copy-vs-copy pairs.
- **Hashes** miss mirrored copies and most screenshots.
- **Small samples.** With 15-25 pairs per transform, the top methods can't be told apart on any single transform. A recall of 1.00 has a Clopper-Pearson lower bound of only 0.78-0.86.

## Screenshots

### screenshots: recall by transform

Recall on the screenshots whole set at the transfer threshold (n = pairs), and in parentheses ROC-AUC of that transform's pairs against all unrelated pairs on the whole set (threshold-free). With n = 15-25 pairs a recall of 1.00 has a Clopper-Pearson 95% lower bound of 0.78-0.86. Recall alone hides the cost: see precision below.

| Method | crop_bars (n=25) | heic (n=25) | resave (n=25) | rescreenshot (n=25) |
|---|---|---|---|---|
| `apple-fp2-soft` | 0.24 (0.978) | 1.00 (1.000) | 1.00 (1.000) | 0.08 (0.955) |
| `apple-fp2-raw` | 0.92 (0.999) | 1.00 (1.000) | 0.96 (1.000) | 1.00 (1.000) |
| `ahash` | 0.00 (0.808) | 0.00 (0.981) | 0.00 (0.979) | 0.00 (0.766) |
| `phash` | 0.76 (0.976) | 1.00 (1.000) | 1.00 (1.000) | 0.20 (0.887) |
| `dhash` | 0.48 (0.998) | 1.00 (1.000) | 1.00 (1.000) | 0.08 (0.958) |
| `whash` | 0.00 (0.904) | 0.00 (0.991) | 0.00 (0.997) | 0.00 (0.812) |
| `pdq` | 0.44 (0.985) | 1.00 (1.000) | 1.00 (1.000) | 0.08 (0.573) |
| `imagededup-cnn` | 0.96 (0.996) | 1.00 (1.000) | 1.00 (1.000) | 0.84 (0.990) |
| `clip-b32-openai` | 0.96 (0.999) | 1.00 (1.000) | 1.00 (1.000) | 0.92 (0.999) |
| `mobileclip` | 1.00 (0.999) | 1.00 (1.000) | 1.00 (0.999) | 0.96 (0.999) |
| `siglip2-base` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `dinov2-small` | 1.00 (0.999) | 1.00 (0.999) | 1.00 (0.998) | 1.00 (0.998) |
| `dinov2-small-mean` | 1.00 (0.999) | 1.00 (0.999) | 1.00 (0.999) | 1.00 (0.999) |
| `dinov2-base` | 1.00 (0.998) | 1.00 (0.999) | 1.00 (0.999) | 1.00 (0.999) |
| `sscd` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `dinov3-small` | 1.00 (0.999) | 1.00 (1.000) | 1.00 (1.000) | 0.92 (0.999) |
| `sscd-skew320` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `sscd-pad320` | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |
| `dinov2-small-squash` | 1.00 (0.971) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (0.992) |
| `dinov2-small-pad` | 1.00 (0.911) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (0.977) |
| `dinov3-small-squash` | 1.00 (0.999) | 1.00 (1.000) | 1.00 (1.000) | 1.00 (1.000) |

### screenshots: what the transfer threshold calls a duplicate

Real app screenshots, not used for any threshold. False calls split into two different screens of the same app (often the same screen in another state: one checkmark, an error banner, a typed field) and screens of different apps.

| Method | P / R | false calls, same app | false calls, other apps | closest same-app pair | closest other pair | farthest duplicate |
|---|---|---|---|---|---|---|
| `siglip2-base` | 0.515 / 1.000 | 45 of 486 | 49 of 85734 | 0.003 | 0.030 | 0.109 |
| `apple-fp2-raw` | 0.431 / 0.970 | 50 of 486 | 78 of 85734 | 0.091 | 0.262 | 0.644 |
| `dhash` | 0.427 / 0.640 | 23 of 486 | 63 of 85734 | 1 bits | 4 bits | 23 bits |
| `mobileclip` | 0.315 / 0.990 | 29 of 486 | 186 of 85734 | 0.000 | 0.000 | 0.205 |
| `sscd-skew320` | 0.308 / 1.000 | 78 of 486 | 147 of 85734 | 0.013 | 0.193 | 0.344 |
| `clip-b32-openai` | 0.307 / 0.970 | 22 of 486 | 197 of 85734 | 0.000 | 0.000 | 0.146 |
| `sscd-pad320` | 0.267 / 1.000 | 80 of 486 | 195 of 85734 | 0.008 | 0.142 | 0.311 |
| `dinov3-small` | 0.226 / 0.980 | 45 of 486 | 291 of 85734 | 0.000 | 0.000 | 0.220 |
| `phash` | 0.210 / 0.740 | 37 of 486 | 242 of 85734 | 4 bits | 2 bits | 34 bits |
| `apple-fp2-soft` | 0.144 / 0.580 | 71 of 486 | 275 of 85734 | 0.077 | 0.186 | 0.613 |
| `pdq` | 0.132 / 0.630 | 83 of 486 | 333 of 85734 | 8 bits | 52 bits | 148 bits |
| `sscd` | 0.055 / 1.000 | 150 of 486 | 1555 of 85734 | 0.007 | 0.184 | 0.281 |
| `imagededup-cnn` | 0.046 / 0.950 | 69 of 486 | 1896 of 85734 | 0.003 | 0.024 | 0.171 |
| `dinov2-base` | 0.034 / 1.000 | 90 of 486 | 2712 of 85734 | 0.000 | 0.000 | 0.175 |
| `dinov2-small-mean` | 0.019 / 1.000 | 118 of 486 | 5140 of 85734 | 0.000 | 0.000 | 0.077 |
| `dinov3-small-squash` | 0.016 / 1.000 | 152 of 486 | 6045 of 85734 | 0.009 | 0.041 | 0.199 |
| `dinov2-small` | 0.012 / 1.000 | 141 of 486 | 8374 of 85734 | 0.000 | 0.000 | 0.164 |
| `dinov2-small-squash` | 0.002 / 1.000 | 320 of 486 | 40705 of 85734 | 0.003 | 0.012 | 0.178 |
| `dinov2-small-pad` | 0.002 / 1.000 | 326 of 486 | 41765 of 85734 | 0.002 | 0.009 | 0.183 |
| `ahash` | n/a / 0.000 | 0 of 486 | 0 of 85734 | 0 bits | 0 bits | 49 bits |
| `whash` | n/a / 0.000 | 0 of 486 | 0 of 85734 | 0 bits | 0 bits | 36 bits |

- **The distributions overlap.** For every learned method, the closest pair of two different screens of one app is closer than the farthest true copy (SSCD: 0.007 against 0.281). Even screens of different apps come within it (SSCD: 0.184): white backgrounds, lists and bars look alike.
- **No threshold separates them.**
  - SSCD at its carried-over threshold makes 150 same-app and 1,555 other-app false calls.
  - The best precision at that threshold is SigLIP 2's 0.515.
  - At precision ≥ 0.99, only about half the copies are separable. SSCD's tight screen threshold catches 49 of the 50 resaved and HEIC copies and none of the 50 cropped or re-screenshotted ones.
- **The app avoids this today.** PhotoKitSource leaves screenshots out of the scan (`PHAssetMediaSubtype.photoScreenshot`).

## Copy pass: linkage rules

Library-wide copy finding has no time window to protect it, so the grouping rule matters. Each table applies the carried-over threshold with five rules.

### Copy pass, copies:test: library-wide linking without the time window

Pair P / R, exact groups, largest cluster, at the transfer threshold. single = connected components; complete = complete linkage cut at the threshold (every pair in a cluster within it); mutual-k = link only if each is among the other's k nearest; two-threshold = single linkage with a separate threshold for screen-shaped pairs (both portrait, h/w ≥ 1.6), picked for P ≥ 0.99 on the screenshots dev half (210 screen-shaped pairs here, 6 duplicates).

| Method | screen thr | single | complete | mutual-1nn | mutual-3nn | two-threshold |
|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 0.067 | 1.000 / 0.833, 58/75, 4 | 1.000 / 0.822, 57/75, 4 | 1.000 / 0.274, 20/75, 2 | 1.000 / 0.833, 58/75, 4 | 1.000 / 0.826, 58/75, 4 |
| `apple-fp2-raw` | 0.275 | 0.969 / 0.919, 64/75, 4 | 0.983 / 0.856, 60/75, 4 | 1.000 / 0.278, 20/75, 2 | 0.969 / 0.919, 64/75, 4 | 0.968 / 0.907, 63/75, 4 |
| `ahash` | none | — | — | — | — | — |
| `phash` | 4 bits | 0.982 / 0.619, 37/75, 4 | 1.000 / 0.611, 38/75, 4 | 1.000 / 0.259, 17/75, 2 | 0.982 / 0.619, 37/75, 4 | 0.982 / 0.611, 37/75, 4 |
| `dhash` | 2 bits | 1.000 / 0.526, 34/75, 4 | 1.000 / 0.526, 34/75, 4 | 1.000 / 0.244, 15/75, 2 | 1.000 / 0.526, 34/75, 4 | 1.000 / 0.526, 34/75, 4 |
| `whash` | none | — | — | — | — | — |
| `pdq` | 4 bits | 0.993 / 0.552, 32/75, 4 | 0.993 / 0.552, 32/75, 4 | 0.985 / 0.248, 15/75, 2 | 0.993 / 0.552, 32/75, 4 | 1.000 / 0.544, 32/75, 4 |
| `imagededup-cnn` | 0.008 | 0.992 / 0.878, 62/75, 4 | 1.000 / 0.867, 61/75, 4 | 1.000 / 0.274, 20/75, 2 | 0.992 / 0.878, 62/75, 4 | 0.991 / 0.859, 61/75, 4 |
| `clip-b32-openai` | none | 0.982 / 1.000, 74/75, 4 | 0.996 / 0.989, 74/75, 4 | 1.000 / 0.281, 21/75, 2 | 0.982 / 1.000, 74/75, 4 | — |
| `mobileclip` | none | 0.968 / 1.000, 74/75, 5 | 0.989 / 1.000, 74/75, 4 | 1.000 / 0.278, 21/75, 2 | 0.968 / 1.000, 74/75, 5 | — |
| `siglip2-base` | 0.027 | 0.967 / 0.859, 60/75, 4 | 0.979 / 0.848, 59/75, 4 | 0.987 / 0.278, 20/75, 2 | 0.967 / 0.859, 60/75, 4 | 0.971 / 0.859, 60/75, 4 |
| `dinov2-small` | none | 1.000 / 1.000, 75/75, 4 | 1.000 / 1.000, 75/75, 4 | 1.000 / 0.278, 21/75, 2 | 1.000 / 1.000, 75/75, 4 | — |
| `dinov2-small-mean` | none | 1.000 / 1.000, 75/75, 4 | 1.000 / 1.000, 75/75, 4 | 1.000 / 0.281, 21/75, 2 | 1.000 / 1.000, 75/75, 4 | — |
| `dinov2-base` | none | 1.000 / 1.000, 75/75, 4 | 1.000 / 0.993, 74/75, 4 | 1.000 / 0.278, 21/75, 2 | 1.000 / 1.000, 75/75, 4 | — |
| `sscd` | 0.034 | 1.000 / 1.000, 75/75, 4 | 1.000 / 1.000, 75/75, 4 | 1.000 / 0.278, 21/75, 2 | 1.000 / 1.000, 75/75, 4 | 1.000 / 0.981, 74/75, 4 |
| `dinov3-small` | none | 1.000 / 1.000, 75/75, 4 | 1.000 / 0.989, 74/75, 4 | 1.000 / 0.278, 21/75, 2 | 1.000 / 1.000, 75/75, 4 | — |
| `sscd-skew320` | 0.022 | 1.000 / 0.941, 69/75, 4 | 1.000 / 0.941, 69/75, 4 | 1.000 / 0.274, 20/75, 2 | 1.000 / 0.941, 69/75, 4 | 1.000 / 0.922, 68/75, 4 |
| `sscd-pad320` | 0.016 | 1.000 / 0.907, 65/75, 4 | 1.000 / 0.907, 65/75, 4 | 1.000 / 0.274, 20/75, 2 | 1.000 / 0.907, 65/75, 4 | 1.000 / 0.889, 64/75, 4 |
| `dinov2-small-squash` | 0.002 | 0.985 / 0.978, 72/75, 4 | 0.996 / 0.978, 73/75, 4 | 0.987 / 0.278, 21/75, 2 | 0.985 / 0.978, 72/75, 4 | 0.985 / 0.959, 71/75, 4 |
| `dinov2-small-pad` | 0.002 | 1.000 / 0.941, 69/75, 4 | 1.000 / 0.930, 68/75, 4 | 1.000 / 0.274, 20/75, 2 | 1.000 / 0.941, 69/75, 4 | 1.000 / 0.922, 68/75, 4 |
| `dinov3-small-squash` | 0.010 | 0.975 / 1.000, 74/75, 5 | 0.989 / 1.000, 74/75, 4 | 1.000 / 0.278, 21/75, 2 | 0.989 / 1.000, 74/75, 4 | 0.974 / 0.981, 73/75, 5 |

### Copy pass, copies:full: library-wide linking without the time window

Pair P / R, exact groups, largest cluster, at the transfer threshold. single = connected components; complete = complete linkage cut at the threshold (every pair in a cluster within it); mutual-k = link only if each is among the other's k nearest; two-threshold = single linkage with a separate threshold for screen-shaped pairs (both portrait, h/w ≥ 1.6), picked for P ≥ 0.99 on the screenshots dev half (666 screen-shaped pairs here, 6 duplicates).

| Method | screen thr | single | complete | mutual-1nn | mutual-3nn | two-threshold |
|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 0.067 | 0.998 / 0.848, 118/150, 4 | 0.998 / 0.842, 117/150, 4 | 0.993 / 0.287, 42/150, 2 | 0.998 / 0.848, 118/150, 4 | 1.000 / 0.844, 118/150, 4 |
| `apple-fp2-raw` | 0.275 | 0.917 / 0.900, 123/150, 6 | 0.977 / 0.862, 121/150, 4 | 0.967 / 0.293, 43/150, 2 | 0.934 / 0.900, 124/150, 6 | 0.920 / 0.894, 122/150, 6 |
| `ahash` | none | — | — | — | — | — |
| `phash` | 4 bits | 0.985 / 0.637, 76/150, 4 | 0.994 / 0.623, 75/150, 4 | 0.985 / 0.269, 35/150, 2 | 0.985 / 0.637, 76/150, 4 | 0.988 / 0.633, 76/150, 4 |
| `dhash` | 2 bits | 0.989 / 0.553, 67/150, 4 | 0.996 / 0.549, 67/150, 4 | 0.992 / 0.257, 32/150, 2 | 0.989 / 0.553, 67/150, 4 | 0.993 / 0.553, 67/150, 4 |
| `whash` | none | — | — | — | — | — |
| `pdq` | 4 bits | 0.976 / 0.575, 67/150, 4 | 0.986 / 0.567, 66/150, 4 | 0.985 / 0.263, 32/150, 2 | 0.976 / 0.575, 67/150, 4 | 1.000 / 0.571, 67/150, 4 |
| `imagededup-cnn` | 0.008 | 0.991 / 0.874, 123/150, 4 | 0.995 / 0.868, 122/150, 4 | 0.986 / 0.291, 43/150, 2 | 0.991 / 0.874, 123/150, 4 | 0.993 / 0.864, 122/150, 4 |
| `clip-b32-openai` | none | 0.969 / 0.982, 145/150, 6 | 0.986 / 0.970, 143/150, 4 | 0.980 / 0.299, 47/150, 2 | 0.969 / 0.982, 145/150, 6 | — |
| `mobileclip` | none | 0.954 / 0.990, 146/150, 7 | 0.976 / 0.990, 146/150, 4 | 0.980 / 0.299, 48/150, 2 | 0.976 / 0.990, 146/150, 4 | — |
| `siglip2-base` | 0.027 | 0.923 / 0.864, 120/150, 6 | 0.973 / 0.858, 120/150, 4 | 0.967 / 0.291, 43/150, 2 | 0.931 / 0.864, 121/150, 6 | 0.929 / 0.864, 120/150, 6 |
| `dinov2-small` | none | 0.992 / 1.000, 149/150, 4 | 0.992 / 1.000, 149/150, 4 | 0.987 / 0.301, 48/150, 2 | 0.992 / 1.000, 149/150, 4 | — |
| `dinov2-small-mean` | none | 0.990 / 0.994, 145/150, 4 | 0.990 / 0.994, 145/150, 4 | 1.000 / 0.297, 45/150, 2 | 0.990 / 0.994, 145/150, 4 | — |
| `dinov2-base` | none | 0.975 / 1.000, 147/150, 6 | 0.990 / 0.996, 148/150, 4 | 0.980 / 0.299, 48/150, 2 | 0.990 / 1.000, 149/150, 4 | — |
| `sscd` | 0.034 | 0.952 / 1.000, 146/150, 8 | 0.998 / 1.000, 150/150, 4 | 0.993 / 0.299, 48/150, 2 | 0.998 / 1.000, 150/150, 4 | 0.998 / 0.990, 149/150, 4 |
| `dinov3-small` | none | 1.000 / 1.000, 150/150, 4 | 1.000 / 0.994, 149/150, 4 | 1.000 / 0.301, 48/150, 2 | 1.000 / 1.000, 150/150, 4 | — |
| `sscd-skew320` | 0.022 | 0.998 / 0.924, 133/150, 4 | 0.998 / 0.924, 133/150, 4 | 0.993 / 0.289, 43/150, 2 | 0.998 / 0.924, 133/150, 4 | 1.000 / 0.914, 132/150, 4 |
| `sscd-pad320` | 0.016 | 0.978 / 0.900, 128/150, 5 | 0.991 / 0.900, 128/150, 4 | 0.986 / 0.289, 43/150, 2 | 0.978 / 0.900, 128/150, 5 | 1.000 / 0.890, 127/150, 4 |
| `dinov2-small-squash` | 0.002 | 0.902 / 0.976, 135/150, 8 | 0.947 / 0.970, 138/150, 7 | 0.980 / 0.297, 46/150, 2 | 0.966 / 0.976, 141/150, 4 | 0.929 / 0.966, 136/150, 7 |
| `dinov2-small-pad` | 0.002 | 0.971 / 0.940, 132/150, 6 | 0.992 / 0.934, 134/150, 4 | 0.986 / 0.289, 43/150, 2 | 0.987 / 0.940, 134/150, 4 | 0.971 / 0.930, 131/150, 6 |
| `dinov3-small-squash` | 0.010 | 0.921 / 0.998, 142/150, 8 | 0.967 / 0.998, 146/150, 7 | 0.987 / 0.297, 47/150, 2 | 0.986 / 0.998, 147/150, 4 | 0.948 / 0.988, 143/150, 7 |

### Copy pass, screenshots:test: library-wide linking without the time window

Pair P / R, exact groups, largest cluster, at the transfer threshold. single = connected components; complete = complete linkage cut at the threshold (every pair in a cluster within it); mutual-k = link only if each is among the other's k nearest; two-threshold = single linkage with a separate threshold for screen-shaped pairs (both portrait, h/w ≥ 1.6), picked for P ≥ 0.99 on the screenshots dev half (21528 screen-shaped pairs here, 50 duplicates).

| Method | screen thr | single | complete | mutual-1nn | mutual-3nn | two-threshold |
|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 0.067 | 0.067 / 0.560, 21/50, 26 | 0.500 / 0.560, 23/50, 4 | 0.737 / 0.560, 28/50, 2 | 0.373 / 0.560, 24/50, 6 | 1.000 / 0.500, 25/50, 2 |
| `apple-fp2-raw` | 0.275 | 0.286 / 0.960, 41/50, 13 | 0.712 / 0.940, 44/50, 4 | 0.839 / 0.940, 47/50, 2 | 0.429 / 0.960, 41/50, 7 | 0.923 / 0.480, 24/50, 2 |
| `ahash` | none | — | — | — | — | — |
| `phash` | 4 bits | 0.172 / 0.720, 30/50, 16 | 0.493 / 0.680, 31/50, 5 | 0.686 / 0.700, 35/50, 2 | 0.305 / 0.720, 31/50, 8 | 1.000 / 0.520, 26/50, 2 |
| `dhash` | 2 bits | 0.297 / 0.700, 33/50, 13 | 0.739 / 0.680, 33/50, 4 | 0.872 / 0.680, 34/50, 2 | 0.531 / 0.680, 33/50, 7 | 1.000 / 0.480, 24/50, 2 |
| `whash` | none | — | — | — | — | — |
| `pdq` | 4 bits | 0.061 / 0.620, 22/50, 29 | 0.392 / 0.620, 25/50, 5 | 0.646 / 0.620, 31/50, 2 | 0.208 / 0.620, 24/50, 8 | 1.000 / 0.520, 26/50, 2 |
| `imagededup-cnn` | 0.008 | 0.013 / 0.940, 23/50, 86 | 0.288 / 0.900, 30/50, 8 | 0.878 / 0.860, 43/50, 2 | 0.179 / 0.940, 28/50, 13 | 1.000 / 0.520, 26/50, 2 |
| `clip-b32-openai` | none | 0.343 / 0.960, 42/50, 14 | 0.500 / 0.960, 44/50, 10 | 0.980 / 0.960, 48/50, 2 | 0.814 / 0.960, 45/50, 4 | — |
| `mobileclip` | none | 0.145 / 1.000, 39/50, 24 | 0.419 / 0.980, 42/50, 11 | 0.923 / 0.960, 48/50, 2 | 0.438 / 0.980, 39/50, 6 | — |
| `siglip2-base` | 0.027 | 0.562 / 1.000, 43/50, 7 | 0.833 / 1.000, 47/50, 3 | 0.907 / 0.980, 49/50, 2 | 0.562 / 1.000, 43/50, 7 | 1.000 / 0.580, 29/50, 2 |
| `dinov2-small` | none | 0.008 / 1.000, 17/50, 115 | 0.088 / 1.000, 20/50, 19 | 0.842 / 0.960, 48/50, 2 | 0.305 / 1.000, 32/50, 10 | — |
| `dinov2-small-mean` | none | 0.007 / 1.000, 13/50, 119 | 0.088 / 1.000, 19/50, 20 | 0.787 / 0.960, 48/50, 2 | 0.218 / 1.000, 26/50, 12 | — |
| `dinov2-base` | none | 0.014 / 1.000, 24/50, 84 | 0.161 / 1.000, 28/50, 12 | 0.845 / 0.980, 49/50, 2 | 0.323 / 1.000, 33/50, 8 | — |
| `sscd` | 0.034 | 0.006 / 1.000, 16/50, 127 | 0.376 / 1.000, 34/50, 6 | 0.833 / 1.000, 50/50, 2 | 0.132 / 1.000, 30/50, 21 | 1.000 / 0.520, 26/50, 2 |
| `dinov3-small` | none | 0.160 / 0.980, 36/50, 21 | 0.358 / 0.980, 38/50, 10 | 0.923 / 0.960, 48/50, 2 | 0.636 / 0.980, 38/50, 4 | — |
| `sscd-skew320` | 0.022 | 0.151 / 1.000, 39/50, 24 | 0.735 / 1.000, 45/50, 4 | 0.943 / 1.000, 50/50, 2 | 0.357 / 1.000, 39/50, 11 | 1.000 / 0.500, 25/50, 2 |
| `sscd-pad320` | 0.016 | 0.086 / 1.000, 37/50, 33 | 0.700 / 0.980, 44/50, 3 | 0.925 / 0.980, 49/50, 2 | 0.190 / 1.000, 38/50, 20 | 1.000 / 0.520, 26/50, 2 |
| `dinov2-small-squash` | 0.002 | 0.003 / 1.000, 8/50, 171 | 0.012 / 0.960, 9/50, 88 | 0.750 / 0.840, 42/50, 2 | 0.272 / 0.860, 27/50, 10 | 1.000 / 0.480, 24/50, 2 |
| `dinov2-small-pad` | 0.002 | 0.003 / 1.000, 7/50, 173 | 0.026 / 0.960, 10/50, 44 | 0.788 / 0.820, 41/50, 2 | 0.209 / 0.860, 25/50, 11 | 1.000 / 0.520, 26/50, 2 |
| `dinov3-small-squash` | 0.010 | 0.009 / 1.000, 18/50, 108 | 0.148 / 0.940, 24/50, 12 | 0.772 / 0.880, 44/50, 2 | 0.137 / 0.960, 32/50, 23 | 1.000 / 0.480, 24/50, 2 |

### Copy pass, screenshots:all: library-wide linking without the time window

Pair P / R, exact groups, largest cluster, at the transfer threshold. single = connected components; complete = complete linkage cut at the threshold (every pair in a cluster within it); mutual-k = link only if each is among the other's k nearest; two-threshold = single linkage with a separate threshold for screen-shaped pairs (both portrait, h/w ≥ 1.6), picked for P ≥ 0.99 on the screenshots dev half (86320 screen-shaped pairs here, 100 duplicates).

| Method | screen thr | single | complete | mutual-1nn | mutual-3nn | two-threshold |
|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 0.067 | 0.012 / 0.590, 30/100, 97 | 0.301 / 0.560, 35/100, 8 | 0.667 / 0.560, 56/100, 2 | 0.223 / 0.590, 34/100, 9 | — |
| `apple-fp2-raw` | 0.275 | 0.056 / 0.970, 63/100, 56 | 0.623 / 0.960, 84/100, 6 | 0.807 / 0.920, 92/100, 2 | 0.260 / 0.970, 66/100, 17 | — |
| `ahash` | none | — | — | — | — | — |
| `phash` | 4 bits | 0.012 / 0.760, 44/100, 110 | 0.378 / 0.680, 52/100, 5 | 0.676 / 0.690, 69/100, 2 | 0.077 / 0.700, 47/100, 34 | — |
| `dhash` | 2 bits | 0.189 / 0.640, 48/100, 22 | 0.585 / 0.620, 53/100, 5 | 0.803 / 0.610, 61/100, 2 | 0.441 / 0.630, 49/100, 8 | — |
| `whash` | none | — | — | — | — | — |
| `pdq` | 4 bits | 0.014 / 0.630, 36/100, 90 | 0.285 / 0.630, 43/100, 7 | 0.656 / 0.630, 63/100, 2 | 0.152 / 0.630, 42/100, 13 | — |
| `imagededup-cnn` | 0.008 | 0.006 / 0.960, 40/100, 183 | 0.254 / 0.900, 53/100, 9 | 0.810 / 0.850, 85/100, 2 | 0.153 / 0.900, 51/100, 23 | — |
| `clip-b32-openai` | none | 0.197 / 0.970, 79/100, 28 | 0.399 / 0.970, 81/100, 16 | 0.941 / 0.950, 95/100, 2 | 0.610 / 0.970, 80/100, 8 | — |
| `mobileclip` | none | 0.101 / 1.000, 74/100, 41 | 0.406 / 0.990, 82/100, 15 | 0.899 / 0.980, 98/100, 2 | 0.462 / 0.980, 75/100, 10 | — |
| `siglip2-base` | 0.027 | 0.307 / 1.000, 73/100, 16 | 0.602 / 1.000, 82/100, 6 | 0.826 / 0.950, 95/100, 2 | 0.433 / 1.000, 74/100, 8 | — |
| `dinov2-small` | none | 0.003 / 1.000, 23/100, 278 | 0.067 / 0.990, 29/100, 27 | 0.760 / 0.920, 92/100, 2 | 0.252 / 0.980, 45/100, 10 | — |
| `dinov2-small-mean` | none | 0.003 / 1.000, 21/100, 263 | 0.087 / 1.000, 31/100, 22 | 0.756 / 0.930, 93/100, 2 | 0.237 / 0.990, 49/100, 9 | — |
| `dinov2-base` | none | 0.005 / 1.000, 36/100, 195 | 0.121 / 1.000, 43/100, 26 | 0.835 / 0.960, 96/100, 2 | 0.235 / 0.990, 55/100, 14 | — |
| `sscd` | 0.034 | 0.003 / 1.000, 25/100, 261 | 0.270 / 1.000, 53/100, 9 | 0.752 / 0.970, 97/100, 2 | 0.106 / 1.000, 45/100, 24 | — |
| `dinov3-small` | none | 0.098 / 0.980, 58/100, 36 | 0.314 / 0.980, 69/100, 13 | 0.870 / 0.940, 94/100, 2 | 0.427 / 0.970, 64/100, 8 | — |
| `sscd-skew320` | 0.022 | 0.025 / 1.000, 56/100, 89 | 0.513 / 1.000, 74/100, 6 | 0.831 / 0.980, 98/100, 2 | 0.200 / 1.000, 59/100, 21 | — |
| `sscd-pad320` | 0.016 | 0.017 / 1.000, 53/100, 107 | 0.497 / 0.980, 76/100, 6 | 0.812 / 0.950, 95/100, 2 | 0.148 / 1.000, 61/100, 29 | — |
| `dinov2-small-squash` | 0.002 | 0.002 / 1.000, 12/100, 349 | 0.012 / 0.920, 18/100, 106 | 0.717 / 0.810, 81/100, 2 | 0.191 / 0.900, 38/100, 14 | — |
| `dinov2-small-pad` | 0.002 | 0.002 / 1.000, 10/100, 348 | 0.009 / 0.880, 14/100, 117 | 0.706 / 0.770, 77/100, 2 | 0.160 / 0.840, 36/100, 14 | — |
| `dinov3-small-squash` | 0.010 | 0.003 / 1.000, 29/100, 247 | 0.134 / 0.970, 39/100, 16 | 0.750 / 0.900, 90/100, 2 | 0.159 / 0.980, 48/100, 25 | — |

- **Whole copies set.** Complete linkage fixes SSCD's chaining: 0.998 / 1.000 with 150/150 groups exact. Single linkage gives 0.952 / 1.000, 146/150, and a cluster of 8. Mutual-3nn does as well as complete linkage.
  - DINOv3-small is exact with plain single linkage (1.000 / 1.000).
  - DINOv2-small scores 0.992 / 1.000 with complete linkage.
- **Mutual-1nn only links pairs.** On copies, with 1-3 copies per original, it finds about 30% of the pairs. Its strong screenshot numbers come partly from that set having exactly one copy per screen.
- **The two-threshold rule** applies a tighter threshold to screen-shaped pairs.
  - On the screenshots test half it gives precision 1.000 at recall 0.48-0.58 for every method.
  - On photo copies it costs little: SSCD scores 0.998 / 0.990 on the whole set.
  - It is tuned on the screenshots dev half, so it is not reported on all of screenshots.
- **Complete linkage on the screenshots test half:** best SigLIP 2 (0.833 / 1.000), then SSCD-skew320 (0.735 / 1.000). SSCD scores 0.376 / 1.000.

## Inside the time window

series_port.py (SeriesBuilder + Scanner.groups, checked against tkscan) with each embedding int8-quantized and compared by Euclidean distance as the app stores it. Configs (link/anchor): transfer = the transfer threshold as a link; window-dev = the link with the most recall at in-window pair precision ≥ 0.99 on photo-triage-tight:dev (real series packed 10-60 s apart); app = the app's own presets (apple prints only). Timing: balanced (maxGap 60 s, maxSpan 240 s) except 'app strict'. Cells: pair P / R. screenshots: only false pairs (its copies are hours to weeks after the original, so never in a window). The copies part dates each copy as its original, as Photos' Duplicate does; real copies (saved, downloaded, screenshotted) get a new date and never meet the window.

| Method | config (link/anchor) | bursts-profile:test | photo-triage:all | photo-triage-tight:test | gopro-bursts:all | screenshots:all | copies:test, copies dated as their original |
|---|---|---|---|---|---|---|---|
| `apple-fp2-soft` | transfer (0.364/0.431) | 1.000 / 0.956 | 1.000 / 0.186 | 0.971 / 0.196 | 1.000 / 0.747, 86 other-moment | 4 false pairs | 1.000 / 0.833 |
| `apple-fp2-soft` | window-dev (0.582/0.687) | 1.000 / 1.000 | 1.000 / 0.655 | 0.983 / 0.660 | 0.540 / 0.949, 422 other-moment | 10 false pairs | 1.000 / 0.852 |
| `apple-fp2-soft` | app balanced (0.550/0.650) | 1.000 / 1.000 | 1.000 / 0.606 | 0.982 / 0.631 | 0.708 / 0.932, 383 other-moment | 8 false pairs | 1.000 / 0.844 |
| `apple-fp2-soft` | app strict (0.400/0.500) | 1.000 / 0.956 | 1.000 / 0.269 | 1.000 / 0.282 | 1.000 / 0.841, 116 other-moment | 4 false pairs | 1.000 / 0.833 |
| `apple-fp2-raw` | transfer (0.575/0.680) | 1.000 / 0.485 | 1.000 / 0.821 | 1.000 / 0.801 | 0.771 / 0.543, 206 other-moment | 3 false pairs | 1.000 / 0.919 |
| `apple-fp2-raw` | window-dev (0.497/0.588) | 1.000 / 0.412 | 1.000 / 0.664 | 1.000 / 0.677 | 0.869 / 0.402, 143 other-moment | 3 false pairs | 1.000 / 0.830 |
| `apple-fp2-raw` | app balanced (0.550/0.650) | 1.000 / 0.441 | 1.000 / 0.795 | 1.000 / 0.781 | 0.740 / 0.503, 191 other-moment | 3 false pairs | 1.000 / 0.881 |
| `apple-fp2-raw` | app strict (0.400/0.500) | 1.000 / 0.176 | 1.000 / 0.383 | 1.000 / 0.441 | 1.000 / 0.283, 68 other-moment | 1 false pairs | 1.000 / 0.793 |
| `ahash` | window-dev (0.000/0.000) | 1.000 / 0.029 | 1.000 / 0.010 | 0.833 / 0.014 | 1.000 / 0.124 | 4 false pairs | 1.000 / 0.326 |
| `phash` | transfer (3.742/4.422) | 1.000 / 0.515 | 1.000 / 0.089 | 1.000 / 0.112 | 1.000 / 0.641, 16 other-moment | 5 false pairs | 1.000 / 0.611 |
| `phash` | window-dev (4.243/5.014) | 0.929 / 0.765 | 1.000 / 0.149 | 0.984 / 0.182 | 1.000 / 0.773, 64 other-moment | 5 false pairs | 1.000 / 0.648 |
| `dhash` | transfer (3.000/3.545) | 1.000 / 0.471 | 1.000 / 0.052 | 1.000 / 0.063 | 1.000 / 0.467, 16 other-moment | 3 false pairs | 1.000 / 0.526 |
| `dhash` | window-dev (4.000/4.727) | 1.000 / 0.750 | 1.000 / 0.187 | 1.000 / 0.190 | 1.000 / 0.705, 16 other-moment | 7 false pairs | 1.000 / 0.619 |
| `whash` | window-dev (2.828/3.343) | 1.000 / 0.632 | 1.000 / 0.215 | 0.953 / 0.233 | 1.000 / 0.636, 40 other-moment | 4 false pairs | 1.000 / 0.600 |
| `pdq` | transfer (9.165/10.832) | 1.000 / 0.338 | 1.000 / 0.066 | 1.000 / 0.084 | 1.000 / 0.487, 16 other-moment | 6 false pairs | 1.000 / 0.552 |
| `pdq` | window-dev (10.000/11.818) | 1.000 / 0.544 | 1.000 / 0.100 | 1.000 / 0.124 | 1.000 / 0.568, 32 other-moment | 11 false pairs | 1.000 / 0.581 |
| `imagededup-cnn` | transfer (0.478/0.565) | 1.000 / 0.809 | 1.000 / 0.439 | 1.000 / 0.435 | 1.000 / 0.639, 152 other-moment | 4 false pairs | 1.000 / 0.878 |
| `imagededup-cnn` | window-dev (0.690/0.816) | 1.000 / 1.000 | 1.000 / 0.864 | 0.987 / 0.867 | 0.842 / 0.861, 381 other-moment | 6 false pairs | 1.000 / 0.941 |
| `clip-b32-openai` | transfer (0.472/0.558) | 1.000 / 0.956 | 1.000 / 0.714 | 0.984 / 0.729 | 0.917 / 0.750, 224 other-moment | 2 false pairs | 1.000 / 0.989 |
| `clip-b32-openai` | window-dev (0.406/0.480) | 1.000 / 0.779 | 1.000 / 0.513 | 0.979 / 0.550 | 1.000 / 0.621, 102 other-moment | 2 false pairs | 1.000 / 0.974 |
| `mobileclip` | transfer (0.563/0.666) | 1.000 / 1.000 | 1.000 / 0.724 | 0.985 / 0.744 | 0.925 / 0.745, 199 other-moment | 3 false pairs | 1.000 / 1.000 |
| `mobileclip` | window-dev (0.544/0.643) | 1.000 / 1.000 | 1.000 / 0.686 | 0.984 / 0.695 | 0.922 / 0.717, 173 other-moment | 2 false pairs | 1.000 / 1.000 |
| `siglip2-base` | transfer (0.471/0.557) | 1.000 / 1.000 | 1.000 / 0.823 | 0.986 / 0.821 | 0.666 / 0.745, 322 other-moment | 3 false pairs | 1.000 / 0.859 |
| `siglip2-base` | window-dev (0.434/0.513) | 1.000 / 1.000 | 1.000 / 0.740 | 0.985 / 0.738 | 0.696 / 0.710, 232 other-moment | 3 false pairs | 1.000 / 0.841 |
| `dinov2-small` | transfer (0.700/0.827) | 1.000 / 1.000 | 1.000 / 0.699 | 0.983 / 0.683 | 0.817 / 0.720, 196 other-moment | 5 false pairs | 1.000 / 1.000 |
| `dinov2-small` | window-dev (0.798/0.943) | 1.000 / 1.000 | 1.000 / 0.788 | 0.986 / 0.798 | 0.819 / 0.823, 317 other-moment | 7 false pairs | 1.000 / 1.000 |
| `dinov2-small-mean` | transfer (0.577/0.682) | 1.000 / 1.000 | 1.000 / 0.709 | 0.992 / 0.677 | 0.913 / 0.848, 252 other-moment | 6 false pairs | 1.000 / 1.000 |
| `dinov2-small-mean` | window-dev (0.543/0.642) | 1.000 / 1.000 | 1.000 / 0.675 | 0.991 / 0.651 | 0.910 / 0.813, 244 other-moment | 5 false pairs | 1.000 / 0.981 |
| `dinov2-base` | transfer (0.659/0.779) | 1.000 / 1.000 | 1.000 / 0.627 | 0.974 / 0.654 | 1.000 / 0.664, 158 other-moment | 4 false pairs | 1.000 / 0.993 |
| `dinov2-base` | window-dev (0.746/0.882) | 1.000 / 1.000 | 1.000 / 0.726 | 0.970 / 0.738 | 0.984 / 0.768, 228 other-moment | 5 false pairs | 1.000 / 1.000 |
| `sscd` | transfer (1.062/1.255) | 1.000 / 1.000 | 1.000 / 0.748 | 0.992 / 0.749 | 1.000 / 0.970, 376 other-moment | 10 false pairs | 1.000 / 1.000 |
| `sscd` | window-dev (1.114/1.317) | 1.000 / 1.000 | 1.000 / 0.819 | 0.986 / 0.790 | 1.000 / 0.990, 416 other-moment | 12 false pairs | 1.000 / 1.000 |
| `dinov3-small` | transfer (0.622/0.735) | 1.000 / 1.000 | 1.000 / 0.571 | 0.981 / 0.588 | 1.000 / 0.775, 170 other-moment | 2 false pairs | 1.000 / 0.989 |
| `dinov3-small` | window-dev (0.709/0.837) | 1.000 / 1.000 | 1.000 / 0.705 | 0.984 / 0.720 | 1.000 / 0.879, 254 other-moment | 3 false pairs | 1.000 / 1.000 |
| `sscd-skew320` | transfer (0.923/1.091) | 1.000 / 1.000 | 1.000 / 0.520 | 1.000 / 0.548 | 1.000 / 0.891, 204 other-moment | 5 false pairs | 1.000 / 0.941 |
| `sscd-skew320` | window-dev (1.104/1.304) | 1.000 / 1.000 | 1.000 / 0.790 | 0.986 / 0.787 | 1.000 / 0.990, 384 other-moment | 11 false pairs | 1.000 / 0.941 |
| `sscd-pad320` | transfer (0.842/0.995) | 1.000 / 1.000 | 1.000 / 0.440 | 0.994 / 0.458 | 1.000 / 0.927, 176 other-moment | 7 false pairs | 1.000 / 0.907 |
| `sscd-pad320` | window-dev (1.098/1.298) | 1.000 / 1.000 | 1.000 / 0.819 | 0.986 / 0.804 | 1.000 / 1.000, 432 other-moment | 15 false pairs | 1.000 / 0.952 |
| `dinov2-small-squash` | transfer (0.784/0.927) | 1.000 / 1.000 | 1.000 / 0.800 | 0.986 / 0.787 | 0.781 / 0.864, 369 other-moment | 13 false pairs | 1.000 / 0.978 |
| `dinov2-small-squash` | window-dev (0.753/0.890) | 1.000 / 1.000 | 1.000 / 0.771 | 0.985 / 0.755 | 0.785 / 0.848, 353 other-moment | 12 false pairs | 1.000 / 0.978 |
| `dinov2-small-pad` | transfer (0.716/0.846) | 1.000 / 1.000 | 1.000 / 0.714 | 0.984 / 0.700 | 0.846 / 0.889, 296 other-moment | 18 false pairs | 1.000 / 0.941 |
| `dinov2-small-pad` | window-dev (0.710/0.839) | 1.000 / 1.000 | 1.000 / 0.709 | 0.984 / 0.695 | 0.844 / 0.874, 286 other-moment | 16 false pairs | 1.000 / 0.941 |
| `dinov3-small-squash` | transfer (0.807/0.954) | 1.000 / 1.000 | 1.000 / 0.834 | 0.979 / 0.818 | 0.767 / 0.937, 396 other-moment | 8 false pairs | 1.000 / 1.000 |
| `dinov3-small-squash` | window-dev (0.729/0.861) | 1.000 / 1.000 | 1.000 / 0.747 | 0.985 / 0.744 | 0.850 / 0.914, 320 other-moment | 7 false pairs | 1.000 / 0.967 |

Oracle in-window sweeps (link picked on the set itself): recall at pair precision ≥ 0.99 / best F1.

| Method | bursts-profile:test | photo-triage-tight:dev | photo-triage-tight:test | gopro-bursts:all |
|---|---|---|---|---|
| `apple-fp2-soft` | 1.000 / 1.000 | 0.651 / 0.917 | 0.150 / 0.896 | 0.866 / 0.928 |
| `apple-fp2-raw` | 0.838 / 0.912 | 0.651 / 0.921 | 0.810 / 0.910 | 0.341 / 0.699 |
| `ahash` | 1.000 / 1.000 | 0.005 / 0.668 | 0.000 / 0.640 | 0.932 / 0.965 |
| `phash` | 0.515 / 0.925 | 0.118 / 0.489 | 0.112 / 0.455 | 0.869 / 0.930 |
| `dhash` | 0.897 / 0.946 | 0.184 / 0.507 | 0.207 / 0.568 | 0.851 / 0.920 |
| `whash` | 1.000 / 1.000 | 0.195 / 0.638 | 0.000 / 0.635 | 0.949 / 0.974 |
| `pdq` | 0.544 / 0.757 | 0.077 / 0.372 | 0.144 / 0.392 | 0.646 / 0.785 |
| `imagededup-cnn` | 1.000 / 1.000 | 0.860 / 0.927 | 0.801 / 0.947 | 0.821 / 0.902 |
| `clip-b32-openai` | 1.000 / 1.000 | 0.478 / 0.930 | 0.179 / 0.918 | 0.669 / 0.843 |
| `mobileclip` | 1.000 / 1.000 | 0.679 / 0.963 | 0.640 / 0.929 | 0.722 / 0.905 |
| `siglip2-base` | 1.000 / 1.000 | 0.742 / 0.946 | 0.648 / 0.950 | 0.601 / 0.794 |
| `dinov2-small` | 1.000 / 1.000 | 0.777 / 0.928 | 0.585 / 0.916 | 0.596 / 0.861 |
| `dinov2-small-mean` | 1.000 / 1.000 | 0.695 / 0.930 | 0.726 / 0.931 | 0.735 / 0.897 |
| `dinov2-base` | 1.000 / 1.000 | 0.714 / 0.924 | 0.628 / 0.940 | 0.692 / 0.905 |
| `sscd` | 1.000 / 1.000 | 0.846 / 0.958 | 0.752 / 0.949 | 0.990 / 0.995 |
| `dinov3-small` | 1.000 / 1.000 | 0.690 / 0.925 | 0.357 / 0.957 | 0.848 / 0.918 |
| `sscd-skew320` | 1.000 / 1.000 | 0.794 / 0.952 | 0.744 / 0.949 | 0.990 / 0.995 |
| `sscd-pad320` | 1.000 / 1.000 | 0.832 / 0.943 | 0.741 / 0.957 | 1.000 / 1.000 |
| `dinov2-small-squash` | 1.000 / 1.000 | 0.786 / 0.924 | 0.447 / 0.942 | 0.601 / 0.844 |
| `dinov2-small-pad` | 1.000 / 1.000 | 0.723 / 0.932 | 0.375 / 0.931 | 0.634 / 0.894 |
| `dinov3-small-squash` | 1.000 / 1.000 | 0.750 / 0.944 | 0.427 / 0.948 | 0.806 / 0.892 |

Port vs tkscan (the Swift code): 94 of 94 runs give identical groups.

- **Hard in-window negatives.** photo-triage-tight packs real series 10-60 s apart, so unrelated scenes from one album meet inside the 60 s window. Its dev half sets `window-dev`; its test half is the held-out check.
- **Sharp real series** (photo-triage-tight test, pair precision about 0.985):
  - The app today scores 0.631 recall (balanced), or 0.660 with its link re-tuned.
  - SSCD scores 0.790, SSCD-pad320 0.804, DINOv2-small 0.798, SigLIP 2 0.821, DINOv3-small-squash 0.818 (at precision 0.979) and imagededup-cnn 0.867 (at precision 0.987).
  - The raw print scores 0.801 at precision 1.000.
  - Inside the window, then, several embeddings beat the softened print by 0.13-0.24 recall. SSCD is not the top one.
- **Blur.**
  - bursts-profile test: the raw print scores 0.485; the softened print and SSCD score 1.000.
  - Real blur: SSCD scores 1.000 / 0.990 and SSCD-pad320 1.000 / 1.000. The softened print scores 0.708 / 0.932 at balanced and 1.000 / 0.841 at strict. The raw print scores 0.771 / 0.543, and imagededup-cnn 0.842 / 0.861.
  - Only SSCD (any input form) is near the top on both blurry and sharp series inside the window.
- **The test-half run is sparser than a real library.** The window runs on test-half images only, so the dev-half series drop out of the timeline and test series sit farther apart than in the full set. The tkscan whole-set run below is the denser check.
- **Copies dated as their original** (as Photos' Duplicate does): SSCD scores 1.000 / 1.000, the softened print 1.000 / 0.844 at balanced.
- **Screenshots.** Only 1-18 false pairs per run fall inside a window, because the copies are hours to weeks after their originals.
- No CIs were computed for window runs.

## tkscan eval --features: other embeddings inside the app

The app's GroupingEval (pair P / R, series found, keeper accuracy), balanced timing, link/anchor as calibrated above. Its pair precision counts gopro other-moment pairs as wrong.

| Embedding | config | bursts-profile | photo-triage-tight | gopro-bursts | screenshots |
|---|---|---|---|---|---|
| `apple-fp2-soft` | transfer | 1.000 / 0.975, 29/29, 1.000 | 0.985 / 0.186, 82/280, 0.341 | 0.775 / 0.747, 61/66, 0.754 | 0.000 / 0.000, 0/100, 0.000 |
| `apple-fp2-soft` | window-dev | 1.000 / 1.000, 29/29, 1.000 | 0.989 / 0.654, 223/280, 0.377 | 0.336 / 0.949, 49/66, 0.612 | 0.000 / 0.000, 0/100, 0.000 |
| `apple-fp2-soft` | app balanced | 1.000 / 1.000, 29/29, 1.000 | 0.989 / 0.605, 209/280, 0.388 | 0.408 / 0.932, 53/66, 0.604 | 0.000 / 0.000, 0/100, 0.000 |
| `apple-fp2-raw` | transfer | 1.000 / 0.546, 17/29, 0.412 | 0.948 / 0.821, 238/280, 0.395 | 0.443 / 0.543, 52/66, 0.288 | 0.000 / 0.000, 0/100, 0.000 |
| `apple-fp2-raw` | window-dev | 1.000 / 0.479, 14/29, 0.214 | 0.987 / 0.664, 218/280, 0.399 | 0.488 / 0.402, 41/66, 0.341 | 0.000 / 0.000, 0/100, 0.000 |
| `apple-fp2-raw` | app balanced | 1.000 / 0.496, 16/29, 0.312 | 0.956 / 0.789, 233/280, 0.386 | 0.433 / 0.503, 48/66, 0.333 | 0.000 / 0.000, 0/100, 0.000 |
| `sscd` | transfer | 1.000 / 0.992, 28/29, 1.000 | 0.989 / 0.747, 227/280, 0.423 | 0.505 / 0.970, 66/66, 0.636 | 0.000 / 0.000, 0/100, 0.000 |
| `sscd` | window-dev | 1.000 / 1.000, 29/29, 1.000 | 0.967 / 0.819, 242/280, 0.421 | 0.485 / 0.990, 66/66, 0.591 | 0.000 / 0.000, 0/100, 0.000 |
| `sscd-pad320` | transfer | 1.000 / 0.992, 28/29, 1.000 | 0.997 / 0.440, 156/280, 0.404 | 0.676 / 0.927, 65/66, 0.785 | 0.000 / 0.000, 0/100, 0.000 |
| `sscd-pad320` | window-dev | 1.000 / 1.000, 29/29, 1.000 | 0.973 / 0.819, 241/280, 0.432 | 0.478 / 1.000, 66/66, 0.576 | 0.000 / 0.000, 0/100, 0.000 |
| `dinov2-small` | transfer | 1.000 / 0.992, 28/29, 1.000 | 0.969 / 0.699, 224/280, 0.420 | 0.523 / 0.720, 57/66, 0.632 | 0.000 / 0.000, 0/100, 0.000 |
| `dinov2-small` | window-dev | 1.000 / 1.000, 29/29, 1.000 | 0.949 / 0.788, 237/280, 0.414 | 0.456 / 0.823, 52/66, 0.635 | 0.000 / 0.000, 0/100, 0.000 |
| `dinov2-small-pad` | transfer | 1.000 / 1.000, 29/29, 1.000 | 0.969 / 0.714, 231/280, 0.407 | 0.494 / 0.889, 60/66, 0.667 | 0.000 / 0.000, 0/100, 0.000 |
| `dinov2-small-pad` | window-dev | 1.000 / 0.992, 28/29, 1.000 | 0.969 / 0.709, 227/280, 0.405 | 0.497 / 0.874, 60/66, 0.667 | 0.000 / 0.000, 0/100, 0.000 |
| `dinov3-small` | transfer | 1.000 / 1.000, 29/29, 1.000 | 0.971 / 0.571, 192/280, 0.396 | 0.644 / 0.775, 60/66, 0.700 | 0.000 / 0.000, 0/100, 0.000 |
| `dinov3-small` | window-dev | 1.000 / 1.000, 29/29, 1.000 | 0.977 / 0.705, 221/280, 0.394 | 0.578 / 0.879, 64/66, 0.703 | 0.000 / 0.000, 0/100, 0.000 |
| `dinov3-small-squash` | transfer | 1.000 / 1.000, 29/29, 1.000 | 0.961 / 0.834, 246/280, 0.398 | 0.422 / 0.937, 57/66, 0.579 | 0.000 / 0.000, 0/100, 0.000 |
| `dinov3-small-squash` | window-dev | 1.000 / 1.000, 29/29, 1.000 | 0.981 / 0.741, 233/280, 0.408 | 0.485 / 0.914, 60/66, 0.650 | 0.000 / 0.000, 0/100, 0.000 |
| `siglip2-base` | transfer | 1.000 / 1.000, 29/29, 1.000 | 0.936 / 0.819, 237/280, 0.380 | 0.386 / 0.745, 49/66, 0.571 | 0.000 / 0.000, 0/100, 0.000 |
| `siglip2-base` | window-dev | 1.000 / 0.975, 28/29, 0.964 | 0.960 / 0.738, 224/280, 0.384 | 0.442 / 0.710, 52/66, 0.577 | 0.000 / 0.000, 0/100, 0.000 |

- **Whole photo-triage-tight,** a dense timeline that includes the dev half:
  - SSCD at its carried-over link scores pair precision 0.989 and finds 227/280 series. The app today (balanced) scores 0.989 with 209/280.
  - SSCD's `window-dev` link finds 242/280 but drops precision to 0.967. The link set on the sparser dev half is too loose for the full timeline, so it has to be set on a denser real timeline.
  - DINOv3-small-squash finds 246/280 at 0.961, and SigLIP 2 237/280 at 0.936. Both are less precise.
- **Real blur.** tkscan does not know about unscored pairs, so its pair precision counts the other moment of the same clip as wrong. SSCD finds all 66 moments; the app today finds 53.
  - Keeper accuracy drops to 0.58-0.79 for most embeddings when the two moments of a clip are merged. One group then holds two sharp frames, and only one of them counts as best.
- **Synthetic bursts.** SSCD at `window-dev` finds 29/29 with keeper accuracy 1.000.
- **Screenshots.** 0/100 for every embedding: copies come hours later, and on a phone the app does not scan screenshots anyway.

## Softening: does it help on real blur?

AP; bursts-profile values are on its test half (from the fusion table).

| Signal | bursts-profile test (synthetic blur, in-sample) | gopro-bursts (real blur, held out) | photo-triage (sharp real series) | screenshots |
|---|---|---|---|---|
| `apple-fp2-soft` (today) | 1.000 | 0.930 | 0.792 | 0.541 |
| `apple-fp2-raw` | 0.936 | 0.631 | 0.923 | 0.834 |
| raw + sharpness gap (fitted on dev halves) | 0.949 | 0.647 | 0.919 | 0.831 |
| soft + raw (fitted on dev halves) | 0.992 | 0.752 | 0.932 | 0.834 |
| `sscd` (no softening) | 1.000 | 0.984 | 0.954 | 0.894 |

- **For the Vision print, softening is a trade.** It gains on held-out real blur (+0.299 [0.220, 0.372]). It loses on sharp real series (−0.131 [−0.185, −0.089]) and on screenshots.
- **A learned alternative does not replace it on real blur.** The raw distance plus the two photos' sharpness gap scores 0.647.
- **SSCD needs no softening.** It is trained for copy detection, and it matches or beats both prints on every column.
- **Wording fixed.** The comment in `VisionFrameAnalyzer.swift` and the README now say the thresholds were set on synthetic bursts made from real photos, and point here for the real-blur check.

## Fusion

Two distances; or the raw print's distance with the two photos' sharpness gap |s_a − s_b| and their product (a learned alternative to softening).

| Signal | bursts-profile (test) AP | copies (test) AP | photo-triage (all) AP | gopro-bursts (all) AP | screenshots (all) AP | bursts-profile (test) P / R at transfer thr | copies (test) P / R at transfer thr | photo-triage (all) P / R at transfer thr | gopro-bursts (all) P / R at transfer thr | screenshots (all) P / R at transfer thr |
|---|---|---|---|---|---|---|---|---|---|---|
| `apple-fp2-soft` | 1.000 | 0.893 | 0.792 | 0.930 | 0.541 | 1.000 / 0.956 | 1.000 / 0.830 | 0.993 / 0.193 | 1.000 / 0.768 | 0.144 / 0.580 |
| `apple-fp2-raw` | 0.936 | 0.963 | 0.923 | 0.631 | 0.834 | 1.000 / 0.456 | 0.976 / 0.889 | 0.941 / 0.814 | 0.702 / 0.530 | 0.431 / 0.970 |
| `phash` | 0.907 | 0.645 | 0.129 | 0.807 | 0.614 | 1.000 / 0.559 | 0.988 / 0.615 | 0.810 / 0.096 | 0.996 / 0.631 | 0.210 / 0.740 |
| `dinov2-small` | 1.000 | 1.000 | 0.910 | 0.877 | 0.340 | 1.000 / 1.000 | 1.000 / 1.000 | 0.950 / 0.689 | 0.903 / 0.727 | 0.012 / 1.000 |
| `dinov2-base` | 1.000 | 1.000 | 0.909 | 0.909 | 0.375 | 1.000 / 1.000 | 1.000 / 0.996 | 0.946 / 0.616 | 0.977 / 0.657 | 0.034 / 1.000 |
| `sscd` | 1.000 | 1.000 | 0.954 | 0.984 | 0.894 | 1.000 / 1.000 | 1.000 / 1.000 | 0.986 / 0.717 | 0.902 / 0.955 | 0.055 / 1.000 |
| `sscd-pad320` | 1.000 | 0.990 | 0.946 | 0.989 | 0.871 | 1.000 / 0.971 | 1.000 / 0.907 | 0.997 / 0.440 | 0.960 / 0.904 | 0.267 / 1.000 |
| `dinov2-small-pad` | 1.000 | 0.998 | 0.921 | 0.884 | 0.541 | 1.000 / 1.000 | 1.000 / 0.937 | 0.947 / 0.726 | 0.767 / 0.838 | 0.002 / 1.000 |
| **apple-fp2-soft + sscd** | 1.000 | 1.000 | 0.948 | 0.984 | 0.902 | 1.000 / 1.000 | 0.996 / 1.000 | 0.985 / 0.743 | 0.892 / 0.955 | 0.044 / 1.000 |
| **apple-fp2-soft + dinov2-small** | 1.000 | 1.000 | 0.920 | 0.898 | 0.725 | 1.000 / 1.000 | 1.000 / 1.000 | 0.976 / 0.636 | 0.929 / 0.725 | 0.016 / 1.000 |
| **apple-fp2-soft + dinov2-base** | 1.000 | 1.000 | 0.922 | 0.922 | 0.748 | 1.000 / 1.000 | 1.000 / 1.000 | 0.943 / 0.702 | 0.947 / 0.770 | 0.023 / 1.000 |
| **apple-fp2-soft + apple-fp2-raw** | 0.992 | 0.955 | 0.932 | 0.752 | 0.834 | 1.000 / 0.662 | 0.983 / 0.867 | 0.958 / 0.810 | 0.689 / 0.689 | 0.199 / 1.000 |
| **apple-fp2-soft + phash** | 1.000 | 0.926 | 0.704 | 0.948 | 0.645 | 1.000 / 1.000 | 0.982 / 0.815 | 0.988 / 0.335 | 0.941 / 0.894 | 0.035 / 0.910 |
| **sscd + dinov2-small** | 1.000 | 1.000 | 0.970 | 0.975 | 0.910 | 1.000 / 1.000 | 1.000 / 1.000 | 0.984 / 0.709 | 0.913 / 0.932 | 0.045 / 1.000 |
| **sscd-pad320 + dinov2-small-pad** | 1.000 | 0.999 | 0.963 | 0.962 | 0.820 | 1.000 / 1.000 | 0.996 / 0.959 | 0.957 / 0.850 | 0.678 / 0.972 | 0.002 / 1.000 |
| **apple-fp2-raw + sharpness gap** | 0.949 | 0.960 | 0.919 | 0.647 | 0.831 | 0.971 / 0.500 | 0.979 / 0.874 | 0.941 / 0.803 | 0.731 / 0.523 | 0.487 / 0.970 |

- **SSCD + DINOv2-small** has the highest real-series AP here (0.970). It also scores 0.975 on real blur and 0.910 on screenshots, at about 186 MB fp32.
- **With fixed square inputs,** SSCD-pad320 + DINOv2-small-pad scores 0.963 / 0.962 / 0.820.
- **The softened print adds nothing next to SSCD.**
- **Softened + raw print,** both free in iOS: real series 0.932, but real blur only 0.752, below the softened print alone.
- No CIs were computed for the fusions.

## App pipeline (tkscan eval: time window, SeriesBuilder, ShotScorer)

Missed pairs: never analyzed (no other photo within maxGap) / farther apart than maxSpan / within the window but not grouped. Scored P leaves out unscored pairs (count in parentheses: gopro other-moment pairs grouped). Keeper accuracy (tkscan) counts every found series, with the first file as 'best' where none is known; the next column counts only series whose best is known. Port = series_port.py gives the same groups.

| Dataset | sensitivity | analyzed | pair P | pair R | scored P (unscored) | series found | keeper acc. (tkscan) | keeper acc. (known best) | missed: not analyzed / span / visual | port |
|---|---|---|---|---|---|---|---|---|---|---|
| bursts-profile | strict | 105/106 | 1.000 | 0.975 | 1.000 (0) | 29/29 | 1.000 | 1.000 (n=29) | 0 / 0 / 3 | yes |
| bursts-profile | balanced | 106/106 | 1.000 | 1.000 | 1.000 (0) | 29/29 | 1.000 | 1.000 (n=29) | 0 / 0 / 0 | yes |
| photo-triage | strict | 731/731 | 1.000 | 0.269 | 1.000 (0) | 107/280 | 0.449 | 0.457 (n=70) | 0 / 0 / 520 | yes |
| photo-triage | balanced | 731/731 | 1.000 | 0.606 | 1.000 (0) | 210/280 | 0.443 | 0.472 (n=142) | 0 / 0 / 280 | yes |
| copies | strict | 6/601 | 1.000 | 0.000 | 1.000 (0) | 0/150 | 0.000 | n/a (n=0) | 501 / 0 / 0 | yes |
| copies | balanced | 8/601 | 1.000 | 0.000 | 1.000 (0) | 0/150 | 0.000 | n/a (n=0) | 501 / 0 / 0 | yes |
| copies | loose | 10/601 | 1.000 | 0.000 | 1.000 (0) | 0/150 | 0.000 | n/a (n=0) | 501 / 0 / 0 | yes |
| gopro-bursts | strict | 264/264 | 0.742 | 0.841 | 1.000 (116) | 65/66 | 0.800 | 0.800 (n=65) | 0 / 0 / 63 | yes |
| gopro-bursts | balanced | 264/264 | 0.408 | 0.932 | 0.708 (383) | 53/66 | 0.604 | 0.604 (n=53) | 0 / 0 / 27 | yes |
| screenshots | strict | 247/416 | 0.000 | 0.000 | 0.000 (0) | 0/100 | 0.000 | n/a (n=0) | 100 / 0 / 0 | yes |
| screenshots | balanced | 316/416 | 0.000 | 0.000 | 0.000 (0) | 0/100 | 0.000 | n/a (n=0) | 100 / 0 / 0 | yes |
| screenshots | loose | 316/416 | 0.000 | 0.000 | 0.000 (0) | 0/100 | 0.000 | n/a (n=0) | 100 / 0 / 0 | yes |
| photo-triage-tight | strict | 731/731 | 1.000 | 0.269 | 1.000 (0) | 107/280 | 0.346 | n/a (n=0) | 0 / 0 / 520 | yes |
| photo-triage-tight | balanced | 731/731 | 0.989 | 0.605 | 0.989 (0) | 209/280 | 0.388 | n/a (n=0) | 0 / 0 / 281 | yes |

- **bursts-profile** (in-sample). Balanced finds all 29 bursts at pair precision and recall 1.000 and picks 29/29 keepers.
- **photo-triage.**
  - Its series are 2-8 h apart, so the window separates them by construction.
  - On photo-triage-tight, where unrelated series meet in the window, pipeline precision is 0.989 at balanced, with 209/280 series found.
  - Recall comes from the signal: every missed pair was inside the window and simply not linked.
- **copies.**
  - The window never compares a photo with a copy made hours or days later: 0 of 501 pairs are grouped, even at loose.
  - 591 to 595 of the 601 photos are never analyzed.
- **gopro-bursts.**
  - Strict finds 65/66 moments, with precision 1.000 on scored pairs.
  - Balanced links more, including different clips of one recording (scored precision 0.708). It finds 53/66 moments.
- **screenshots.** 0/100: the copies are far apart in time.

## Best shot

### Best shot: bursts-profile

Pairwise: known best frame vs each other frame of its group, n = 63 pairs in 29 groups. Top-1: n = 29 groups. 95% CIs resample groups.

| Ranker | pairwise accuracy [95% CI] | strong pairs (ratio ≥ .8 or ≤ .2) | top-1 accuracy [95% CI] | app − this, pairwise [95% CI] | app − this, top-1 [95% CI] |
|---|---|---|---|---|---|
| random | 0.500 | — | 0.357 | n/a | — |
| app (ShotScorer) | 1.000 [1.000, 1.000] | — | 1.000 [1.000, 1.000] | n/a | — |
| sharpness only | 1.000 [1.000, 1.000] | — | 1.000 [1.000, 1.000] | +0.000 to +0.000 | +0.000 to +0.000 |
| Vision aesthetics only | 0.778 [0.646, 0.892] | — | 0.621 [0.448, 0.793] | +0.108 to +0.354 | +0.207 to +0.552 |
| first in capture order | 0.619 [0.465, 0.776] | — | 0.483 [0.310, 0.655] | +0.224 to +0.535 | +0.345 to +0.690 |
| last in capture order | 0.381 [0.224, 0.535] | — | 0.241 [0.103, 0.414] | +0.465 to +0.776 | +0.586 to +0.897 |
| LAION aesthetic (CLIP ViT-L/14) | 1.000 [1.000, 1.000] | — | 1.000 [1.000, 1.000] | +0.000 to +0.000 | +0.000 to +0.000 |

### Best shot: photo-triage

Pairwise: human preference pairs (preference ratio >= 0.7 or <= 0.3), n = 292 pairs in 136 groups. Top-1: n = 195 groups. 95% CIs resample groups.

| Ranker | pairwise accuracy [95% CI] | strong pairs (ratio ≥ .8 or ≤ .2) | top-1 accuracy [95% CI] | app − this, pairwise [95% CI] | app − this, top-1 [95% CI] |
|---|---|---|---|---|---|
| random | 0.500 | — | 0.423 | n/a | — |
| app (ShotScorer) | 0.733 [0.665, 0.790] | 0.773 (n=194) | 0.513 [0.441, 0.579] | n/a | — |
| sharpness only | 0.606 [0.534, 0.670] | 0.634 (n=194) | 0.431 [0.359, 0.497] | +0.065 to +0.187 | +0.015 to +0.149 |
| Vision aesthetics only | 0.668 [0.589, 0.736] | 0.680 (n=194) | 0.500 [0.433, 0.569] | -0.007 to +0.136 | -0.069 to +0.090 |
| first in capture order | 0.493 [0.429, 0.555] | 0.531 (n=194) | 0.421 [0.354, 0.492] | +0.153 to +0.322 | +0.000 to +0.185 |
| last in capture order | 0.507 [0.445, 0.571] | 0.469 (n=194) | 0.400 [0.333, 0.472] | +0.126 to +0.316 | +0.021 to +0.210 |
| LAION aesthetic (CLIP ViT-L/14) | 0.695 [0.623, 0.766] | 0.742 (n=194) | 0.590 [0.523, 0.662] | -0.033 to +0.105 | -0.164 to +0.010 |

### Best shot: copies

Pairwise: known best frame vs each other frame of its group, n = 301 pairs in 150 groups. Top-1: n = 150 groups. 95% CIs resample groups.

| Ranker | pairwise accuracy [95% CI] | strong pairs (ratio ≥ .8 or ≤ .2) | top-1 accuracy [95% CI] | app − this, pairwise [95% CI] | app − this, top-1 [95% CI] |
|---|---|---|---|---|---|
| random | 0.500 | — | 0.359 | n/a | — |
| app (ShotScorer) | 0.635 [0.575, 0.692] | — | 0.473 [0.393, 0.553] | n/a | — |
| sharpness only | 0.488 [0.434, 0.549] | — | 0.287 [0.220, 0.360] | +0.083 to +0.210 | +0.106 to +0.267 |
| Vision aesthetics only | 0.583 [0.522, 0.640] | — | 0.393 [0.313, 0.467] | -0.005 to +0.105 | +0.007 to +0.160 |
| first in capture order | 1.000 [1.000, 1.000] | — | 1.000 [1.000, 1.000] | -0.425 to -0.308 | -0.607 to -0.447 |
| last in capture order | 0.000 [0.000, 0.000] | — | 0.000 [0.000, 0.000] | +0.575 to +0.692 | +0.393 to +0.553 |
| LAION aesthetic (CLIP ViT-L/14) | 0.664 [0.613, 0.716] | — | 0.460 [0.380, 0.533] | -0.106 to +0.052 | -0.087 to +0.113 |

### Best shot: gopro-bursts

Pairwise: known best frame vs each other frame of its group, n = 198 pairs in 66 groups. Top-1: n = 66 groups. 95% CIs resample groups.

| Ranker | pairwise accuracy [95% CI] | strong pairs (ratio ≥ .8 or ≤ .2) | top-1 accuracy [95% CI] | app − this, pairwise [95% CI] | app − this, top-1 [95% CI] |
|---|---|---|---|---|---|
| random | 0.500 | — | 0.250 | n/a | — |
| app (ShotScorer) | 0.995 [0.985, 1.000] | — | 0.985 [0.955, 1.000] | n/a | — |
| sharpness only | 1.000 [1.000, 1.000] | — | 1.000 [1.000, 1.000] | -0.015 to +0.000 | -0.045 to +0.000 |
| Vision aesthetics only | 0.975 [0.954, 0.995] | — | 0.924 [0.864, 0.985] | +0.005 to +0.040 | +0.015 to +0.121 |
| first in capture order | 0.510 [0.409, 0.606] | — | 0.288 [0.182, 0.394] | +0.389 to +0.581 | +0.591 to +0.803 |
| last in capture order | 0.490 [0.394, 0.591] | — | 0.258 [0.152, 0.364] | +0.404 to +0.601 | +0.621 to +0.833 |
| LAION aesthetic (CLIP ViT-L/14) | 0.879 [0.808, 0.939] | — | 0.788 [0.682, 0.879] | +0.056 to +0.187 | +0.091 to +0.303 |

### Best shot: screenshots

Pairwise: known best frame vs each other frame of its group, n = 100 pairs in 100 groups. Top-1: n = 100 groups. 95% CIs resample groups.

| Ranker | pairwise accuracy [95% CI] | strong pairs (ratio ≥ .8 or ≤ .2) | top-1 accuracy [95% CI] | app − this, pairwise [95% CI] | app − this, top-1 [95% CI] |
|---|---|---|---|---|---|
| random | 0.500 | — | 0.500 | n/a | — |
| app (ShotScorer) | 0.660 [0.570, 0.750] | — | 0.660 [0.570, 0.750] | n/a | — |
| sharpness only | 0.710 [0.620, 0.800] | — | 0.710 [0.620, 0.800] | -0.110 to +0.000 | -0.110 to +0.010 |
| Vision aesthetics only | 0.485 [0.395, 0.565] | — | 0.485 [0.410, 0.565] | +0.070 to +0.285 | +0.065 to +0.280 |
| first in capture order | 1.000 [1.000, 1.000] | — | 1.000 [1.000, 1.000] | -0.430 to -0.250 | -0.430 to -0.250 |
| last in capture order | 0.000 [0.000, 0.000] | — | 0.000 [0.000, 0.000] | +0.570 to +0.750 | +0.570 to +0.750 |
| LAION aesthetic (CLIP ViT-L/14) | 0.680 [0.595, 0.765] | — | 0.680 [0.585, 0.775] | -0.145 to +0.100 | -0.150 to +0.105 |

- **bursts-profile** (synthetic). The best frame is the only unblurred one, so sharpness alone, ShotScorer and LAION are all perfect. This checks the plumbing more than the ranking.
- **photo-triage** (crowd preferences).
  - Pairwise, ShotScorer scores 0.733 [0.665, 0.790], and 0.773 on the 194 strong pairs. It beats sharpness alone (+0.065 to +0.187) and capture order. It ties LAION (−0.033 to +0.105).
  - **For the single top photo it is only modestly above chance:** top-1 0.513 [0.441, 0.579], where random gets 0.423 and LAION 0.590 [0.523, 0.662]. App − LAION is −0.164 to +0.010, so LAION is probably better at the top pick, though not significantly.
- **gopro-bursts** (real blur, best = the sharp frame). ShotScorer scores 0.995 pairwise and 0.985 top-1. Sharpness alone is perfect; LAION scores 0.879 / 0.788.
- **copies** (best = the original).
  - ShotScorer scores 0.635 pairwise and 0.473 top-1, where random gets 0.359. LAION is no better.
  - "First in capture order" is perfect only by construction, since copies are dated after their originals.
  - The copy keeper should come from metadata: not a screenshot, largest pixel size, camera EXIF, oldest date, favourite or edited. None of that is measured here.
- **screenshots.** ShotScorer scores 0.660, sharpness 0.710, and capture order 1.000 by construction. The app does not scan screenshots.
- **The LAION baseline.**
  - Model: improved-aesthetic-predictor `sac+logos+ava1-l14-linearMSE`, whose MLP code and weights are Apache-2.0.
  - It runs on OpenAI CLIP ViT-L/14 (MIT), through open_clip.
  - Cost: 1,220 MB fp32, 42 ms/img on M3 Max MPS. Code: `bench/aesthetic.py`.

## Speed, size, licenses

ms/img per dataset (bursts-profile / photo-triage / copies / gopro-bursts / screenshots), M3 Max, batch 1, warm. Not iPhone numbers.

| Method | metric | dim | ms/img | device | model MB (fp32) | code license | weights license |
|---|---|---|---|---|---|---|---|
| `apple-fp2-soft` | l2 | 768 | 17.1 / 21.0 / 21.2 / 25.2 / 21.0 | vision | 0 (in iOS) | Apache-2.0 (Tidykeep); Vision is an Apple OS framework | Apple OS component (ships with iOS/macOS, no separate weights) |
| `apple-fp2-raw` | l2 | 768 | 16.8 / 20.0 / 19.4 / 17.0 / 18.1 | vision | 0 (in iOS) | Apache-2.0 (Tidykeep); Vision is an Apple OS framework | Apple OS component (ships with iOS/macOS, no separate weights) |
| `ahash` | hamming | 64 | 0.2 / 0.4 / 0.4 / 0.4 / 1.0 | cpu | 0.0 | BSD-2-Clause (imagehash) | none (no learned weights) |
| `phash` | hamming | 64 | 0.3 / 0.5 / 0.5 / 0.6 / 1.4 | cpu | 0.0 | BSD-2-Clause (imagehash) | none (no learned weights) |
| `dhash` | hamming | 64 | 0.2 / 0.4 / 0.3 / 0.5 / 1.0 | cpu | 0.0 | BSD-2-Clause (imagehash) | none (no learned weights) |
| `whash` | hamming | 64 | 2.3 / 8.3 / 8.5 / 9.2 / 35.9 | cpu | 0.0 | BSD-2-Clause (imagehash) | none (no learned weights) |
| `pdq` | hamming | 256 | 1.7 / 5.4 / 5.3 / 6.3 / 9.8 | cpu | 0.0 | BSD-3-Clause (PDQ reference, facebook/ThreatExchange); MIT (pdqhash Python bindings) | none (no learned weights) |
| `imagededup-cnn` | cosine | 576 | 6.9 / 7.8 / 7.6 / 9.2 / 14.0 | mps | 3.8 | Apache-2.0 (imagededup recipe); BSD-3-Clause (torchvision) | BSD-3-Clause (torchvision IMAGENET1K_V1); trained on ImageNet-1k, whose terms may apply |
| `clip-b32-openai` | cosine | 512 | 12.2 / 11.7 / 11.2 / 13.5 / 19.6 | mps | 351.4 | MIT (open_clip) | MIT (OpenAI CLIP release; HF mirror timm/vit_base_patch32_clip_224.openai is tagged apache-2.0) |
| `mobileclip` | cosine | 512 | 10.6 / 12.8 / 12.7 / 13.9 / 17.3 | mps | 45.5 | MIT (open_clip); MIT (apple/ml-mobileclip code) | Apple Machine Learning Research Model License (apple-amlr, LICENSE_MODELS): scientific research only, not usable in a shipping app |
| `siglip2-base` | cosine | 768 | 12.9 / 13.3 / 13.8 / 13.6 / 14.9 | mps | 371.5 | Apache-2.0 (transformers) | Apache-2.0 |
| `dinov2-small` | cosine | 384 | 9.2 / 11.8 / 12.3 / 12.9 / 12.5 | mps | 88.2 | Apache-2.0 (transformers) | Apache-2.0 |
| `dinov2-small-mean` | cosine | 384 | 9.4 / 9.5 / 10.4 / 12.2 / 11.2 | mps | 88.2 | Apache-2.0 (transformers) | Apache-2.0 |
| `dinov2-base` | cosine | 768 | 16.1 / 17.0 / 17.0 / 17.6 / 18.2 | mps | 346.3 | Apache-2.0 (transformers) | Apache-2.0 |
| `sscd` | cosine | 512 | 12.8 / 15.6 / 15.0 / 16.5 / 20.2 | mps | 98.4 | MIT (facebookresearch/sscd-copy-detection, relicensed from CC-BY-NC to MIT on 2022-07-14) | MIT (weights published with the MIT-licensed repo; trained on DISC21 images) |
| `dinov3-small` | cosine | 384 | 12.3 / 11.5 / 12.2 / 13.9 / 22.3 | mps | 86.3 | Apache-2.0 (timm) | DINOv3 License (Meta custom license; facebook/ repo is gated, timm/vit_small_patch16_dinov3.lvd1689m mirror is not; read the license before shipping) |
| `sscd-skew320` | cosine | 512 | 14.2 / 15.0 / 15.6 / 16.5 / 21.3 | mps | 98.4 | MIT (facebookresearch/sscd-copy-detection, relicensed from CC-BY-NC to MIT on 2022-07-14) | MIT (weights published with the MIT-licensed repo; trained on DISC21 images) |
| `sscd-pad320` | cosine | 512 | 14.2 / 15.2 / 15.7 / 16.6 / 21.7 | mps | 98.4 | MIT (facebookresearch/sscd-copy-detection, relicensed from CC-BY-NC to MIT on 2022-07-14) | MIT (weights published with the MIT-licensed repo; trained on DISC21 images) |
| `dinov2-small-squash` | cosine | 384 | 10.7 / 11.1 / 12.1 / 12.5 / 19.5 | mps | 88.2 | Apache-2.0 (transformers) | Apache-2.0 |
| `dinov2-small-pad` | cosine | 384 | 10.4 / 11.3 / 11.9 / 12.9 / 17.1 | mps | 88.2 | Apache-2.0 (transformers) | Apache-2.0 |
| `dinov3-small-squash` | cosine | 384 | 11.1 / 11.8 / 12.3 / 13.2 / 18.3 | mps | 86.3 | Apache-2.0 (timm) | DINOv3 License (Meta custom license; facebook/ repo is gated, timm/vit_small_patch16_dinov3.lvd1689m mirror is not; read the license before shipping) |

- **MobileCLIP** weights are for research only, so they can't ship.
- **DINOv3** uses a custom Meta license that needs reading before shipping.
- **SSCD** is MIT. Its notice would go in the app's third-party notices.
- **DINOv2 and SigLIP 2** are Apache-2.0.
- **imagededup-cnn** uses ImageNet-trained torchvision weights, so ImageNet's terms may apply.
- **Fixed-square variants** use the same weights and license as their base models.

## Integrity checks

- AP and ROC-AUC match scikit-learn to 2.2e-16 (15 dataset x method checks).
- Duplicates are closer than unrelated pairs on average for every dataset x method.
- Embedding ids match truth.json order; distance matrices are symmetric; hashes are unpacked 0/1 bits.
- Cosine methods are unit-normalized (max norm error 1.3e-07); the l2 (Vision) prints have norms 0.997-1.005, so L2 order is cosine order to within that spread.
- 2118 image files hashed: 0 byte-identical sets within datasets, 0 across datasets.
- Cross-dataset pairs within `sscd`'s transfer threshold: 20 (closest photo-triage/pt004844-02.jpg vs copies/cp75009.jpg at 0.321). Pairs are only formed within a dataset, so these do not enter any metric.
- Cross-dataset pairs within `dinov2-base`'s transfer threshold: 60 (closest photo-triage/pt004844-02.jpg vs copies/cp75009.jpg at 0.047). Pairs are only formed within a dataset, so these do not enter any metric.
- Cross-dataset pairs within `apple-fp2-soft`'s transfer threshold: 0 (closest photo-triage/pt004818-02.jpg vs copies/cp81178.jpg at 0.442). Pairs are only formed within a dataset, so these do not enter any metric.
- Thresholds come only from the dev halves (transfer, fusion, the in-window link, the screen threshold). Columns marked oracle are picked on the set they are reported on.

- **Port check.** `series_port.py` and tkscan give identical groups in 94 of 94 runs.
- **Recomputed outside `evaluate.py`** from the saved embeddings with scikit-learn:
  - gopro-bursts AP for the softened print, raw print and SSCD: 0.930 / 0.631 / 0.984, with the 528 unscored pairs left out;
  - screenshots AP for SSCD and SigLIP 2: 0.894 / 0.912;
  - SSCD's screenshot false calls at its threshold of 0.56428: 1,705, precision 0.055.
  - All match.
- **Visual checks.** The closest cross-dataset pair (photo-triage pt004844 against copies cp75009, a distractor from train series 004788) is the same group photo from the same album with a different person in the middle: a similar shot, not a copy. The hardest photo-triage negatives are different series from the same trips.

## Discussion

### Ranking by dataset

The statistical top group by AP lists the members whose gap to the leader has a 95% CI that includes 0.

- **bursts-profile** (synthetic, in-sample for the softened print): 14 methods tie at 0.999-1.000, including the softened print, SSCD, DINOv2/v3, SigLIP 2, MobileCLIP and imagededup-cnn. It ranks almost nothing.
- **photo-triage** (sharp real series): DINOv3-small-squash 0.960, SSCD 0.954, SSCD-skew320 0.953, SSCD-pad320 0.946. Next come DINOv3-small 0.949 and SigLIP 2 0.941. The softened print is 16th (0.792).
- **copies** (synthetic edits): DINOv3-small, SSCD, DINOv2-small, DINOv2-base, DINOv2-small-mean, all at 1.000.
- **gopro-bursts** (real blur): SSCD-pad320 0.989, SSCD-skew320 0.987, SSCD 0.984. Next come DINOv3-small 0.951 and the softened print 0.930.
- **screenshots** (real Android screens): SigLIP 2 0.912, SSCD-skew320 0.908, SSCD 0.894, SSCD-pad320 0.871, DINOv3-small-squash 0.863. None of them is usable at one threshold.
- **Inside the window** (photo-triage-tight test, pair precision about 0.985), by recall: imagededup-cnn 0.867, SigLIP 2 0.821, DINOv3-small-squash 0.818, SSCD-pad320 0.804, raw print 0.801 (at precision 1.000), DINOv2-small 0.798, SSCD 0.790, softened print 0.660. These have no CIs.

### Where Tidykeep's signal wins

- **Blur.** It is perfect on synthetic bursts (in-sample). On held-out real camera shake it scores 0.930 against 0.631 for the raw print. Inside the window at strict it scores 1.000 / 0.841 on real blur.
- **Precision.** On unseen real series it keeps 0.993 precision at the carried-over threshold, about 4 false calls per million unrelated pairs.
- **Cost.** 0 MB to ship. On M3 Max the whole analysis, including the quality signals, takes 17-25 ms per photo.
- **Ranking.** ShotScorer ties a 1.2 GB aesthetic model on crowd preference pairs, and picks the sharp frame on real camera shake 98.5% of the time.

### Where it loses

- **Sharp real series.** It scores AP 0.792, last among the learned signals. On recomposed shots it scores 0.479. Inside the app it finds 209 of 280 series on photo-triage-tight.
- **Copies across time.** The window is blind to them: 0/501 found. Even without the window, the softened print misses every screenshot copy and 26% of copy-vs-copy pairs.
- **Screenshots.** It scores 0.541, though the app does not scan them.
- **Single best frame on real series.** It is probably behind LAION (0.513 against 0.590), though not significantly.

### Best on-device combination

**(a) Bursts and series: keep the window and ShotScorer, and change the link signal.**

- **SSCD as the link signal.** Measured in the app's own code at the carried-over link (Euclidean 1.062 on int8 vectors, which is cosine distance 0.564):
  - real series: 227/280 at pair precision 0.989, against 209/280 at 0.989 today;
  - real blur: 66/66 moments, against 53/66;
  - synthetic bursts: 28/29, against 29/29 (in-sample).
- **The link needs care.** A looser link from the sparser dev half finds 242/280 but drops precision to 0.967. The link should be calibrated on a dense real timeline, ideally real phone bursts.
- **With a fixed 320x320 input,** SSCD-pad320 inside the window scores 1.000 / 1.000 on real blur and 0.986 / 0.804 on the photo-triage-tight test half. Its carried-over link is too strict in the app (0.997 / 0.440, 156/280), so it needs its own link.
- **With Apache-2.0 weights,** DINOv2-small is as good on sharp series inside the window (0.986 / 0.798) but weaker on real blur (0.819 / 0.823).
- **With no download,** keep the softened print. Fusing it with the raw print helps sharp series (0.932) but hurts real blur (0.752). A rule that links when either print is close was not measured.

**(b) Copies across time: a separate library-wide pass with no time window.**

- **Step 1:** a byte hash for exact copies.
- **Step 2:** SSCD embeddings at the carried-over threshold, with complete linkage (not single linkage). On the whole copies set this gives 0.998 / 1.000, 150/150 groups, across all eight edits and copy-vs-copy pairs.
  - DINOv2-small (Apache-2.0) scores 0.992 / 1.000.
  - DINOv3-small scores 1.000 / 1.000 under a custom license.
  - Fixed-square SSCD-skew320 scores 0.998 / 0.924, finding only 65% of photo-vs-screenshot copies.
- **Keepers by metadata,** not ShotScorer.
- **Hashes are not enough.** pHash finds 63% of copy pairs and no mirrored ones.
- **Label similar shots separately in the UI.** The same threshold also links 72% of same-series pairs on real series, so this pass will surface similar shots as well as copies.
- Embeddings are computed once per photo and cached. The pairwise step is a matrix product, and its cost on an iPhone has not been measured.

**(c) Screenshots.**

- **Keep them out of photo dedup,** as the app does today. If photo-vs-screenshot copies should be found, include screenshots in pass (b) only as candidates for a photo, never as keepers. Aspect-kept SSCD finds all 17 such test pairs; the fixed-square forms find 65% (squashed) and 41% (padded).
- **For a screenshot cleaner** (screenshot vs screenshot), no tested signal works at one threshold. The screen-shaped threshold gives precision 1.000 at recall about 0.5. For SSCD those are the resaved and HEIC copies; cropped and re-screenshotted copies are missed. The rest needs the user to confirm.

**Overall.** SSCD (MIT, 98 MB fp32) is the one added model that is never significantly behind on any dataset here.

- It helps inside the window: +18 real series at the same precision, and every real-blur moment.
- As a copy pass it finds every edited copy.
- It does not solve screenshot-vs-screenshot duplicates.
- Its measured form, aspect-kept input, needs a flexible-shape Core ML model, which has not been built.

### Can one app clear photos, files and other data on an iPhone, entirely on-device?

**Photos and videos: yes.**

- PhotoKit gives the app the whole library, or only the photos the user picks. It marks screenshots (`PHAssetMediaSubtype.photoScreenshot`), so they can be handled separately.
- Vision runs on the device. SSCD or DINOv2 would run on the device through Core ML after conversion; neither the conversion nor iPhone speed was measured.
- Deleting always goes through an iOS confirmation the app cannot skip, and deleted items stay in Recently Deleted for 30 days. The user keeps the final say.
- Copies that messaging apps save into Photos are exactly what pass (b) finds.

**Files: only what the user hands over.** The app can scan folders the user picks in the Files picker (On My iPhone, iCloud Drive, other providers) and its own storage. It cannot crawl the phone.

**Contacts and calendars: yes, with permission.** Duplicate contacts are a natural addition.

**Other apps' data, caches, message attachments and "System Data": no.** The iOS sandbox blocks access to them, and no public API reports other apps' storage.

**No server.** Everything above can run without one. The app needs no account and no analytics, and can carry the App Store label "Data Not Collected". Nothing in this pipeline needs the network once the model ships inside the app.

## Caveats

- **Timings and sizes.** Speeds are M3 Max (MPS or Vision) numbers at batch 1, not iPhone numbers. No Core ML conversion or iPhone profiling was done. Sizes are fp32; fp16 would roughly halve them, but that was not measured.
- **Dates.** Capture times are synthesized in every dataset, so every time-window and pipeline result depends on that date model.
- **bursts-profile** is synthetic and is the app's calibration set, so the app's numbers on it are in-sample. 14 methods tie at the top.
- **Test halves** of bursts-profile and copies are held out, but they come from the same generator as the dev halves that set the thresholds. Full-set and cross-split numbers are given next to them.
- **photo-triage** truth is "same series", not "same photo", so its recall is series recall. A few negatives are same-trip near-duplicates.
- **copies** are synthetic edits, with only 15-25 test-half pairs per transform (17 screenshots). Clopper-Pearson bounds, not bootstrap CIs, are given per transform.
- **gopro-bursts** comes from a video camera. Its blur is an average of 7-13 frames at 240 fps, its times are synthetic, and the 528 pairs between two moments of one clip are unscored.
- **screenshots** are Android screens from Rico (apps from about 2017), 1-3 per app, each with at most one copy. The iPhone screenshot copies are simulated.
- **Cross-dataset similar shots.** The copies originals come from other series of the same personal albums as photo-triage. Pairs are only formed within a dataset, so this does not affect any metric.
- **Transfer and fusion** were fitted on small synthetic dev halves (51 + 231 duplicate pairs). A threshold fitted on real data could differ.
- **Missing CIs.** Window runs, tkscan runs and fusions have none.
- **Best shot.** The 292 preference pairs come from 136 series, and top-1 from 195 series. Crowd agreement on a single best frame is limited, so top-1 stays low for every ranker.

## Known limitations

A review asked for the following. Each item was not done, or only partly done, for the reason given.

- **Copies were not grown to ≥ 100 pairs per transform.**
  - Why: growing the copies set changes the dev half that sets every carried-over threshold, so every section would need a rebuild and a rerun. That is left for a later pass.
  - Shown instead: Clopper-Pearson lower bounds (a recall of 1.00 on 15-25 pairs is only ≥ 0.78-0.86), threshold-free ROC-AUC per transform on the whole set, and full-set and cross-split precision.
- **No real-phone burst set.**
  - Why: no small public set exists with a license that allows this, and the user's own library is off limits.
  - Shown instead: gopro-bursts, the nearest held-out real blur, but from a video camera. Link thresholds should be re-checked on real phone bursts before shipping.
- **No iPhone or Core ML measurements.** No model was converted and no device was profiled, so speed, memory and battery are unknown.
  - Neither is it known whether a flexible-shape SSCD (the form behind the `sscd` rows) runs on the Neural Engine.
  - The fixed-square rows show what a fixed-shape conversion would score.
- **The time-window results depend on synthesized dates.** No public dataset gives real capture times for the series and unrelated shots of one library.
  - photo-triage-tight is a stress test of that date model, not a measurement of real libraries.
  - Its test-half runs are sparser than the full timeline. The whole-set tkscan run is reported next to them.
- **California-ND** is not included, because its photos are password-protected and the password is only given by email.
- **Market claim dropped.** The earlier "most duplicate cleaners are built on hashes" was never measured. No commercial cleaner was tested.
- **Statistical tests are limited to AP.** The in-window and tkscan comparisons have no CIs, so differences of a few points there (for example SSCD 0.790 against DINOv2-small 0.798) should not be read as rankings.
- **Mutual nearest-neighbour results on screenshots are flattered** by every screen there having exactly one copy. On copies, with 1-3 copies each, the same rule finds about 30% of pairs.

## Reproduce

```
cd TidykeepKit && swift build -c release --product tkscan && cd ..       # the app's code, for the apple-* methods and pipeline
bench/.venv/bin/python bench/datasets/build_gopro_bursts.py               # likewise build_bursts_profile, build_photo_triage,
bench/.venv/bin/python bench/datasets/build_screenshots.py                # build_copies, build_photo_triage_tight
bench/.venv/bin/python bench/embed.py --dataset all --method all          # embeddings, signals
bench/.venv/bin/python bench/aesthetic.py                                 # LAION aesthetic baseline
bench/.venv/bin/python bench/evaluate.py                                  # about 9 min on M3 Max; writes out/results.json, out/tables.md
scripts/test.sh                                                           # the Swift tests (69 pass)
```

`evaluate.py` caches tkscan output in `bench/out/<dataset>/app/` (`--force-app` reruns it). `--skip-app` scores the embeddings only.
