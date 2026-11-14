#!/bin/bash
# Installs a pinned XcodeGen release, checked against its SHA-256, and puts it on PATH.
#
#   scripts/ci/install-xcodegen.sh
#
# The runner images don't include XcodeGen, and Homebrew would install whatever is newest.
# A pinned release generates the same project every run.
#
# Env:
#   XCODEGEN_VERSION  release tag (default below)
#   XCODEGEN_SHA256   SHA-256 of that release's xcodegen.zip; change both together
# When GITHUB_PATH is set, later steps find xcodegen on PATH.
set -euo pipefail

version="${XCODEGEN_VERSION:-2.46.0}"
sha256="${XCODEGEN_SHA256:-4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806}"
root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xcodegen-$version"
url="https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"

if [ ! -x "$root/xcodegen/bin/xcodegen" ]; then
    rm -rf "$root"
    mkdir -p "$root"
    curl -fsSL --retry 3 --retry-delay 5 -o "$root/xcodegen.zip" "$url"
    actual="$(shasum -a 256 "$root/xcodegen.zip" | cut -d ' ' -f 1)"
    if [ "$actual" != "$sha256" ]; then
        echo "install-xcodegen: checksum mismatch for $url" >&2
        echo "  expected $sha256" >&2
        echo "  got      $actual" >&2
        exit 1
    fi
    # bin/xcodegen finds its setting presets in ../share, so keep the layout.
    unzip -q "$root/xcodegen.zip" -d "$root"
fi

"$root/xcodegen/bin/xcodegen" --version
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$root/xcodegen/bin" >> "$GITHUB_PATH"
fi
