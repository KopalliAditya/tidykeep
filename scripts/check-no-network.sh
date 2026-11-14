#!/bin/sh
# Fails if app code could reach the network. Tidykeep promises that photos never leave
# the device; this keeps that promise checkable. Run before every release.
set -eu
cd "$(dirname "$0")/.."

# Everything that can end up in the app. Targets only used by tests and the CLI are left out.
not_app="--exclude-dir=TidykeepFolderSource --exclude-dir=TidykeepTestSupport --exclude-dir=tkscan"
pattern='URLSession|URLRequest|NWConnection|NWPathMonitor|import Network|CFNetwork|CFStream'
pattern="$pattern"'|NetService|LPMetadataProvider|import LinkPresentation|import MapKit'
pattern="$pattern"'|WKWebView|import WebKit|SFSafariViewController|import SafariServices'
pattern="$pattern"'|AsyncImage|(^|[^A-Za-z])Link\(|ShareLink|UIActivityViewController|MFMailComposeViewController'
pattern="$pattern"'|CloudKit|CKContainer|NSUbiquitousKeyValueStore|import MultipeerConnectivity'
pattern="$pattern"'|isNetworkAccessAllowed *= *[^ f]|openURL|AVPlayer\(url: *URL\(string'
# Any URL with a scheme, web or not, and the links that hand off to Mail, Phone or Messages.
# Reading "mailto:" off a contact's email (ContactNormalizer) is fine: it opens nothing.
pattern="$pattern"'|[A-Za-z][A-Za-z0-9+.-]*://|URL\(string: *"(mailto|tel|sms):'

fail() { echo "check-no-network: $1" >&2; exit 1; }

# grep -r says nothing about a missing folder, so check they're there.
for dir in App TidykeepKit/Sources/TidykeepCore TidykeepKit/Sources/TidykeepUI; do
    [ -d "$dir" ] || fail "$dir not found"
done

# grep exits 0 on a match, 1 on none and 2 on an error (a missing folder, say).
status=0
grep -rnE "$pattern" App TidykeepKit/Sources --include='*.swift' $not_app || status=$?
case $status in
    0) fail "network-capable code found above" ;;
    1) ;;
    *) fail "grep failed (status $status)" ;;
esac

# Opening a URL hands it to another app, a browser included. The one call allowed opens
# Tidykeep's own page in the Settings app (openSettings in Design/Platform.swift).
settings_call='^TidykeepKit/Sources/TidykeepUI/Design/Platform\.swift:[0-9]+:[[:space:]]*UIApplication\.shared\.open\(url\)$'
status=0
opens="$(grep -rnE 'UIApplication\.shared\.open|\.open\(' App TidykeepKit/Sources --include='*.swift' $not_app)" || status=$?
case $status in
    0|1) ;;
    *) fail "grep failed (status $status)" ;;
esac
others="$(printf '%s\n' "$opens" | grep -vE "$settings_call" | grep -v '^$' || true)"
if [ -n "$others" ]; then
    printf '%s\n' "$others"
    fail "code that opens a URL found above (only the Settings call in Design/Platform.swift may)"
fi

status=0
grep -nE '\.package\(' TidykeepKit/Package.swift || status=$?
case $status in
    0) fail "third-party package dependency found above" ;;
    1) ;;
    *) fail "couldn't read TidykeepKit/Package.swift" ;;
esac

# The app's project: XcodeGen fetches a package given by url (or github), and Xcode
# fetches an XCRemoteSwiftPackageReference. Only the local TidykeepKit is allowed.
status=0
awk '/^packages:/ { inside = 1; next }
     /^[^[:space:]#]/ { inside = 0 }
     inside && /^[[:space:]]+(url|github):/ { print FILENAME ":" FNR ":" $0; found = 1 }
     END { exit found ? 0 : 1 }' project.yml || status=$?
case $status in
    0) fail "remote package in project.yml found above" ;;
    1) ;;
    *) fail "couldn't read project.yml" ;;
esac

status=0
grep -n 'XCRemoteSwiftPackageReference' Tidykeep.xcodeproj/project.pbxproj || status=$?
case $status in
    0) fail "remote package in Tidykeep.xcodeproj found above" ;;
    1) ;;
    *) fail "couldn't read Tidykeep.xcodeproj/project.pbxproj" ;;
esac

status=0
grep -rniE 'NSAppTransportSecurity|icloud|com\.apple\.developer\.' App --include='*.plist' --include='*.entitlements' || status=$?
case $status in
    0) fail "network or iCloud setting found in the app's plist or entitlements" ;;
    1) ;;
    *) fail "grep failed on App (status $status)" ;;
esac

echo "check-no-network: OK (no network APIs, no third-party packages, no network entitlements)"
