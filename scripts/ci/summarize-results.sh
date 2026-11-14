#!/bin/bash
# Prints a Markdown summary of test result bundles: one row each, then the failures.
#
#   scripts/ci/summarize-results.sh <result.xcresult>... >> "$GITHUB_STEP_SUMMARY"
#
# Bundles are listed in the order given; a missing one shows as "not run". Never fails, so
# it can run after anything. Field names from the schema that
# `xcrun xcresulttool help get test-results summary` prints.
set -uo pipefail

echo "| Tests | Result | Passed | Failed | Skipped | Took |"
echo "|---|---|---:|---:|---:|---:|"

failures="$(mktemp)"
trap 'rm -f "$failures"' EXIT

for result in "$@"; do
    phase="$(basename "$result" .xcresult)"
    if [ ! -d "$result" ]; then
        echo "| $phase | not run | | | | |"
        continue
    fi
    if ! json="$(xcrun xcresulttool get test-results summary --path "$result" --compact 2>/dev/null)"; then
        echo "| $phase | unreadable | | | | |"
        continue
    fi
    printf '%s' "$json" | jq -r --arg phase "$phase" '
        def took: if (.startTime | type) == "number" and (.finishTime | type) == "number"
                  then "\((.finishTime - .startTime) | floor)s" else "" end;
        "| \($phase) | \(.result // "?") | \(.passedTests // 0) | \(.failedTests // 0) | \((.skippedTests // 0) + (.expectedFailures // 0)) | \(took) |"'
    printf '%s' "$json" | jq -r --arg phase "$phase" '
        (.testFailures // [])[:10][]
        | "- \($phase): \(.targetName // "") \(.testName // ""): \((.failureText // "") | gsub("\\s+"; " ") | .[0:300])"' >> "$failures"
done

if [ -s "$failures" ]; then
    echo
    echo "**Failures** (first 10 per bundle)"
    echo
    cat "$failures"
fi
exit 0
