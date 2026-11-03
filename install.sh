#!/bin/zsh
# Builds Sumi for Supernote, installs it to /Applications (where the
# release DMG puts it) and refreshes Launch Services, Finder services and Quick Look. Never changes the default app.
set -euo pipefail
cd "$(dirname "$0")"

APPS=("Sumi for Supernote")
SCHEMES=("SupernoteViewer")
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Signs ad-hoc unless DEVELOPMENT_TEAM is set, e.g. DEVELOPMENT_TEAM=ABCDE12345 ./install.sh
SIGNING=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  SIGNING=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Apple Development")
fi

xcodegen generate --quiet
for scheme in "${SCHEMES[@]}"; do
  xcodebuild -project SupernoteViewer.xcodeproj -scheme "$scheme" -configuration Release \
    -derivedDataPath build/DerivedData build -quiet "${SIGNING[@]}"
done

for app in "${APPS[@]}"; do
  # Quit a running copy so open requests don't go to the old version.
  pkill -f "$app.app/Contents/MacOS/$app" || true
  rm -rf /Applications/"$app.app"
  cp -R "build/DerivedData/Build/Products/Release/$app.app" /Applications/
  "$LSREGISTER" -f /Applications/"$app.app"
  # Unregister the build copy so Finder's "Open with" menu lists each app once.
  "$LSREGISTER" -u "build/DerivedData/Build/Products/Release/$app.app" 2>/dev/null || true
  # Earlier versions of this script installed to ~/Applications; remove that copy so only one is registered.
  if [[ -d ~/Applications/"$app.app" ]]; then
    "$LSREGISTER" -u ~/Applications/"$app.app" 2>/dev/null || true
    rm -rf ~/Applications/"$app.app"
    echo "Removed old ~/Applications/$app.app"
  fi
  echo "Installed /Applications/$app.app"
done

# Remove apps from earlier versions: the viewer was called "Supernote Viewer" up to 1.4.0 (same bundle ID), and
# Supernote Preview Bridge was a separate app up to 1.4.0 (now Settings → Open Supernote files in → Preview).
for name in "Supernote Viewer" "Supernote Preview Bridge"; do
  for old in /Applications/"$name.app" ~/Applications/"$name.app"; do
    if [[ -d "$old" ]]; then
      pkill -f "$name.app/Contents/MacOS/$name" || true
      "$LSREGISTER" -u "$old" 2>/dev/null || true
      rm -rf "$old"
      echo "Removed old $old"
    fi
  done
done

/System/Library/CoreServices/pbs -update  # refresh Finder services
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1
pluginkit -m -p com.apple.quicklook.preview | grep -i supernote || echo "warning: Quick Look extension not registered yet; open Sumi for Supernote once"
