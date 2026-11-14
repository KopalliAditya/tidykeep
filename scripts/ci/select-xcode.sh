#!/bin/bash
# Selects the newest installed Xcode 26 release and checks it has the iOS 26 SDK.
#
#   scripts/ci/select-xcode.sh
#
# Looks at /Applications/Xcode_26*.app (the GitHub macOS images' naming) and plain
# /Applications/Xcode.app, skips betas and release candidates, and picks the highest version.
# Tidykeep builds against the iOS 26 SDK and must not use iOS 27 API, so an Xcode whose
# simulator SDK isn't 26.x stops the job with an error saying so.
#
# Env:
#   XCODE_PIN      a version to use instead, like 26.5 or 26.4 (26.4.1 matches; must be installed)
#   XCODE_MAJOR    the major version to look for (default 26)
# When GITHUB_ENV is set, exports DEVELOPER_DIR, XCODE_VERSION and IOS_SDK for later steps.
set -euo pipefail

major="${XCODE_MAJOR:-26}"
pinned="${XCODE_PIN:-}"

version_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true
}

# "<sort key>\t<version>\t<path>" for every release Xcode of the wanted major version.
candidates() {
    local app v a b c
    for app in /Applications/Xcode_"$major"*.app /Applications/Xcode.app; do
        [ -d "$app/Contents/Developer" ] || continue
        case "$(basename "$app")" in
            *beta*|*Beta*|*_RC*|*-RC*|*Release_Candidate*) continue ;;
        esac
        v="$(version_of "$app")"
        case "$v" in
            "$major"|"$major".*)
                IFS=. read -r a b c _ <<EOF_VERSION
$v
EOF_VERSION
                printf '%03d%03d%03d\t%s\t%s\n' "${a:-0}" "${b:-0}" "${c:-0}" "$v" "$app" ;;
        esac
    done
}

list="$(candidates | sort -k1,1 | cut -f2-)"
if [ -z "$list" ]; then
    echo "::error::select-xcode: no Xcode $major release in /Applications. Installed:" >&2
    ls -d /Applications/Xcode*.app >&2 2>/dev/null || true
    exit 1
fi

if [ -n "$pinned" ]; then
    # A pin matches the version itself, any point release of it (26.4 matches 26.4.1, as
    # Xcode_26.4.app reports), or the app's folder name; the newest match wins. Compared as
    # strings: awk would otherwise call 26.1 and 26.10 equal.
    pick="$(printf '%s\n' "$list" | awk -F'\t' -v v="$pinned" '{
        version = "" $1; folder = $2; sub(/.*\//, "", folder)
        if (version == "" v || index(version, v ".") == 1 || folder == "Xcode_" v ".app") print
    }' | tail -n 1)"
    if [ -z "$pick" ]; then
        echo "::error::select-xcode: Xcode $pinned isn't installed. Have: $(printf '%s\n' "$list" | awk -F'\t' '{ folder = $2; sub(/.*\//, "", folder); printf "%s (%s) ", $1, folder }')" >&2
        exit 1
    fi
else
    pick="$(printf '%s\n' "$list" | tail -n 1)"
fi
version="$(printf '%s' "$pick" | cut -f1)"
app="$(printf '%s' "$pick" | cut -f2)"
developer="$app/Contents/Developer"

if [ "$(id -u)" = 0 ] || ! command -v sudo >/dev/null 2>&1; then
    xcode-select -s "$developer"
else
    sudo xcode-select -s "$developer"
fi
export DEVELOPER_DIR="$developer"

sdk="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || true)"
case "$sdk" in
    "$major".*|"$major") ;;
    "")
        echo "::error::select-xcode: Xcode $version at $app has no iOS Simulator SDK. Tidykeep needs the iOS $major SDK." >&2
        exit 1 ;;
    *)
        echo "::error::select-xcode: Xcode $version has iOS Simulator SDK $sdk, not iOS $major. Tidykeep builds against the iOS $major SDK only (no iOS $((major + 1)) API)." >&2
        exit 1 ;;
esac

echo "select-xcode: Xcode $version ($app), iOS Simulator SDK $sdk"
xcodebuild -version
swift --version 2>&1 | head -n 1
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "DEVELOPER_DIR=$developer"
        echo "XCODE_VERSION=$version"
        echo "IOS_SDK=$sdk"
    } >> "$GITHUB_ENV"
fi
