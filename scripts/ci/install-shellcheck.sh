#!/bin/bash
# Installs a pinned ShellCheck release, checked against its SHA-256, and puts it on PATH.
#
#   scripts/ci/install-shellcheck.sh
#
# The macOS runner images don't include ShellCheck, so without this the lint step would
# quietly do nothing. A pinned release reports the same findings every run.
#
# Env:
#   SHELLCHECK_VERSION  release tag (default below)
#   SHELLCHECK_SHA256   SHA-256 of that release's darwin.aarch64 tarball; change both together
# When GITHUB_PATH is set, later steps find shellcheck on PATH.
set -euo pipefail

version="${SHELLCHECK_VERSION:-v0.11.0}"
sha256="${SHELLCHECK_SHA256:-56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79}"
root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/shellcheck-$version"

# Only the Apple silicon build is pinned: the macos-26 runners are arm64.
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) platform=darwin.aarch64 ;;
    *)
        echo "install-shellcheck: no pinned build for $(uname -s)/$(uname -m)" >&2
        exit 1 ;;
esac
tarball="shellcheck-$version.$platform.tar.xz"
url="https://github.com/koalaman/shellcheck/releases/download/$version/$tarball"

if [ ! -x "$root/shellcheck-$version/shellcheck" ]; then
    rm -rf "$root"
    mkdir -p "$root"
    curl -fsSL --retry 3 --retry-delay 5 -o "$root/$tarball" "$url"
    actual="$(shasum -a 256 "$root/$tarball" | cut -d ' ' -f 1)"
    if [ "$actual" != "$sha256" ]; then
        echo "install-shellcheck: checksum mismatch for $url" >&2
        echo "  expected $sha256" >&2
        echo "  got      $actual" >&2
        exit 1
    fi
    tar -xf "$root/$tarball" -C "$root"
fi

"$root/shellcheck-$version/shellcheck" --version
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$root/shellcheck-$version" >> "$GITHUB_PATH"
fi
