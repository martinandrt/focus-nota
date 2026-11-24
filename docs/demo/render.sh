#!/bin/bash
# Render scene.html frames with headless Chrome and assemble docs/demo.gif (needs ImageMagick). Run outside the sandbox.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT=$(mktemp -d)
for f in 1 2 3 4; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --force-device-scale-factor=2 --window-size=720,450 --screenshot="$OUT/$f.png" "file://$PWD/scene.html#$f" 2>/dev/null
  magick "$OUT/$f.png" -resize 50% "$OUT/$f.png"
done
# Frame durations in 1/100 s.
magick -dispose background \
  -delay 220 "$OUT/1.png" -delay 260 "$OUT/2.png" -delay 240 "$OUT/3.png" -delay 280 "$OUT/4.png" \
  -loop 0 -layers Optimize ../demo.gif
cp "$OUT"/*.png "${FRAMES_DIR:-$OUT}/" 2>/dev/null || true
echo "docs/demo.gif $(du -h ../demo.gif | cut -f1), frames in $OUT"
