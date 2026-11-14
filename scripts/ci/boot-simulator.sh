#!/bin/bash
# Boots a simulator, waits until it's ready and sets it up for repeatable screenshots.
# Fine to run when it's already booted.
#
#   scripts/ci/boot-simulator.sh <udid>
#
# Boot after building, not during: a just-booted simulator starts hundreds of background
# services that slow a build down several times over on a 3-core runner.
set -euo pipefail

udid="${1:?usage: boot-simulator.sh <udid>}"
start=$(date +%s)

xcrun simctl boot "$udid" 2>/dev/null || true   # fails if it's booted already
xcrun simctl bootstatus "$udid" -b
echo "boot-simulator: $udid ready after $(( $(date +%s) - start ))s"

# 9:41, full battery and signal, light appearance: screenshots differ only where the app does.
xcrun simctl status_bar "$udid" override \
    --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 \
    || echo "boot-simulator: status bar override not available" >&2
xcrun simctl ui "$udid" appearance light || true
