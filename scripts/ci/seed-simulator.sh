#!/bin/bash
# Fills a booted simulator's photo library with the seed photos and videos.
#
#   scripts/ci/seed-simulator.sh <udid> <seed-folder>
#
# <seed-folder> is what make-seed-media.swift wrote: JPEG, HEIC and PNG photos and .mov
# videos, plus seed.json describing them. Photos takes each photo's capture date from its
# EXIF and each video's from its QuickTime metadata, so the bursts keep their seconds-apart
# timing and the re-saved copies come after their originals.
#
# Contacts and files aren't seeded here: the app makes its own sample files and contact
# cards when launched with -TKSeedFiles YES and -TKSeedContacts YES, and TidykeepAppTests
# makes up (and removes) its own cards.
#
# Simulator only: refuses a udid that isn't a booted simulator on this Mac.
# When GITHUB_ENV is set, exports TK_SEED_PHOTOS, TK_SEED_SCREENSHOTS, TK_SEED_VIDEOS,
# TK_SEED_BURSTS, TK_SEED_COPY_SETS, TK_SEED_SOURCE, TK_SEED_FIRST and TK_SEED_LAST from
# seed.json, so the tests know what to expect (run-tests.sh passes TK_* through). Also
# TK_SEED_NAMES (every seeded photo), TK_SEED_KEEPERS (each burst's sharp frame and each copy
# set's original, which no flow may remove) and TK_SEED_EXTRAS (what the app may offer to
# remove): file names, comma-separated (the seed's names have no commas).
set -euo pipefail

udid="${1:?usage: seed-simulator.sh <udid> <seed-folder>}"
seed="${2:?usage: seed-simulator.sh <udid> <seed-folder>}"

state="$(xcrun simctl list -j devices | jq -r --arg u "$udid" '[.devices[][] | select(.udid == $u) | .state][0] // empty')"
case "$state" in
    Booted) ;;
    "") echo "seed-simulator: no simulator with udid $udid" >&2; exit 1 ;;
    *) echo "seed-simulator: $udid is $state; boot it first (boot-simulator.sh)" >&2; exit 1 ;;
esac

collect() {
    find "$seed" -maxdepth 1 -type f \( "$@" \) | sort
}

photos=()
while IFS= read -r file; do
    photos+=("$file")
done < <(collect -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png')
videos=()
while IFS= read -r file; do
    videos+=("$file")
done < <(collect -iname '*.mov' -o -iname '*.mp4')
[ "${#photos[@]}" -gt 0 ] || { echo "seed-simulator: no photos in $seed" >&2; exit 1; }

start=$(date +%s)
xcrun simctl addmedia "$udid" "${photos[@]}"
if [ "${#videos[@]}" -gt 0 ]; then
    xcrun simctl addmedia "$udid" "${videos[@]}"
fi
echo "seed-simulator: added ${#photos[@]} photos and ${#videos[@]} videos to $udid in $(( $(date +%s) - start ))s"

if [ -f "$seed/seed.json" ]; then
    jq -r '"seed-simulator: \(.photos) photos (\(.bursts) bursts, \(.copySets) copy sets, \(.screenshots) screenshots), \(.videos) videos, \(.first) to \(.last), from \(.source)"' "$seed/seed.json"
    if [ -n "${GITHUB_ENV:-}" ]; then
        jq -r '
            "TK_SEED_PHOTOS=\(.photos)", "TK_SEED_SCREENSHOTS=\(.screenshots)", "TK_SEED_VIDEOS=\(.videos)",
            "TK_SEED_BURSTS=\(.bursts)", "TK_SEED_COPY_SETS=\(.copySets)", "TK_SEED_SOURCE=\(.source)",
            "TK_SEED_FIRST=\(.first)", "TK_SEED_LAST=\(.last)",
            "TK_SEED_NAMES=\(.names // [] | join(","))", "TK_SEED_KEEPERS=\(.keepers // [] | join(","))",
            "TK_SEED_EXTRAS=\(.extras // [] | join(","))"' "$seed/seed.json" >> "$GITHUB_ENV"
    fi
fi
