#!/bin/sh
# Runs the package tests on a Mac. Works with full Xcode or with only the Command Line
# Tools, which keep the swift-testing macro plugin where SwiftPM doesn't look for it.
set -eu
cd "$(dirname "$0")/../GoodTakeKit"

plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
else
    exec swift test "$@"
fi
