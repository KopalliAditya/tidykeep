#!/bin/sh
# Fails if app code could reach the network. Good Take promises that photos never leave
# the device; this keeps that promise checkable. Run before every release.
set -eu
cd "$(dirname "$0")/.."

# Everything that can end up in the app. Targets only used by tests and the CLI are left out.
not_app="--exclude-dir=GoodTakeFolderSource --exclude-dir=GoodTakeTestSupport --exclude-dir=gtscan"
pattern='URLSession|URLRequest|NWConnection|NWPathMonitor|import Network|CFNetwork|CFStream'
pattern="$pattern"'|WKWebView|import WebKit|SFSafariViewController|import SafariServices'
pattern="$pattern"'|AsyncImage|(^|[^A-Za-z])Link\(|ShareLink|UIActivityViewController|MFMailComposeViewController'
pattern="$pattern"'|CloudKit|CKContainer|NSUbiquitousKeyValueStore|import MultipeerConnectivity'
pattern="$pattern"'|isNetworkAccessAllowed *= *[^ f]|https?://'

fail() { echo "check-no-network: $1" >&2; exit 1; }

# grep -r says nothing about a missing folder, so check they're there.
for dir in App GoodTakeKit/Sources/GoodTakeCore GoodTakeKit/Sources/GoodTakeUI; do
    [ -d "$dir" ] || fail "$dir not found"
done

# grep exits 0 on a match, 1 on none and 2 on an error (a missing folder, say).
status=0
grep -rnE "$pattern" App GoodTakeKit/Sources --include='*.swift' $not_app || status=$?
case $status in
    0) fail "network-capable code found above" ;;
    1) ;;
    *) fail "grep failed (status $status)" ;;
esac

status=0
grep -nE 'package\((url|id):' GoodTakeKit/Package.swift || status=$?
case $status in
    0) fail "third-party package dependency found above" ;;
    1) ;;
    *) fail "couldn't read GoodTakeKit/Package.swift" ;;
esac

status=0
grep -rniE 'NSAppTransportSecurity|icloud|com\.apple\.developer\.' App --include='*.plist' --include='*.entitlements' || status=$?
case $status in
    0) fail "network or iCloud setting found in the app's plist or entitlements" ;;
    1) ;;
    *) fail "grep failed on App (status $status)" ;;
esac

echo "check-no-network: OK (no network APIs, no third-party packages, no network entitlements)"
