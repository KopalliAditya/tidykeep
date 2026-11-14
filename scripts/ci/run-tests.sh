#!/bin/bash
# Runs some of the already built tests on the CI simulator, into <results>/<name>.xcresult.
#
#   scripts/ci/run-tests.sh <name> <test target or identifier>... [-- <xcodebuild args>]
#
# Each name after <name> becomes -only-testing:<it>. Everything in the environment named
# TK_* reaches the tests too (xcodebuild hands TEST_RUNNER_<name> to the test process as
# <name>), so the tests can read TK_SEED_FIRST and friends from ProcessInfo.
#
# Env:
#   SIM_UDID       the simulator (pick-simulator.sh)
#   RESULTS, LOGS  folders for the result bundle and the full xcodebuild log
#   DERIVED_DATA   the -derivedDataPath the build used (optional)
#   PROJECT, SCHEME
set -euo pipefail

name="${1:?usage: run-tests.sh <name> <test>... [-- <xcodebuild args>]}"
shift
only=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    only+=("-only-testing:$1")
    shift
done
if [ "$#" -gt 0 ]; then shift; fi  # the --
[ "${#only[@]}" -gt 0 ] || { echo "run-tests: name at least one test target" >&2; exit 2; }

: "${SIM_UDID:?run pick-simulator.sh first}"
results="${RESULTS:?}"
logs="${LOGS:?}"
mkdir -p "$results" "$logs"
rm -rf "$results/$name.xcresult"

for var in $(env | sed -n 's/^\(TK_[A-Z0-9_]*\)=.*/\1/p'); do
    export "TEST_RUNNER_$var=${!var}"
done

derived=()
if [ -n "${DERIVED_DATA:-}" ]; then
    derived=(-derivedDataPath "$DERIVED_DATA")
fi

if command -v xcbeautify >/dev/null 2>&1; then
    pretty() { xcbeautify --renderer github-actions; }
else
    pretty() { cat; }
fi

start=$(date +%s)
status=0
# Parallel testing would run the tests on clones of the simulator, which have neither the
# seeded photos nor the granted access.
xcodebuild test-without-building \
    -project "${PROJECT:-Tidykeep.xcodeproj}" \
    -scheme "${SCHEME:-Tidykeep}" \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -destination-timeout 180 \
    ${derived[@]+"${derived[@]}"} \
    -resultBundlePath "$results/$name.xcresult" \
    -parallel-testing-enabled NO \
    "${only[@]}" \
    "$@" \
    2>&1 | tee "$logs/$name.log" | pretty || status=$?
echo "run-tests: $name took $(( $(date +%s) - start ))s (exit $status)"
exit "$status"
