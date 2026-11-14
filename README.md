# Tidykeep

A free iPhone app that tidies photos, files and contacts, entirely on the phone. It finds
similar shots, copies, old screenshots and long videos; duplicate and large files in folders
you choose; and duplicate contacts. It suggests, says why, and changes nothing until you
confirm.

> **Nothing changes without you, and everything can be traced.**

iOS 26, iPhone only, portrait, Liquid Glass. Free: no purchases, ads, tips or subscriptions.
Built VoiceOver-first: every screen, photo and decision has a spoken label.

## What it does

| Area | What ships in 1.0 |
|---|---|
| Photos | **Similar Shots:** runs of near-identical photos, the best pick in each and why ("Best pick: sharpest and best faces"). **Copies:** the same photo re-saved, resized, re-encoded, lightly cropped or screenshotted, found across the whole library; the copy with the most detail stays and the others' favorite and albums move onto it. **Screenshots:** by month, nothing marked in advance. **Big Videos:** over 1 minute, sorted by duration × pixels. Photos and videos show counts, pixels and durations, never bytes. |
| Files | Only in folders the user picks. **Duplicate Files:** same size, then a 64 KB head-and-tail hash, then a full SHA-256. **Large Files:** 100 MB and over, with exact bytes. **Holding:** a file moves into a "Held by Tidykeep" folder at the root of the folder it came from (a same-volume rename), with Put back, Delete now and Empty. |
| Contacts | Duplicate cards by name, phone or email, only within one account. A phone number shared by three or more cards never counts as a match. A merge preview shows where each field comes from; a vCard backup is written first, and Undo puts things back. |
| History | A receipt for every change, written before the change (in progress) and after it (done, failed or partial). Receipts hold metadata only, never images, and are kept for a year. Each one shows the way back where there is one (Recently Deleted for photos, for 30 days; Put back for files in Holding; Undo for contacts) and says so when there is none, as after Delete now or Empty in Holding. |
| Rules | What's always kept (favorites, edited and hidden photos; chosen albums; screenshots in albums; files changed in the last 7 days; My Card), what to look at, folders, haptics, saved data, and About. |

It can't clear caches, System Data, Messages attachments or other apps' data, because iOS
doesn't let any app do that, and it never says it can.

### How the promise shows up

- **Reason card** (Why · Kept safe · Undo) on every group, copy set, file set, contact merge,
  review sheet and receipt. Why uses only the engine's own phrases; Undo always names where
  things go and until when, or says "Can't be undone".
- **Receipts.** A change that was cut short (the app quit mid-way) is re-checked on the next
  launch and its receipt finished, so History never claims a change that didn't happen.
- **Coverage line.** "Checked 2,814 photos · 212 skipped" under each header; it opens the
  five reasons a photo was skipped (only in iCloud, couldn't be read, in a Shared Album,
  outside the chosen range, kept safe by a rule).
