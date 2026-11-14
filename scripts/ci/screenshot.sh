#!/bin/bash
# Saves what a booted simulator shows right now, as <out-folder>/<name>.png. For the
# moments no test is attaching screens: a hung test, a system alert nobody answered.
#
#   scripts/ci/screenshot.sh <udid> <out-folder> <name>
#
# Never fails the job: a missing screenshot shouldn't hide the real failure.
set -uo pipefail

udid="${1:?usage: screenshot.sh <udid> <out-folder> <name>}"
out="${2:?usage: screenshot.sh <udid> <out-folder> <name>}"
name="${3:?usage: screenshot.sh <udid> <out-folder> <name>}"

mkdir -p "$out"
if xcrun simctl io "$udid" screenshot --type=png "$out/$name.png" >/dev/null 2>&1; then
    echo "screenshot: $out/$name.png"
else
    echo "screenshot: couldn't take one of $udid (not booted?)" >&2
fi
exit 0
