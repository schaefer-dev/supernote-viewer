#!/bin/zsh
# Builds Sumi for Supernote signed with Developer ID, packs them into a notarized, stapled DMG in dist/.
#   ./release.sh            build, sign, notarize
#   ./release.sh --publish  also create the GitHub release (needs `gh auth login`)
set -euo pipefail
cd "$(dirname "$0")"

TEAM=VYPW8U86QN
NOTARY_PROFILE=supernote-notary
APPS=("Sumi for Supernote")
SCHEMES=("SupernoteViewer")
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
DMG="dist/SupernoteViewer-$VERSION.dmg"
PRODUCTS=build/ReleaseData/Build/Products/Release

setup_help() {
  cat >&2 <<EOF

One-time setup:
  1. Xcode → Settings → Accounts → (your team) → Manage Certificates… → + → Developer ID Application
  2. Create an app-specific password at https://account.apple.com → Sign-In and Security, then run:
       xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id $TEAM
EOF
  exit 1
}

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM)" \
  | head -1 | awk '{print $2}' || true)
[[ -n "$IDENTITY" ]] || { echo "error: no 'Developer ID Application' certificate for team $TEAM" >&2; setup_help; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "error: no notarytool keychain profile '$NOTARY_PROFILE'" >&2; setup_help; }

echo "==> Building $VERSION"
xcodegen generate --quiet
rm -rf build/ReleaseData
for scheme in "${SCHEMES[@]}"; do
  xcodebuild -project SupernoteViewer.xcodeproj -scheme "$scheme" -configuration Release \
    -derivedDataPath build/ReleaseData -destination 'generic/platform=macOS' build -quiet \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO  # no get-task-allow; notarization rejects it
done
for app in "${APPS[@]}"; do
  codesign --verify --deep --strict "$PRODUCTS/$app.app"
  for binary in "$PRODUCTS/$app.app" "$PRODUCTS/$app.app"/Contents/PlugIns/*.appex(N); do
    if codesign -d --entitlements - "$binary" 2>/dev/null | grep -q get-task-allow; then
      echo "error: $binary has the get-task-allow entitlement" >&2
      exit 1
    fi
  done
done

echo "==> Packing $DMG"
WORK=$(mktemp -d)
trap 'hdiutil detach "$WORK/mnt" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT
STAGING="$WORK/staging"
mkdir "$STAGING"
for app in "${APPS[@]}"; do
  ditto "$PRODUCTS/$app.app" "$STAGING/$app.app"
done
ln -s /Applications "$STAGING/Applications"
# The mounted volume shows the Viewer's app icon: .VolumeIcon.icns plus the custom-icon flag on the root.
swift Artwork/app-icon.swift "$PRODUCTS/${APPS[1]}.app" "$STAGING/.VolumeIcon.icns"
mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "Sumi for Supernote $VERSION" -srcfolder "$STAGING" -format UDRW -quiet "$WORK/rw.dmg"
hdiutil attach "$WORK/rw.dmg" -mountpoint "$WORK/mnt" -nobrowse -noautoopen -quiet
SetFile -a C "$WORK/mnt"
hdiutil detach "$WORK/mnt" -quiet
hdiutil convert "$WORK/rw.dmg" -format UDZO -quiet -o "$DMG"
# Xcode registers the build products with Launch Services; left registered, a stale copy can become the
# default app for .note/.mark (and supply their document icons) once build/ReleaseData is rebuilt or removed.
for app in "${APPS[@]}"; do
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$PRODUCTS/$app.app" 2>/dev/null || true
done
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing (usually a few minutes)"
OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$OUT"
if ! grep -q "status: Accepted" <<<"$OUT"; then
  ID=$(sed -n 's/^ *id: *//p' <<<"$OUT" | head -1)
  echo "error: notarization failed; details: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi
xcrun stapler staple -q "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

if [[ "${1:-}" == "--publish" ]]; then
  echo "==> Publishing v$VERSION"
  gh release create "v$VERSION" "$DMG" --title "Sumi for Supernote $VERSION" --generate-notes
fi
echo "Done: $DMG"
