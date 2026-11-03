#!/bin/zsh
# Renders the icon concepts (concepts.py) to PNG with headless Chrome, then the contact sheets.
#   Artwork/concepts/render.sh            all icons + sheets
#   Artwork/concepts/render.sh remora-    only icons whose id starts with "remora-"
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
shot() { # <url> <out.png> <w> <h>
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=$3,$4 --virtual-time-budget=3000 --screenshot="$2" "$1" 2>/dev/null
}

python3 -I concepts.py
mkdir -p build/png
for svg in build/svg/${1:-}*.svg; do
  shot "file://$PWD/$svg" "$PWD/build/png/${${svg:t}:r}.png" 1024 1024
done
if [[ -z "${1:-}" && -f sheet.py ]]; then
  python3 -I sheet.py
  for html in build/sheet-*.html; do
    h=$(sed -n 's/.*data-height="\([0-9]*\)".*/\1/p' $html | head -1)
    shot "file://$PWD/$html" "$PWD/build/${${html:t}:r}.png" 1600 ${h:-2400}
  done
fi
echo "rendered $(ls build/png | wc -l | tr -d ' ') icons"
