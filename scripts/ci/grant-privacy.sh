#!/bin/bash
# Grants an app privacy access on a simulator, so no test ever waits on a prompt.
#
#   scripts/ci/grant-privacy.sh <udid> <bundle-id> <service>...
#
# <service> is any name `xcrun simctl privacy` takes: photos, contacts, calendar, ...
# A service that's already allowed is left alone (the UI tests may have answered the real
# prompt, and granting again would replace that row).
#
# Photos: on recent runtimes `simctl privacy grant photos` writes a row (auth_version 1)
# that tccd reads as "not determined", so the app sees no access. Reported for Xcode 26.6
# with the iOS 26.4 runtime:
#   https://github.com/hawkeye-xb/P-Pass/blob/8550a796e5d4318b20d2ca5947243d53b1cd7acd/apps/ios/Packages/PPassMedia/scripts/sim-photos-auth.sh
# So after granting photos this sets auth_version to 2 in the simulator's own TCC.db
# (CoreSimulator/Devices/<udid>/...), never the Mac's. PATCH_PHOTOS_TCC=0 skips that.
# The app sees the change the next time it launches; each test run launches it afresh.
set -euo pipefail

udid="${1:?usage: grant-privacy.sh <udid> <bundle-id> <service>...}"
bundle="${2:?usage: grant-privacy.sh <udid> <bundle-id> <service>...}"
shift 2
[ "$#" -gt 0 ] || { echo "grant-privacy: name at least one service" >&2; exit 2; }

db="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"
case "$bundle" in
    *[!A-Za-z0-9.-]*) echo "grant-privacy: unexpected bundle id $bundle" >&2; exit 2 ;;
esac

tcc_service() {
    case "$1" in
        photos) echo kTCCServicePhotos ;;
        photos-add) echo kTCCServicePhotosAdd ;;
        contacts) echo kTCCServiceAddressBook ;;
        calendar) echo kTCCServiceCalendar ;;
        reminders) echo kTCCServiceReminders ;;
        *) echo "" ;;
    esac
}

# "<auth_value>,<auth_version>" for the app's row, or nothing.
row() {
    [ -f "$db" ] || return 0
    sqlite3 -readonly "$db" \
        "SELECT auth_value || ',' || auth_version FROM access WHERE service = '$1' AND client = '$bundle';" \
        2>/dev/null || true
}

for service in "$@"; do
    key="$(tcc_service "$service")"
    current=""
    [ -n "$key" ] && current="$(row "$key")"
    case "$service,$current" in
        photos,2,2|photos,3,2)
            echo "grant-privacy: $service already allowed ($current)"; continue ;;
        photos,*) ;;
        *,2,*|*,3,*)
            echo "grant-privacy: $service already allowed ($current)"; continue ;;
    esac

    xcrun simctl privacy "$udid" grant "$service" "$bundle"

    if [ "$service" = photos ] && [ "${PATCH_PHOTOS_TCC:-1}" != 0 ]; then
        [ -f "$db" ] || { echo "grant-privacy: no TCC.db at $db" >&2; exit 1; }
        sqlite3 "$db" "UPDATE access SET auth_version = 2 WHERE service = 'kTCCServicePhotos' AND client = '$bundle' AND auth_value = 2;"
    fi
    echo "grant-privacy: $service granted to $bundle (${key:-?} row: $(row "${key:-none}"))"
done
