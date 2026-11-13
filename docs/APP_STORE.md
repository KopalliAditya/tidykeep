# App Store checklist

## Before the first build

- [ ] **Pick the name.** "Good Take" is too close to Google's "Best Take". Check the name is
      free in App Store Connect (names are unique) and search trademarks (USPTO) first.
      Changing it means: `CFBundleDisplayName` in `project.yml`, `AppInfo.name` in
      `GoodTakeUI/AppModel.swift`, and the copy in `README.md` / `docs/PRIVACY.md`.
- [ ] Bundle ID: `com.kopalliaditya.goodtake` (change in `project.yml` if wanted; it can't
      change after the first upload).
- [ ] Set `DEVELOPMENT_TEAM` in `project.yml` and run `xcodegen generate`. A team picked in
      Xcode works too, but regenerating the project drops it.
- [ ] Apple Developer Program membership ($99/yr).

## Test on a real iPhone first

These paths have never run, because they need iOS:

- [ ] First launch: permission prompt, then full, limited and denied access.
- [ ] Limited access: the "Only photos you picked" note, "Choose photos" (the picker opens,
      then the app checks again) and "Open Settings".
- [ ] Scan a real library (thousands of photos): time, battery, heat, Low Power Mode.
- [ ] Bursts and Live Photos group as expected; screenshots and receipts aren't offered.
- [ ] Faces: a group shot with one blink picks the frame with eyes open.
- [ ] Remove: the iOS confirmation appears, photos land in Recently Deleted.
- [ ] Coming back from Photos after deleting there triggers a rescan.
- [ ] VoiceOver: every control and photo is labeled, announcements are spoken, and the whole
      flow works with the screen curtain on (triple-tap with three fingers).
- [ ] Dynamic Type at the largest accessibility size; Dark Mode; Reduce Motion.
- [ ] iCloud-only photos are skipped (turn on Optimize iPhone Storage).
- [ ] Going to the Home screen mid-scan stops it, and coming back picks it up again.
- [ ] Run on an iPad too: App Review often tests iPhone-only apps there in compatibility mode.

## App Store Connect

- **Category:** Photo & Video. **Price:** Free. **No in-app purchases.**
- **Age rating:** 4+.
- **App Privacy:** "Data Not Collected". This matches `App/PrivacyInfo.xcprivacy`.
- **Privacy policy URL** (required): host `docs/PRIVACY.md` somewhere public. The repo is
  private, so use GitHub Pages from a separate public repo, a gist or a personal site.
  Add a contact email to its Contact section first.
- **Support URL** (required): a page or a public repo's issues.
- **Export compliance:** no encryption (`ITSAppUsesNonExemptEncryption` is NO).
- **Availability:** turn off "Apple silicon Mac" and "Apple Vision Pro" unless tested there.
- **Screenshots:** 6.9" iPhone at least. Show a group with "Best pick: sharpest and best faces",
  the VoiceOver rotor, and the "Everything happens on this phone" section.

## Review notes (paste into App Review Information)

> Good Take groups near-identical photos and suggests the best one to keep. All analysis is
> on-device with Vision; the app makes no network requests. To prefer frames where nobody
> blinked it uses Vision's face capture quality score; it doesn't recognize people or store
> face images or geometry. Removal goes through PhotoKit, so iOS shows its own confirmation
> and photos go to Recently Deleted. To try it, take 4–5 photos of the same thing in a row,
> then open the app.

## Guidelines to keep in mind

- **4.3 (spam / copycats).** Photo cleaners are a crowded category. Lead with what's
  different: VoiceOver-first, on-device, explains each pick, free with no upsell.
- **5.1.1 (data).** Photo access is needed for the app's core function; the purpose string
  says what it's for, including removal. The button before the system prompt says
  "Continue", not "Allow". Don't add sign-in or analytics.
- **5.1.2(vi) (faces).** Face scores are covered in the privacy policy and review notes.
- **2.3 (accurate metadata).** Don't promise storage saved figures the app doesn't measure.
- **2.1 (completeness).** No placeholder text, no dead buttons, works on a fresh device.

## Every release

- [ ] `scripts/test.sh` passes.
- [ ] `scripts/check-no-network.sh` passes.
- [ ] Bump `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION` for user-visible releases) in
      `project.yml`, then `xcodegen generate`. Info.plist reads both from build settings.
- [ ] If analysis changed, `VisionFrameAnalyzer.version` changed too, so caches rebuild.
- [ ] Archive (Product → Archive) → Distribute → App Store Connect → TestFlight first.
