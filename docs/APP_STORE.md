# Tidykeep 1.0 on the App Store

Everything to paste into App Store Connect, then the owner's checklist. Character counts were
measured on the exact text in each block (Unicode characters, without the final newline).
App Store Connect limits: name 30, subtitle 30, promotional text 170, description 4,000,
keywords 100 bytes, review notes 4,000.

Words the store text avoids on purpose: "clean", "cleaner", "junk", "boost", "free up space",
and any competitor or Apple-app name as a keyword (guidelines 2.3.1, 2.3.7 and 4.3). Photos and
videos never get byte counts; only files do.

## App information

| Field | Value |
|---|---|
| Name | `Tidykeep` (8 characters) |
| Subtitle | see below (28 characters) |
| Bundle ID | `com.kopalliaditya.tidykeep` (from `project.yml`; it can't change after the first upload) |
| SKU | `tidykeep-ios` (any unique string; never shown) |
| Primary language | English (U.S.) |
| Primary category | Utilities |
| Secondary category | Photo & Video |
| Content rights | Yes, it contains third-party content, and you have the rights: the DINOv2 model weights (Apache-2.0, credited in Acknowledgements). The person's own photos aren't third-party content |
| Age rating | 4+ (answers below) |
| Copyright | `2026 Aditya Kopalli` |
| Price | Free (USD 0.00), all territories |
| In-app purchases | None. Don't create any, and don't sign the Paid Apps agreement |
| Availability | iPhone only. Turn off "Apple silicon Mac" and "Apple Vision Pro" |

**Why Utilities first and Photo & Video second.** Tidykeep works across three kinds of data:
photos, files and contacts. Utilities describes the whole app; Photo & Video alone would hide
the Files and Contacts half and set the wrong expectation. Photo & Video is still where most
of the work happens (similar shots, copies, screenshots, videos), so it's the secondary
category, where people browsing for photo tools will find it. `LSApplicationCategoryType` in
`project.yml` still says `public.app-category.photography`; set it to
`public.app-category.utilities` to match (it doesn't change the store listing on iOS, but it's
tidier).

### Subtitle (28 characters)

```text
Tidy photos, files, contacts
```

### Promotional text (167 characters)

Can be changed at any time without a new build.

```text
Find similar shots, copies, old screenshots, duplicate files and contacts. Review every change first; History keeps a receipt for each one. Nothing leaves your iPhone.
```

### Description (2,431 characters)

```text
Tidykeep helps you tidy the photos, files and contacts on your iPhone, one decision at a time. It finds what's worth a look, tells you why, and changes nothing until you confirm. Everything happens on your iPhone.

PHOTOS
• Similar Shots: runs of near-identical photos, like a burst or five tries at the same picture. Tidykeep suggests the best one in each group and says why, for example "sharpest and best faces".
• Copies: the same photo saved more than once: resized, saved in another format, or as a screenshot. A favorite or edited copy is always the one kept; otherwise the copy with the most detail stays. It's added to the albums of the copies removed.
• Screenshots: look back through old screenshots by month and mark the ones you're done with.
• Big Videos: videos over a minute, with their length and resolution.

FILES
• Duplicate Files: files that are the same, byte for byte, in the folders you choose.
• Large Files: files of 100 MB or more, biggest first, with exact sizes.
• Holding: files you set aside wait in a "Held by Tidykeep" folder until you put them back or delete them.

CONTACTS
• Duplicate Contacts: cards for the same person, found by name, phone number or email. See the merged card before you merge. A backup is saved first, so you can undo it.

NOTHING CHANGES WITHOUT YOU
Every removal, move and merge goes through one review screen that shows what goes, what stays, what your rules kept safe, and how to undo it, or that it can't be undone. Removed photos go to Recently Deleted for 30 days.

A RECEIPT FOR EVERY CHANGE
History keeps a receipt for every change and shows the way back where there is one: Recently Deleted for photos (30 days), Put back for files in Holding, and Undo for contacts. Permanent deletes say so before you confirm.

YOUR RULES
Favorites, edited photos and hidden photos are always kept. You can also protect albums and recently changed files.

PRIVATE BY DESIGN
No account, no ads, no analytics, no tracking, and no network access at all. Tidykeep works in Airplane Mode. Your photos, files and contacts never leave your iPhone.

MADE FOR EVERYONE
Built for VoiceOver from the start, with support for larger text sizes, Dark Mode, Increased Contrast and Reduce Motion.

FREE
Tidykeep is free. No purchases, ads, tips or subscriptions.

WHAT IT CAN'T DO
iOS doesn't let apps clear caches, System Data, Messages attachments or other apps' data, so Tidykeep doesn't try.
```

### Keywords (99 characters)

Comma separated, no spaces after commas. Words already in the name or subtitle (tidy, photos,
files, contacts) are left out because the store indexes those anyway. No trademarks, no app
names, no competitor names. "storage" and "space" are left out because the app doesn't
measure storage saved for photos and shouldn't look like it promises it.

```text
duplicate,similar,burst,screenshot,video,merge,organize,declutter,private,offline,album,dedupe,undo
```

## Age rating: 4+

Answer the questionnaire like this. Every answer is None or No.

| Section | Question | Answer |
|---|---|---|
| Features | Parental controls | No |
| | Age assurance | No |
| | Unrestricted web access | No (the app has no web view and no network code) |
| | User-generated content | No (it shows only the person's own photos, files and contacts) |
| | Messaging and chat | No |
| | Advertising | No |
| Mature themes | Profanity or crude humor | None |
| | Horror or fear themes | None |
| | Alcohol, tobacco or drug use or references | None |
| | Mature or suggestive themes | None |
| Medical and wellness | Medical or treatment information | None |
| | Health or wellness topics | No |
| Sexuality and nudity | Sexual content or nudity | None |
| | Graphic sexual content and nudity | None |
| Violence | Cartoon or fantasy violence | None |
| | Realistic violence | None |
| | Prolonged graphic or sadistic realistic violence | None |
| | Guns or other weapons | None |
| Chance-based activities | Simulated gambling | None |
| | Contests | None |
| | Gambling | No |
| | Loot boxes | No |
| Kids | Made for Kids | No |

## Pricing

Free, with no in-app purchases, subscriptions, tips or ads, now or later. Accept only the
free-apps terms that come with the developer membership. Don't sign the Paid Apps agreement,
and leave banking and tax forms untouched.

## App Privacy: "Data Not Collected"

In App Privacy, answer **"No, we do not collect data from this app"**. That gives the label
"Data Not Collected". It's true because:

- Apple counts data as collected when it leaves the device. Tidykeep has no network code at
  all, so nothing can leave. `scripts/check-no-network.sh` fails the build check on network
  APIs (URLSession, Network.framework, CFNetwork, Bonjour and NetService, LinkPresentation,
  MapKit, CloudKit, the iCloud key-value store, Multipeer); web views; share sheets and mail
  compose; `Link`, `openURL` and opening URLs other than Settings; URLs with a scheme; and
  third-party packages in `Package.swift`, `project.yml` or the Xcode project.
- There are no third-party SDKs, analytics, crash reporting, ads or account.
- The photo analysis, History receipts, vCard backups, folder bookmarks and preferences stay in
  the app's own container on the iPhone, and deleting the app deletes them.
- `App/PrivacyInfo.xcprivacy` says the same: `NSPrivacyTracking` false, no tracking domains, no
  collected data types. Its required-reason entries are for local use only: UserDefaults
  (CA92.1, the app's own preferences), file timestamps (C617.1 for its own container, 3B52.1
  for folders the user picked, DDA9.1 for dates shown to the user) and disk space (85F4.1:
  `getattrlist` reads how much space a file really takes, which the app shows).

Privacy Policy URL: required, see the owner checklist. The policy text is `docs/PRIVACY.md`;
the app ships the same text as `TidykeepKit/Sources/TidykeepUI/Resources/PrivacyPolicy.txt`.
Change both together.

## Accessibility Nutrition Labels

Under App Accessibility, declare only what has been checked on a real iPhone with TestFlight.
Tidykeep is built for these; tick each one after testing the common tasks (check, review,
remove, move to Holding, merge contacts, undo):

| Feature | Declare | Check on device |
|---|---|---|
| VoiceOver | Yes, after testing | Every control and photo is labeled; the whole flow works with Screen Curtain on |
| Voice Control | After testing | Every button can be said by name |
| Larger Text | Yes, after testing | Largest accessibility size; nothing is cut off; the action bar stacks |
| Dark Interface | Yes, after testing | Dark Mode on every screen |
| Differentiate Without Color Alone | Yes, after testing | Keep / Remove are symbols and words, not colour |
| Sufficient Contrast | Yes, after testing | Increased Contrast on; the accent switches to `#05545E` / `#80D6DB` |
| Reduced Motion | Yes, after testing | Reduce Motion on; no sliding or zooming transitions |
| Captions, Audio Descriptions | No | The app has no video or audio of its own |

## Export compliance

The app uses no encryption. It makes no network connections, so it doesn't use HTTPS or TLS,
and it encrypts nothing. It computes SHA-256 hashes only to tell whether two files have the
same contents, which is not encryption. `ITSAppUsesNonExemptEncryption` is `NO` in
`App/Info.plist` (set in `project.yml`), so App Store Connect doesn't ask for each build. If
asked, answer that the app doesn't use encryption.

## App Review information

| Field | Value |
|---|---|
| Sign-in required | No. There is no account |
| Contact | Aditya Kopalli, the owner's phone, the real support email |
| Attachment | None needed |

### Notes (3,383 characters)

```text
Tidykeep needs no account, sign-in or network connection. It contains no network code, works in Airplane Mode, and does all its work on the device.

To see each feature on a fresh device:

1. Photos. Before opening Tidykeep, take 4 or 5 photos of the same thing in a row with the Camera (Similar Shots). Then take one photo of something else. In Photos, open that photo and choose Duplicate from the More menu, then open the duplicate, swipe up, tap Adjust next to the date and set it one day earlier (Copies). A duplicate that keeps the original's date counts as a similar shot instead, because copies are found across time. Take 2 screenshots of different screens (Screenshots). Record a video longer than 1 minute (Big Videos). Then open Tidykeep, tap Continue and allow access. The Tidy tab fills in as the check runs.

2. Removing photos. Open Similar Shots, open a group and tap the Remove button at the bottom. The sheet "Remove N photos?" shows what goes, what stays and how to undo. Confirming shows the system's own delete confirmation, and removed photos go to Recently Deleted.

3. Files. Files changed in the last 7 days are kept out of Duplicate Files and Large Files by default, because they are probably still in use, so first open the Rules tab and turn off "Files changed in the last 7 days" under Always Keep. In the Files app, make a folder in On My iPhone, put any file in it, then touch and hold the file and choose Duplicate. In Tidykeep, open Duplicate Files, choose that folder, and move the extra copy to Holding. It moves into a "Held by Tidykeep" folder inside the chosen folder. In Holding, swipe a file for Put back or Delete; Put all back and Empty Holding are at the bottom. Large Files lists files of 100 MB or more, if there are any.

4. Contacts. In Contacts, create two cards with the same name and the same phone number. In Tidykeep, open Duplicate Contacts, tap Continue and allow access, then open the pair. The preview shows which card each detail comes from. Merging asks "Merge anyway", because iOS doesn't let the app read contact notes. A vCard backup is saved in the app first, and Undo is in History.

5. History and Rules. Every change writes a receipt in the History tab, with the way back where there is one, or a note that it can't be undone. The Rules tab holds what is always kept. Rules > About shows the privacy policy and acknowledgements inside the app.

Notes:
- Photos access is requested on first launch, after a one-screen introduction whose button reads "Continue". Contacts access is requested only when the user taps Continue in Duplicate Contacts or under Contacts in Rules. Files are read only in folders the user picks. If any access is denied, the rest of the app still works.
- To prefer a photo where nobody blinked, the app uses Vision's face capture quality score on the device. It doesn't recognize or identify people and doesn't store face images or face geometry.
- Photo similarity uses a bundled Core ML model (DINOv2, Apache License 2.0) that runs on the device.
- Nothing is deleted without a confirmation. Photos go through the system confirmation to Recently Deleted. Files are deleted permanently only from Holding, after a confirmation. Contact merges can be undone from History.
- The app is free: no in-app purchases, ads, tips, subscriptions, analytics or tracking. App Privacy: Data Not Collected.
```

## Screenshots

App Store Connect needs the 6.9-inch iPhone size; it scales those down for smaller iPhones.
No iPad set is needed because the app is iPhone only.

- **Size:** 1320 x 2868 pixels, portrait, PNG, no transparency.
- **Source:** the iPhone 17 Pro Max simulator (iOS 26.x). CI's UI-test run
  (`TidykeepUITests/ScreenshotTests.swift`) captures them into the "screenshots" artifact,
  so no one's real photos, files or contacts appear:
  - photos and videos: known media added to the simulator's library first
    (`scripts/ci/make-seed-media.swift`, then `scripts/ci/seed-simulator.sh`);
  - files and contacts: the app itself, launched with `-TKSeedFiles YES` and
    `-TKSeedContacts YES` (simulator only), makes a sample folder of duplicate files and
    made-up duplicate contact cards.
- **If a files or contacts shot comes out empty** ("No folders chosen" or "All tidy"), the
  sample didn't load, or its files are newer than the "Files changed in the last 7 days"
  rule allows. Don't upload it. Fix the seed, or capture that screen by hand on the
  simulator with made-up files and contacts only.
- **Pictures in the screenshots:** by default the seed uses images that ship with macOS. Those
  belong to Apple, so don't put them in store screenshots. Re-run the seed with
  `--pictures DIR` pointing at photos you own and are happy to show (objects or places, no
  people), or at public-domain images, and capture the store set from that run.
- **Status bar:** 9:41, full battery, full signal (`xcrun simctl status_bar booted override
  --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4`).
- **Order and captions** (one line each; use them as the overlay text, or just as the order):

| # | Screen | CI capture | How the UI test reaches it | Caption |
|---|---|---|---|---|
| 1 | Tidy home: coverage line, Photos cards, Files and Contacts rows | `01-home` | first screen after the photo check | Photos, files and contacts, tidied on your iPhone |
| 2 | A Similar Shots group: pager on the best pick, Why line, Keep / Remove picker | `03-group` | `home.card.similar`, then `similar.row.0` | See the best shot, and why it was picked |
| 3 | Review sheet "Remove 9 photos?": Removing / Staying, Reason card | `04-review` | `actionbar.primary` in that group | Nothing changes until you confirm |
| 4 | A Copies set: the keeper, copy rows (pixels, format, date), what merges onto it | `05-copies` | `home.card.copies`, then `copies.row.0` | Copies merge onto the one you keep |
| 5 | A Duplicate Files set: "Same file, byte for byte.", exact sizes | `06-files` | `home.row.dupfiles`, then `dupfiles.row.0` (sample folder) | Find files that match byte for byte |
| 6 | Contact merge preview with the source of each detail | `08-contacts-merge` | `home.row.contacts`, then `contacts.row.0` (made-up cards) | Merge duplicate contacts, with a backup first |
| 7 | History: receipts by day | `09-history` | `tab.history` | Every change leaves a receipt |
| 8 | Rules: Always Keep, What to look at | `10-rules` | `tab.rules` | Your rules decide what is always kept |

The run also saves `02-similar`, `07-holding` and dark versions of the home screen and a
group (`01-home-dark`, `03-group-dark`); use them in place of a row above if they read
better.

Check every screenshot for: no placeholder text, no real names or faces of real people,
made-up contacts only, and copy that matches the build being submitted.

## Owner checklist before submitting

Only the owner can do these.

### Accounts and project

- [ ] **Apple Developer Program** membership (individual, USD 99 a year), in the owner's own
      name and personal Apple Account, not a work account.
- [ ] **Team ID:** put the 10-character team ID in `DEVELOPMENT_TEAM` in `project.yml`, then
      run `xcodegen generate`. A team picked in Xcode is lost the next time the project is
      regenerated.
- [ ] **Name:** check "Tidykeep" is free when creating the app record (store names are
      unique) and search the USPTO trademark database for it.
- [ ] **App record:** App Store Connect > Apps > + > New App: iOS, name Tidykeep, English
      (U.S.), bundle ID `com.kopalliaditya.tidykeep`, SKU `tidykeep-ios`.
- [ ] **EU trader status** (Digital Services Act), under Business in App Store Connect. An
      individual who earns nothing from the app is normally not a trader; read Apple's
      guidance and choose.

### Support email, Support URL, Privacy Policy URL

- [ ] **Real support email.** The placeholder `support@tidykeep.app` only works if you own
      that domain. Make a dedicated address (for example a new free mail account just for
      Tidykeep) and replace the placeholder in all four places:
      `Copy.About.supportEmail` in `TidykeepKit/Sources/TidykeepUI/Rules/RulesCopy.swift`,
      `docs/PRIVACY.md`, `TidykeepKit/Sources/TidykeepUI/Resources/PrivacyPolicy.txt`, and
      the App Review contact.
- [ ] **Support URL and Privacy Policy URL are both required**, and both must open without a
      sign-in. The code repo stays private, so host only the policy and a short support page.
      Two free ways:
  1. **GitHub Pages from a separate, public, docs-only repo.** Pages on a private repo needs a
     paid plan, so make a new public repo (for example `KopalliAditya/tidykeep-site`) holding
     only `index.md` (support page: what Tidykeep does, the support email, how to get things
     back) and `privacy.md` (a copy of `docs/PRIVACY.md`). Settings > Pages > Deploy from a
     branch > `main`, folder `/`. The addresses become
     `kopalliaditya.github.io/tidykeep-site/` (Support URL) and
     `kopalliaditya.github.io/tidykeep-site/privacy` (Privacy Policy URL). No code goes in
     that repo.
  2. **Google Sites.** Create a site (for example `sites.google.com/view/tidykeep`) with two
     pages, Support and Privacy, paste the text in, and publish it to anyone with the link.
     Nothing is tied to GitHub at all.

  Paste the addresses into App Store Connect with the `https` prefix. Whenever
  `docs/PRIVACY.md` changes, update the hosted page and `PrivacyPolicy.txt` the same day.

### Build, archive and upload (Mac with Xcode 26.x)

- [ ] `scripts/test.sh` and `scripts/check-no-network.sh` both pass.
- [ ] Every permission the app asks for has a purpose string under `info.properties` in
      `project.yml`, and `App/Info.plist` has it after `xcodegen generate`: today
      `NSPhotoLibraryUsageDescription` and `NSContactsUsageDescription`. Without one, iOS ends
      the app the moment it asks, which App Review rejects as a crash (2.1). Each string says
      what is read, what can change, and that nothing leaves the iPhone.
- [ ] Bump `CURRENT_PROJECT_VERSION` in `project.yml` for every upload (`MARKETING_VERSION`
      stays `1.0` for this release), then `xcodegen generate`.
- [ ] Open `Tidykeep.xcodeproj`, choose the Tidykeep scheme and **Any iOS Device (arm64)**.
- [ ] Product > Archive (the scheme archives the Release configuration).
- [ ] In the Organizer: Validate App, then Distribute App > App Store Connect > Upload, with
      automatic signing.
- [ ] Wait for the "processing complete" email. The build appears under TestFlight. Export
      compliance is already answered by `ITSAppUsesNonExemptEncryption`.

### TestFlight on a real iPhone first

Add yourself as an internal tester, install TestFlight on your own iPhone, and install the
build. These paths can't run on the simulator or in CI:

- [ ] First launch: the Photos prompt, then full, limited ("Choose more photos") and denied
      access. Denied still leaves Files and Contacts working.
- [ ] A real library of thousands of photos: time, battery, heat, Low Power Mode, and "Keep
      Tidykeep open to finish. It picks up where it left off."
- [ ] Bursts and Live Photos group as expected; iCloud-only photos are skipped, never
      downloaded (turn on Optimize iPhone Storage to try).
- [ ] Remove: the system confirmation appears and photos land in Recently Deleted. Cancel
      shows "Nothing removed."
- [ ] Copies: a favorite or edited copy is the one kept, and the kept copy joins the albums of
      the copies removed.
- [ ] The review notes' Copies path: a photo duplicated in Photos, with the duplicate's date
      moved a day earlier, shows up under Copies, not Similar Shots. If it doesn't, change
      step 1 of the notes before submitting.
- [ ] The review notes' Files path with brand-new files: first turn off "Files changed in the
      last 7 days" in Rules, or Duplicate Files and Large Files show nothing.
- [ ] Contacts: tapping Continue in Duplicate Contacts, or under Contacts in Rules, shows the
      Contacts prompt with its purpose string, and the app doesn't quit.
- [ ] Files: a folder in On My iPhone and one in iCloud Drive. Move to Holding is instant (a
      rename), "Held by Tidykeep" appears in the folder, Put back and Empty work, and the
      held folder isn't offered as duplicates on the next check.
- [ ] Contacts: use two test cards, not real ones. Merge, then Undo from History. The keeper's
      own note survives.
- [ ] Force-quit in the middle of a removal, reopen, and check History finishes the receipt.
- [ ] VoiceOver with Screen Curtain, the largest text size, Dark Mode, Increased Contrast,
      Reduce Motion.
- [ ] Airplane Mode: everything still works.
- [ ] An iPad, if you have one: App Review often runs iPhone-only apps there.

### Before the repo goes public

- [ ] The owner's own pre-release checks (kept outside this repo) are done. Until then the
      GitHub repo stays private.

## Review guidelines to keep in mind

- **4.3 Spam.** Photo tidy-up apps are a crowded category. Lead with what's different: nothing
  changes without the user, every change has a receipt, everything stays on the iPhone, it's
  free, and it's built for VoiceOver.
- **2.3.1 and 2.3.7 Accurate metadata.** No storage-saved figures for photos, no "clean" or
  "boost", no competitor names in keywords.
- **5.1.1 Data collection and storage.** Each permission is asked for when its feature starts,
  after a screen whose button says "Continue" (not "Allow"). Each has a purpose string that
  says what is read and what can change. Denying one leaves the rest working. No sign-in.
- **2.1 App completeness.** No placeholder text, no dead buttons, and it works on a fresh
  device. "All tidy" is the empty state.
- **What it can't do.** Never claim to clear caches, System Data, Messages attachments or other
  apps' data. The About section says so.

## Every release

- [ ] `scripts/test.sh` and `scripts/check-no-network.sh` pass.
- [ ] Every permission the app asks for has a purpose string in `App/Info.plist` (from
      `project.yml`), and each string still matches what the app does with that data.
- [ ] Walk the App Review notes on a fresh TestFlight install, step by step, and fix the
      notes wherever the build doesn't match them.
- [ ] Bump `CURRENT_PROJECT_VERSION`, and `MARKETING_VERSION` for user-visible changes, in
      `project.yml`, then `xcodegen generate`.
- [ ] If the analysis changed, the analyzer version changed too, so saved analysis is rebuilt.
- [ ] If the privacy policy changed, update `docs/PRIVACY.md`, `PrivacyPolicy.txt` and the
      hosted page together.
- [ ] New screenshots if any shown screen changed.
- [ ] Archive, upload, TestFlight on a real iPhone, then submit.
