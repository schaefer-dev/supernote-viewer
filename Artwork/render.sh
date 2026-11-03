#!/bin/zsh
# Regenerates the icon artwork from artwork.py: the layers in Viewer, Bridge and ViewerIOS AppIcon.icon
# (stroke.png and paper.png rendered here), and Shared/SupernoteNote.icns / SupernoteMark.icns (document icons),
# rendered with headless Chrome.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

python3 -I artwork.py
# App icon layers whose SVG filters Icon Composer can't render: the brush S and the washi texture.
for layer in stroke paper; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$PWD/build/icon-$layer.png" "file://$PWD/build/icon-$layer.svg" 2>/dev/null
  for app in Viewer Bridge ViewerIOS; do
    cp build/icon-$layer.png ../$app/AppIcon.icon/Assets/$layer.png
  done
done
echo "wrote AppIcon.icon layers (stroke.png, paper.png, dot.svg)"
for doc in note mark; do
  for variant in $doc $doc-small; do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
      --window-size=1024,1024 --screenshot="$PWD/build/$variant.png" "file://$PWD/build/$variant.svg" 2>/dev/null
  done
  iconset=build/$doc.iconset
  rm -rf $iconset && mkdir -p $iconset
  # Up to 64 px the simplified artwork (no label, fewer lines) stays legible.
  for name px in 16x16 16 16x16@2x 32 32x32 32 32x32@2x 64 128x128 128 128x128@2x 256 \
                 256x256 256 256x256@2x 512 512x512 512 512x512@2x 1024; do
    src=build/$doc.png
    (( px <= 64 )) && src=build/$doc-small.png
    sips -z $px $px $src --out $iconset/icon_$name.png >/dev/null
  done
  out=../Shared/Supernote${(C)doc}.icns
  iconutil -c icns $iconset -o $out
  echo "wrote ${out#../}"
done