- **One gate.** Every removal, move or merge goes through the same review sheet ("Remove 9
  photos?"). Photo removals then get iOS's own confirmation and go to Recently Deleted.

## Privacy

- **No network code.** `scripts/check-no-network.sh` fails on any networking API, web view,
  share sheet, link or scheme-prefixed URL in the app's Swift, on any third-party package,
  and on network or iCloud keys in the app's plists and entitlements.
- **Nothing collected.** No account, analytics, crash reporting, ads or tracking. The App
  Store label is "Data Not Collected", and `App/PrivacyInfo.xcprivacy` agrees.
- **Never downloads.** Photos and files that are only in iCloud are skipped and counted.
- **Stays in the app.** The photo analysis, receipts, vCard backups, folder bookmarks and
  preferences live in the app's container; deleting the app deletes them.
- The policy is `docs/PRIVACY.md`. The app ships the same text as plain text in
  `TidykeepKit/Sources/TidykeepUI/Resources/PrivacyPolicy.txt`; change both together.

## How the photo engine works

1. **Order** (`Scanner`). Photos taken within a minute of another photo, or in a burst, are
   analyzed first, newest first, so similar shots show up early. Every other photo follows,
   because the copy pass needs them all. Screenshots never form a series.
2. **Analysis** (`TidykeepVision`), once per photo and cached on the device:
   - Vision feature print (revision 2) of a lightly blurred copy. The blur makes grouping
     ignore shake and focus blur: blurred frames of a moment land near the sharp one.
   - DINOv2-small content embeddings (Apache-2.0, bundled Core ML model, center crop). They
     tell neighbouring moments apart better than the softened print does.
   - Vision aesthetics score and its "utility" (document, screenshot) flag.
   - Vision face capture quality for each face.
   - A focus measure: variance of the Laplacian over the sharpest tiles.
3. **Grouping** (`SeriesBuilder`). Shots are grouped in time order when each one is close to
   a recent shot *and* not far from the first shot, which stops a slow pan from chaining.
   "Close" weighs the softened print and the DINOv2 embedding together (`GroupingConfig`).
   Burst frames always group together. Groups are limited in how long they can run.
4. **Copies** (`CopyFinder`, then `LibraryGroups`). A copy is usually made days later, so the
   time window can't find it. A separate pass over the whole library compares DINOv2
   embeddings (screen-like pairs must also be as close as a re-save in the softened print),
   and clusters with complete linkage, so every pair in a copy set passes on its own. Copy
   sets then lose any photo already in a series, so no photo is in two groups.
5. **Ranking** (`ShotScorer`). Sharpness, look and faces are each scaled within the group
   so that a tiny difference stays tiny. A favorite is always the pick. Near-ties are
   marked "close call".
6. **Review.** The user sees each group with the best pick marked and can change anything.
   Removal uses PhotoKit, so iOS asks for confirmation and photos go to Recently Deleted.

### Safety rules (enforced in `ReviewDecisions`, covered by tests)

- Favorites, edited photos and document-like photos are never suggested for removal.
- Every group keeps at least one photo. If the photos a group keeps were deleted in Photos
  since the scan, the rest of the group is left alone.
- Favorites and edits are checked again just before removing, in case they changed in Photos.
- Photos only in iCloud are skipped, never downloaded.
- Nothing is deleted without the iOS confirmation dialog.

## How it's built

All the code and tests are in one Swift package, `TidykeepKit` (tools version 6.2, Swift 6
language mode with strict concurrency, iOS 26 and macOS 26). The app target in `App/` is a
thin shell around it. There are no third-party dependencies.

```
App/                    iOS app entry point, Info.plist, privacy manifest, icon and accent colour
TidykeepKit/            Swift package with all the code and tests
  TidykeepCore          models, time-window grouping, library-wide copy pass, ranking, safety
                        and protection rules, receipts, analysis cache, scanner (Foundation only)
  TidykeepVision        Vision analysis, the focus measure and the DINOv2 content model
  TidykeepPhotoKit      the photo library (PhotoKit)
  TidykeepUI            SwiftUI screens, AppModel, Copy.swift (every user-facing string), design
                        tokens and components, bundled privacy policy and acknowledgements
  TidykeepFolderSource  a folder of images as a photo library, for tests and tkscan (not in the app)
  TidykeepTestSupport   synthetic and real-photo test libraries with known answers (not in the app)
  tkscan                command-line scanner for calibration and evaluation (not in the app)
bench/                  the duplicate-photo benchmark (Python) and the Core ML conversion
project.yml             XcodeGen spec; Tidykeep.xcodeproj is generated from it
scripts/                package tests, network check, app icon
docs/                   App Store listing and checklist, privacy policy
```

### The on-device content model

`TidykeepVision` bundles DINOv2-small (ViT-S/14, by Meta, Apache-2.0) as a compiled Core ML
model, `DINOv2Small.mlmodelc`. `bench/coreml/convert_dinov2.py` builds it: input normalization
folded into the first layer, position embeddings resampled for a 224 × 224 input, weights
compressed to 8-bit palettes. The app feeds it a centre crop resized with the same bicubic
filter the benchmark used (`BicubicResampler`), because the thresholds were fitted on exactly
that input. Its licence and notice ship next to it and are repeated in `NOTICE` and in the
app's Acknowledgements.

### The benchmark

`bench/` compares the app's signals (the softened Vision feature print, then DINOv2) with
open-source hashes and image embeddings on public datasets and on the images that ship with
macOS, and runs the strongest of them inside the app's own grouping code. It is where the
engine's constants come from (`bench/rules.py`) and where the choice of model was made.
SSCD came closest to winning everywhere but is MIT-licensed, so it can't ship (CLIP is MIT
too, and scored below DINOv2-small everywhere except screenshots). Among the Apache-2.0
models, DINOv2-small ties for best on copies (AP 1.000, with the larger DINOv2-base; SigLIP 2
gets 0.937) and is close on real photo series (0.910, against SigLIP 2's 0.941) at about a
quarter of SigLIP 2's size (88 against 372 MB fp32).
Results and caveats are in `bench/RESULTS.md`, setup in `bench/README.md`.
It is a development tool only: nothing in `bench/` ships in the app.

## Build and run (Mac with Xcode 26)

1. `brew install xcodegen`, then `xcodegen generate` in the repo root. Run it again after
   every change to `project.yml`.
2. Put your 10-character team ID in `DEVELOPMENT_TEAM` in `project.yml` and regenerate. A
   team chosen under Signing & Capabilities is lost the next time the project is generated.
3. Open `Tidykeep.xcodeproj` and run the Tidykeep scheme on an iPhone with iOS 26 or later.
   The simulator works too, but its photo library and contacts are nearly empty.

The app is iPhone only and portrait only. It uses no iOS 27 API, because CI builds with the
iOS 26.5 SDK.

The app icon is drawn in code: `swift scripts/make-icon.swift
App/Assets.xcassets/AppIcon.appiconset` writes the default, dark and tinted 1024 px PNGs.

## Tests

```
scripts/test.sh                 # all package tests
scripts/check-no-network.sh     # fails if app code could reach the network
```

`scripts/test.sh` also works with only the Command Line Tools installed: it points SwiftPM
at the swift-testing macro plugin, which the Command Line Tools keep in a separate folder.
Code that only exists on iOS (`#if os(iOS)`) can't build there; CI covers it.

The suites:

| Suite | What it covers |
|---|---|
| TidykeepCoreTests | grouping, copy pass, ranking, safety rules, cache, scanner (with fakes), thermal back-off |
| TidykeepVisionTests | feature print, distance against Vision's own, focus measure, softening, document flag, content model and its input framing |
| TidykeepScanTests | end to end on generated and real photos, folder source, AppModel flow, VoiceOver copy, screens render |

The real-photo test uses the profile pictures that ship with macOS (`/Library/User Pictures`)
and is skipped where they're missing.

## CI

CI runs on GitHub Actions macOS runners with Xcode 26.x (iOS 26.5 SDK, Swift 6.3). It runs
`scripts/test.sh` and `scripts/check-no-network.sh`, builds the app for the iOS simulator
(the only place the `#if os(iOS)` code compiles), and runs the UI tests on the iPhone 17 Pro
Max simulator, after adding known photos and videos to its library
(`scripts/ci/make-seed-media.swift`, which uses only images that ship with macOS or synthetic
scenes). Files and contacts come from the app itself: launched with `-TKSeedFiles YES` and
`-TKSeedContacts YES` on the simulator, it makes a sample folder of duplicate files and
made-up duplicate cards. The UI tests also save the 1320 × 2868 screenshots for the App Store listing (see
`docs/APP_STORE.md`). Nothing in CI signs, uploads or publishes.

## Calibration

The grouping constants were fitted in `bench/rules.py` on the dev halves of the benchmark sets
(real photo series and synthetic blurry bursts) and checked on the held-out halves and on real
camera shake (GoPro frames). Don't tune them by hand. `tkscan bursts` turns real images into
handheld bursts (reframing, tilt, exposure drift, then motion or focus blur on every frame but
one) with a `truth.json`, so the blur in them is simulated. `tkscan eval` scores a scan against
it, and `tkscan calibrate` and `tkscan sweep` measure distances and try thresholds.
`tkscan copies` runs the series step and then the copy pass, and scores the copy sets against
a `truth.json` that lists each photo with its copies.

| Library | Setting | Pair precision | Pair recall | Keeper accuracy | Series |
|---|---|---|---|---|---|
| macOS profile pictures, 29 bursts + 14 singles | Balanced | 1.000 | 1.000 | 1.000 | 29/29 |
| macOS profile + desktop pictures, 32 bursts + 16 singles | Balanced | 1.000 | 1.000 | 1.000 | 32/32 |
| Generated scenes, 6 series + 8 singles | Strict | 1.000 | 1.000 | 1.000 | 6/6 |

On the profile pictures, frames of the same moment are 0.09–0.45 apart in softened print and
different photos 0.66–1.27. Balanced links a pair when 0.3115 × that distance + 0.6885 × the
DINOv2 distance is at most 0.55, or the softened distance alone is at most 0.35 (which keeps
blurred frames the content model pulls apart). A photo with no DINOv2 vector links on the
softened distance alone, at most 0.55. Normalized so that 1 links, frames of a moment score
0.19–0.93 and different photos 1.16–2.48. Two things the calibration changed:

- **Softening** (Gaussian blur, σ = 0.8% of the long side, before the feature print) cut
  the distance between sharp and blurred frames of a moment enough to group them reliably.
  The bench (`bench/RESULTS.md`) checks this on held-out real camera shake (GoPro frames):
  softening raises AP from 0.63 to 0.93 there, but lowers it on photo series and screenshots
  without blur (0.92 to 0.79 and 0.83 to 0.54).
- **Document-like photos** are kept rather than left out. Vision flagged the sharp frame of
  some plain-background shots as a document but not their blurred copies, so leaving them
  out pulled the best frame out of its own group.

`bench/swift_parity.py` runs `tkscan` on every benchmark set and scores the Swift engine's
groups with the bench's own scorers. Series precision and recall land within 0.01 of the
bench's and within two series per set; the copy-pass scores and the groups the app would show
match exactly (150 of 150 copy sets). The content model's input is resized with the bench's
exact filter for this: CoreGraphics' resampling cost up to three series and a screenshot pair.

Not yet measured: real faces (none in the calibration photos) and real phone bursts. Run
`tkscan` on an export of your own photos before trusting the defaults:

```
cd TidykeepKit
swift run tkscan scan ~/Pictures/export --sensitivity balanced
swift run tkscan bursts /tmp/lib <folder of sources> && swift run tkscan eval /tmp/lib
```

## Notes

- Swift 6 language mode, strict concurrency, iOS 26 / macOS 26 (macOS only for tests and
  rendering screens to images during development; the app ships on iPhone only).
- `ViewState` is `SwiftUI.State` under another name, so the package also builds with only the
  Command Line Tools (which don't ship SwiftUI's macro plugin). In Xcode, `@State` works too.
  For the same reason there are no `#Preview`, `@Entry` or `@Previewable` macros.
- Every user-facing string lives in `Copy.swift`; iOS-only calls live in `Platform.swift`
  behind `#if os(iOS)`.
- No third-party dependencies.

## License

Apache License 2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). The bundled DINOv2 model
weights are Copyright (c) Meta Platforms, Inc. and affiliates, also under the Apache License
2.0. No MIT-licensed code or models are included.
