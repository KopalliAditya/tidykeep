#!/bin/bash
# Copies the screenshots and other attachments out of a test result bundle, with readable
# names: "03-group.png" rather than "03-group_0_6F1C...-....png". Attachments kept
# because a test failed get a FAILED- prefix.
#
#   scripts/ci/export-attachments.sh <result.xcresult> <out-folder>
#
# Uses `xcrun xcresulttool export attachments` (Xcode 16 and later). A missing or empty
# result bundle isn't an error: the step that should have made it already failed.
set -euo pipefail

result="${1:?usage: export-attachments.sh <result.xcresult> <out-folder>}"
out="${2:?usage: export-attachments.sh <result.xcresult> <out-folder>}"

if [ ! -d "$result" ]; then
    echo "export-attachments: no result bundle at $result"
    exit 0
fi

raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT
mkdir -p "$out"

if ! xcrun xcresulttool export attachments --path "$result" --output-path "$raw" >/dev/null; then
    echo "export-attachments: xcresulttool couldn't export from $result" >&2
    exit 0
fi

if [ ! -f "$raw/manifest.json" ]; then
    cp -R "$raw/." "$out/"
    echo "export-attachments: no manifest; copied $(find "$out" -type f | wc -l | tr -d ' ') files as they are"
    exit 0
fi

# One line per attachment: exported file, suggested name, 1 if kept for a failure. The
# fields are split on the unit separator, not tabs, so an empty one stays in place.
# Field names as `xcrun xcresulttool help export attachments` describes manifest.json.
sep=$'\037'
count=0
while IFS="$sep" read -r file name failed; do
    [ -f "$raw/$file" ] || continue
    [ -n "$name" ] || name="$file"
    # Drop the "_<index>_<UUID>" xcresulttool adds before the extension, and any slashes.
    clean="$(printf '%s' "$name" | sed -E 's/_[0-9]+_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(\.[A-Za-z0-9]+)$/\2/' | tr '/:' '--')"
    [ "$failed" = "1" ] && clean="FAILED-$clean"
    target="$out/$clean"
    n=2
    while [ -e "$target" ]; do
        case "$clean" in
            *.*) target="$out/${clean%.*}-$n.${clean##*.}" ;;
            *) target="$out/$clean-$n" ;;
        esac
        n=$((n + 1))
    done
    cp "$raw/$file" "$target"
    count=$((count + 1))
done < <(jq -r --arg sep "$sep" '
    .[] | .attachments[]?
    | [.exportedFileName, (.suggestedHumanReadableName // ""), (if .isAssociatedWithFailure == true then "1" else "0" end)]
    | join($sep)' "$raw/manifest.json")

cp "$raw/manifest.json" "$out/attachments-manifest.json"
echo "export-attachments: $count attachments from $(basename "$result") to $out"
