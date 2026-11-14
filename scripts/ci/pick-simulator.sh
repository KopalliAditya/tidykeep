#!/bin/bash
# Picks the iPhone simulator to test on and prints "<udid> <name> (iOS <version>)".
#
#   scripts/ci/pick-simulator.sh
#
# Only runtimes of the SDK's major version (iOS 26 with Xcode 26) and no newer than the SDK.
# In order: an iPhone that's already booted; else, on the newest of those runtimes, the
# first model named in SIM_PREFERENCE, else any other Pro Max, else any iPhone there; else a
# new simulator of the first preferred model on that runtime; else the best iPhone on an
# older runtime of that major version. Foldable models are skipped.
#
# Env:
#   SIM_PREFERENCE  models, best first, comma-separated (default below)
#   SIM_OS          an iOS version to require instead, like 26.5
#   SIM_OS_MAJOR    the iOS major version to require (default: the SDK's)
# When GITHUB_ENV is set, also exports SIM_UDID, SIM_NAME and SIM_OS for later steps.
set -euo pipefail

preference="${SIM_PREFERENCE:-iPhone 17 Pro Max,iPhone 16 Pro Max,iPhone 17 Pro,iPhone Air,iPhone 17}"
want="${SIM_OS:-}"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
major="${SIM_OS_MAJOR:-${sdk%%.*}}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun simctl list -j devices available > "$work/devices.json"
xcrun simctl list -j runtimes available > "$work/runtimes.json"

# Runtimes that fit, newest first: "<identifier>\t<version>".
jq -r --arg sdk "$sdk" --arg want "$want" --arg major "$major" '
  def ver: split(".") | map(tonumber? // 0) | (. + [0, 0, 0])[0:3];
  [.runtimes[]
    | select(((.platform // "") == "iOS" or (.identifier | test("SimRuntime[.]iOS-"))) and .isAvailable != false)
    | select((.version | split(".")[0]) == $major)
    | select(if $want != "" then (.version == $want or (.version | startswith($want + "."))) else ((.version | ver) <= ($sdk | ver)) end)]
  | sort_by(.version | ver) | reverse | .[] | "\(.identifier)\t\(.version)"
' "$work/runtimes.json" > "$work/runtimes.tsv"

if [ ! -s "$work/runtimes.tsv" ]; then
    echo "::error::pick-simulator: no iOS $major runtime fits SDK $sdk${want:+ and iOS $want}. Installed:" >&2
    xcrun simctl list runtimes >&2
    exit 1
fi

# Every available iPhone on those runtimes:
#   "<udid>\t<name>\t<version>\t<state>\t<rank>\t<order>"
# rank: 0 booted, 1.. position in SIM_PREFERENCE, 50 other Pro Max, 90 other iPhone,
# 99 foldable.
# order: 0 on the newest runtime, 1 on the next newest, and so on.
jq -r --rawfile runtimes "$work/runtimes.tsv" --arg pref "$preference" '
  ($pref | split(",") | map(sub("^ +"; "") | sub(" +$"; ""))) as $names
  | ($runtimes | split("\n") | map(select(length > 0) | split("\t"))) as $rts
  | . as $root
  | $rts | to_entries[] | .key as $order | .value as [$id, $version]
  | ($root.devices[$id] // [])[]
  | select(.isAvailable != false and (.name | startswith("iPhone")))
  | (.name as $n | ($names | index($n))) as $p
  | (if .state == "Booted" then 0
     elif $p != null then $p + 1
     elif (.name | test("Duo|Fold|Flip")) then 99
     elif (.name | test("Pro Max")) then 50
     else 90 end) as $rank
  | "\(.udid)\t\(.name)\t\($version)\t\(.state)\t\($rank)\t\($order)"
' "$work/devices.json" > "$work/phones.tsv"

# A booted iPhone wins. Otherwise the best-ranked iPhone on the newest runtime.
usable="$(awk -F'\t' '$5 != 99' "$work/phones.tsv")"
best="$(printf '%s\n' "$usable" | awk -F'\t' '$5 == 0' | head -n 1)"
if [ -z "$best" ]; then
    best="$(printf '%s\n' "$usable" | awk -F'\t' '$6 == 0' | sort -t$'\t' -k5,5n | head -n 1)"
fi

create() {
    # A new simulator of the first preferred model on the newest runtime.
    local runtime_id type_name type_id
    runtime_id="$(head -n 1 "$work/runtimes.tsv" | cut -f1)"
    type_name="${preference%%,*}"
    type_id="$(xcrun simctl list -j devicetypes | jq -r --arg n "$type_name" '.devicetypes[] | select(.name == $n) | .identifier' | head -n 1)"
    [ -n "$type_id" ] || return 1
    udid="$(xcrun simctl create "CI $type_name" "$type_id" "$runtime_id")" || return 1
    name="CI $type_name"
    os="$(head -n 1 "$work/runtimes.tsv" | cut -f2)"
}

if [ -n "$best" ]; then
    udid="$(printf '%s' "$best" | cut -f1)"
    name="$(printf '%s' "$best" | cut -f2)"
    os="$(printf '%s' "$best" | cut -f3)"
elif ! create; then
    # Can't make one: the best iPhone on an older runtime, if any.
    best="$(printf '%s\n' "$usable" | sort -t$'\t' -k6,6n -k5,5n | awk 'NF' | head -n 1)"
    [ -n "$best" ] || { echo "pick-simulator: no iPhone simulator to use or create" >&2; exit 1; }
    udid="$(printf '%s' "$best" | cut -f1)"
    name="$(printf '%s' "$best" | cut -f2)"
    os="$(printf '%s' "$best" | cut -f3)"
fi

echo "$udid $name (iOS $os)"
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "SIM_UDID=$udid"
        echo "SIM_NAME=$name"
        echo "SIM_OS=$os"
    } >> "$GITHUB_ENV"
fi
