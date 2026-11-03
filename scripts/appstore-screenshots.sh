#!/bin/bash
# Captures raw App Store screenshots on the iPhone 6.9" and iPad 13" simulators.
#
#   scripts/appstore-screenshots.sh            # both devices
#   scripts/appstore-screenshots.sh iphone     # one device: iphone | ipad
#
# Output goes to $APPSTORE_DIR/screenshots/raw/<device>/ (APPSTORE_DIR from the environment or .env),
# outside this public repository. Frame them afterwards with scripts/frame-screenshots.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env-value.sh

APPSTORE_DIR="$(env_value APPSTORE_DIR)"
[ -n "$APPSTORE_DIR" ] || { echo "Set APPSTORE_DIR (for example ../sumi-appstore) in .env" >&2; exit 1; }
APPSTORE_DIR="$(resolve_path "$APPSTORE_DIR")"
[ -d "$APPSTORE_DIR" ] || { echo "APPSTORE_DIR does not exist: $APPSTORE_DIR" >&2; exit 1; }

declare -a DEVICES=()
case "${1:-all}" in
    iphone) DEVICES=("iphone|iPhone 17 Pro Max") ;;
    ipad)   DEVICES=("ipad|iPad Pro 13-inch (M5)") ;;
    all)    DEVICES=("iphone|iPhone 17 Pro Max" "ipad|iPad Pro 13-inch (M5)") ;;
    *) echo "Usage: $0 [iphone|ipad]" >&2; exit 1 ;;
esac

# The newest available simulator with this exact name.
udid_for() {
    xcrun simctl list devices available -j | /usr/bin/python3 -I -c '
import json, sys
name = sys.argv[1]
runtimes = json.load(sys.stdin)["devices"]
matches = [(rt, d["udid"]) for rt, ds in runtimes.items() if "iOS" in rt for d in ds if d["name"] == name]
print(sorted(matches)[-1][1] if matches else "")' "$1"
}

command -v xcodegen >/dev/null && xcodegen generate --quiet

for entry in "${DEVICES[@]}"; do
    slug="${entry%%|*}"; name="${entry#*|}"
    udid="$(udid_for "$name")"
    [ -n "$udid" ] || { echo "Simulator not found: $name (install it in Xcode → Settings → Components)" >&2; exit 1; }
    out="$APPSTORE_DIR/screenshots/raw/$slug"
    rm -rf "$out"; mkdir -p "$out"

    echo "▸ $name ($udid)"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl ui "$udid" appearance light
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    # A fresh install, so no earlier Dropbox session or recents show up.
    xcrun simctl uninstall "$udid" dev.schaefer.Sumi 2>/dev/null || true

    TEST_RUNNER_SCREENSHOT_DIR="$out" xcodebuild test \
        -scheme SupernoteViewerIOS \
        -destination "id=$udid" \
        -derivedDataPath build/screenshots \
        -only-testing:SupernoteViewerIOSUITests/AppStoreScreenshotTests \
        -quiet

    xcrun simctl status_bar "$udid" clear
    echo "  $(ls "$out" | wc -l | tr -d ' ') screenshots in $out"
done
