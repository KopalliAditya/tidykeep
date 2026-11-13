# Good Take

A free iPhone app that finds runs of near-identical photos (the five shots you took to get
one good one), picks the best of each run, and suggests removing the rest. Everything runs
on the phone with Apple's Vision framework. No account, no ads, no analytics, no network.

Built VoiceOver-first: every screen, photo and decision has a spoken label, and the app
says *why* it picked a photo ("Best pick: sharpest and best faces").

> "Good Take" is a working name. Google ships a feature called "Best Take", so pick a
> distinct name before submitting (see [docs/APP_STORE.md](docs/APP_STORE.md)).

## How it works

1. **Candidates.** Only photos taken within a minute of another photo are looked at, so a
   big library is mostly skipped before any analysis.
2. **Analysis** (`GoodTakeVision`), once per photo and cached on the device:
   - Vision feature print (revision 2) of a lightly blurred copy. The blur makes grouping
     ignore shake and focus blur: blurred frames of a moment land near the sharp one.
   - Vision aesthetics score and its "utility" (document, screenshot) flag.
   - Vision face capture quality for each face.
   - A focus measure: variance of the Laplacian over the sharpest tiles.
3. **Grouping** (`SeriesBuilder`). Shots are grouped in time order when each one is close to
   a recent shot *and* not far from the first shot, which stops a slow pan from chaining.
   Burst frames always group together. Groups are limited in how long they can run.
4. **Ranking** (`ShotScorer`). Sharpness, look and faces are each scaled within the group
   so that a tiny difference stays tiny. A favorite is always the pick. Near-ties are
   marked "close call".
5. **Review.** The user sees each group with the pick starred and can change anything.
   Removal uses PhotoKit, so iOS asks for confirmation and photos go to Recently Deleted.

### Safety rules (enforced in `ReviewDecisions`, covered by tests)

- Favorites, edited photos and document-like photos are never suggested for removal.
- Every group keeps at least one photo. If the photos a group keeps were deleted in Photos
  since the scan, the rest of the group is left alone.
- Favorites and edits are checked again just before removing, in case they changed in Photos.
- Photos only in iCloud are skipped, never downloaded.
- Nothing is deleted without the iOS confirmation dialog.

## Project layout

```
App/                    iOS app entry point, Info.plist, privacy manifest, assets
GoodTakeKit/            Swift package with all the code and tests
  GoodTakeCore          models, grouping, ranking, cache, scanner (no Apple frameworks beyond Foundation)
  GoodTakeVision        Vision analysis and the focus measure
  GoodTakePhotoKit      the photo library (PhotoKit)
  GoodTakeUI            SwiftUI screens and AppModel
  GoodTakeFolderSource  a folder of images as a photo library, for tests and gtscan
  GoodTakeTestSupport   synthetic and real-photo test libraries with known answers
  gtscan                command-line tool for calibration
project.yml             XcodeGen spec; GoodTake.xcodeproj is generated from it
scripts/                tests, icon, network check
docs/                   App Store checklist, privacy policy
```

## Build and run (Mac with Xcode 26 or later)

1. Open `GoodTake.xcodeproj`. If you change `project.yml`, regenerate it with
   `brew install xcodegen && xcodegen generate`.
2. Put your team ID in `DEVELOPMENT_TEAM` in `project.yml` and regenerate, or choose the
   team under Signing & Capabilities (regenerating drops a team chosen there).
3. Run on an iPhone (iOS 18 or later). The simulator works, but its photo library is small.

## Tests

```
scripts/test.sh                 # all package tests
scripts/check-no-network.sh     # fails if app code could reach the network
```

`scripts/test.sh` also works with only the Command Line Tools installed: it points SwiftPM
at the swift-testing macro plugin, which the Command Line Tools keep in a separate folder.

The suites:

| Suite | What it covers |
|---|---|
| GoodTakeCoreTests | grouping, ranking, safety rules, cache, scanner (with fakes), thermal back-off |
| GoodTakeVisionTests | feature print, distance against Vision's own, focus measure, softening, document flag |
| GoodTakeScanTests | end to end on generated and real photos, folder source, AppModel flow, VoiceOver copy, screens render |

The real-photo test uses the profile pictures that ship with macOS (`/Library/User Pictures`)
and is skipped where they're missing.

## Calibration

Thresholds were set on synthetic bursts made from real photos (not drawn shapes), so the blur
in them is simulated. `gtscan bursts` turns real images into handheld bursts (reframing, tilt, exposure drift, then motion or focus blur on every
frame but one) with a `truth.json`. `gtscan calibrate` and `gtscan sweep` then measure
distances and try thresholds.

| Library | Setting | Pair precision | Pair recall | Keeper accuracy | Series |
|---|---|---|---|---|---|
| macOS profile pictures, 29 bursts + 14 singles | Balanced | 1.000 | 1.000 | 1.000 | 29/29 |
| macOS profile + desktop pictures, 32 bursts + 16 singles | Balanced | 1.000 | 1.000 | 1.000 | 32/32 |
| Generated scenes, 6 series + 8 singles | Strict | 1.000 | 1.000 | 1.000 | 6/6 |

On the profile pictures, frames of the same moment are 0.09–0.45 apart and different photos
0.66–1.27, against a Balanced link distance of 0.55. Two things the calibration changed:

- **Softening** (Gaussian blur, σ = 0.8% of the long side, before the feature print) cut
  the distance between sharp and blurred frames of a moment enough to group them reliably.
  The bench (`bench/RESULTS.md`) checks this on held-out real camera shake (GoPro frames):
  softening raises AP from 0.63 to 0.93 there, but lowers it on photo series and screenshots
  without blur (0.92 to 0.79 and 0.83 to 0.54).
- **Document-like photos** are kept rather than left out. Vision flagged the sharp frame of
  some plain-background shots as a document but not their blurred copies, so leaving them
  out pulled the best frame out of its own group.

Not yet measured: real faces (none in the calibration photos) and real phone bursts. Run
`gtscan` on an export of your own photos before trusting the defaults:

```
cd GoodTakeKit
swift run gtscan scan ~/Pictures/export --sensitivity balanced
swift run gtscan bursts /tmp/lib <folder of sources> && swift run gtscan eval /tmp/lib
```

## Notes

- Swift 6 language mode, strict concurrency, iOS 18 / macOS 15.
- `ViewState` is `SwiftUI.State` under another name, so the package also builds with only the
  Command Line Tools (which don't ship SwiftUI's macro plugin). In Xcode, `@State` works too.
- No third-party dependencies.

## License

Apache License 2.0. See [LICENSE](LICENSE).
