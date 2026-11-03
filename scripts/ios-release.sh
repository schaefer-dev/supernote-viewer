#!/bin/bash
# Archives the iOS app and uploads it to App Store Connect (TestFlight), signed automatically
# with an App Store Connect API key.
#
#   scripts/ios-release.sh              # test, archive, upload
#   scripts/ios-release.sh --no-upload  # test and archive only (build/ios-release/Sumi.xcarchive)
#   scripts/ios-release.sh --skip-tests
#
# Needs in the environment or .env (never committed):
#   ASC_KEY_ID      App Store Connect API key ID
#   ASC_ISSUER_ID   Issuer ID shown above the key list
#   ASC_KEY_PATH    Path to AuthKey_<id>.p8 (default ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8)
#   DROPBOX_APP_KEY Dropbox app key (via scripts/prepare-ios.py → Local.xcconfig, or Base.xcconfig)
#
# The build number is the commit count, so every upload from a new commit is higher than the last.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env-value.sh

UPLOAD=1; TESTS=1
for arg in "$@"; do
    case "$arg" in
        --no-upload) UPLOAD=0 ;;
        --skip-tests) TESTS=0 ;;
        *) echo "Usage: $0 [--no-upload] [--skip-tests]" >&2; exit 1 ;;
    esac
done

SCHEME=SupernoteViewerIOS
BUNDLE_ID=dev.schaefer.Sumi
OUT=build/ios-release
ARCHIVE="$OUT/Sumi.xcarchive"

if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree has uncommitted changes. Commit or stash them first, so the build matches a commit." >&2
    exit 1
fi

AUTH=()
KEY_ID="$(env_value ASC_KEY_ID)"; ISSUER="$(env_value ASC_ISSUER_ID)"
if [ -n "$KEY_ID" ] && [ -n "$ISSUER" ]; then
    KEY_PATH="$(env_value ASC_KEY_PATH)"
    KEY_PATH="$(resolve_path "${KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}")"
    [ -f "$KEY_PATH" ] || { echo "API key not found: $KEY_PATH" >&2; exit 1; }
    AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")
elif [ "$UPLOAD" = 1 ]; then
    echo "Set ASC_KEY_ID and ASC_ISSUER_ID (and ASC_KEY_PATH) in .env to upload." >&2
    exit 1
else
    AUTH=(-allowProvisioningUpdates)  # Falls back to the Xcode account for a local archive.
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
echo "▸ Sumi $VERSION ($BUILD_NUMBER) from $(git rev-parse --short HEAD)"

[ -f ViewerIOS/Configuration/Local.xcconfig ] || python3 -I scripts/prepare-ios.py || true
xcodegen generate --quiet

if [ "$TESTS" = 1 ]; then
    echo "▸ SupernoteKit tests"
    (cd SupernoteKit && swift test --quiet)
    echo "▸ iOS unit tests"
    xcodebuild test -scheme "$SCHEME" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
        -only-testing:SupernoteViewerIOSTests -derivedDataPath build/ios-release-tests -quiet
fi

echo "▸ Archive"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodebuild archive -scheme "$SCHEME" -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -derivedDataPath build/ios-release-dd \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" -quiet

PLIST="$ARCHIVE/Products/Applications/$SCHEME.app/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
[ "$(read_plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || { echo "Unexpected bundle ID: $(read_plist CFBundleIdentifier)" >&2; exit 1; }
[ "$(read_plist CFBundleVersion)" = "$BUILD_NUMBER" ] || { echo "Unexpected build number: $(read_plist CFBundleVersion)" >&2; exit 1; }
KEY="$(read_plist DropboxAppKey)"
if [ -z "$KEY" ] || [ "$KEY" = "unconfigured" ]; then echo "The archive has no Dropbox app key." >&2; exit 1; fi
echo "  $BUNDLE_ID $(read_plist CFBundleShortVersionString) ($BUILD_NUMBER), Dropbox key set"

if [ "$UPLOAD" = 0 ]; then
    echo "Archived to $ARCHIVE (not uploaded)."
    exit 0
fi

echo "▸ Upload to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ViewerIOS/ExportOptions.plist \
    -exportPath "$OUT/export" "${AUTH[@]}"
echo "Uploaded. The build appears in App Store Connect → TestFlight after processing (usually 5–30 minutes)."
