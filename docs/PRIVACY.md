# Tidykeep Privacy Policy

Last updated: November 14, 2026. Applies to Tidykeep 1.0 and later.

Tidykeep is made by Aditya Kopalli, an independent developer.

## The short version

Tidykeep collects no data. Everything it does happens on your iPhone. It has no account, no
ads, no analytics, no crash reporting and no tracking, and it contains no code that connects
to the internet. It works the same in Airplane Mode. The developer never receives your photos,
files, contacts or anything about them.

## Data collected

None. Tidykeep does not collect, sell, share or transmit any information, and it includes no
third-party code or services that could. The App Store privacy label for Tidykeep reads
"Data Not Collected".

## How Tidykeep works

All analysis runs on the iPhone's own processor, using Apple's Vision and Core ML frameworks
and a content model (DINOv2) that ships inside the app. Nothing is uploaded for processing.

Nothing is changed until you review it and confirm. Every change is recorded in History in
the app, with the way to undo it, or a note that it can't be undone.

## Photos

**Why Tidykeep asks for access.** To find similar shots, copies of the same photo,
screenshots and long videos, Tidykeep needs to look at the photos and videos in your library.
If you give access to only some photos, it looks at only those. If you don't give access,
the Photos part of the app stays off; Files and Contacts still work. You can change or turn
off Photos access at any time in Settings > Apps > Tidykeep.

**What it reads.** Each photo's pixels and details such as date, size in pixels, format,
favorite status and albums. Photos and videos stored only in iCloud are skipped. Tidykeep
never downloads them.

**Faces.** To prefer a frame where nobody blinked, Tidykeep asks Vision for a face capture
quality score: one number for each face in a photo. It does not recognize or identify people,
and it does not store face images or face geometry.

**What it stores.** A compact numeric analysis of each photo it has checked (fingerprints and
quality scores), so photos aren't analyzed twice. No copies of your photos are made or kept.

**Changes to your library.** Tidykeep removes or merges photos only when you confirm, and
iOS asks you to confirm again. Removed photos go to Recently Deleted in the Photos app, where
you can recover them for 30 days. If iCloud Photos is on, a removed photo is also removed from
your other devices, and a photo in a Shared Library is removed for everyone in it. When you
merge copies, favorites and edited copies are never removed, and the photo you keep is added
to the albums of the copies removed.

## Files

**What it reads.** Only folders you choose with the iOS folder picker. Tidykeep reads file
names, sizes, dates and contents in those folders to find exact duplicates (by comparing the
files' contents on the iPhone) and large files. Files stored only in iCloud Drive are skipped,
never downloaded. To open your folders again next time, Tidykeep keeps a bookmark to each one,
which you can remove in Rules.

**Holding.** "Move to Holding" moves a file into a folder named "Held by Tidykeep" inside the
folder you chose. The file stays on the same drive or service until you put it back or delete
it. Because that folder is yours, not the app's, deleting Tidykeep leaves it and its files in
place.

## Contacts

**Why Tidykeep asks for access.** To find cards for the same person, Tidykeep compares
names, phone numbers and email addresses on this iPhone. It asks for access only when you tap
Continue in Duplicate Contacts or under Contacts in Rules. You can turn off Contacts access at
any time in Settings > Apps > Tidykeep.

**Backup before every merge.** Before it merges cards, Tidykeep saves a backup of the cards
involved (a vCard file) in its own storage on the iPhone. Undo uses this backup. iOS doesn't
let Tidykeep read contact notes, so notes are not part of the backup, and Tidykeep asks you to
confirm every merge for that reason. Cards are merged only within the same account. A
backup is kept as long as the History receipt of its merge, so Undo keeps working, and is
deleted with that receipt: after a year, or sooner if you clear History. Delete backups,
under Contacts in Rules, deletes them all at once; past merges can't be undone after that.

## History and Rules

**History receipts** record what changed: counts, dates, pixel sizes, file names and byte
counts. A contact merge's receipt holds only the contact's name and the cards' IDs. The
details of the merged cards are kept next to that merge's contact backup, not in History,
and are deleted with it: by Delete backups, or when the receipt goes. Receipts never contain
images, and they stay in the app's own storage. History keeps each receipt for one year,
then deletes it.

**Rules and settings** (what to always keep, what to look at, haptics) are saved as ordinary
app preferences on the iPhone.

## Where your data lives, and how to delete it

Everything Tidykeep stores (the photo analysis, History receipts, contact backups, folder
bookmarks, the list of files in Holding, photos you chose to keep, contact cards you chose to
keep apart, and preferences) is kept in the app's own storage on your iPhone. You can clear
the analysis at any time in Rules, under Saved Data, and clear History there too, which also
deletes the contact backups (and so the Undo) of past merges. Folder bookmarks are removed in
Rules. Deleting the app deletes all of it.

Turning off Photos or Contacts access in Settings > Apps > Tidykeep stops Tidykeep from
reading them. What it has already stored stays until you clear it or delete the app, and it
is never sent anywhere.

Tidykeep leaves its own data (the photo analysis, History receipts, contact backups, folder
bookmarks, the Holding list and what you chose to keep) out of iPhone backups, so it isn't
restored to a new iPhone. Only Rules and settings, saved as app preferences, are part of a
backup. Tidykeep never reads or sends your iPhone backups.

## Children

Tidykeep collects no data from anyone, including children.

## Changes to this policy

If this policy changes, the new version will be posted here with a new date before the app
changes.

## Contact

Questions about privacy: support@tidykeep.app
