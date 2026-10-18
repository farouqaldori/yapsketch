#!/usr/bin/env bash
# Draws Resources/Icon/*.svg (scripts/icon.py) and renders them into the app's AppIcon.icns and PNGs (needs rsvg-convert).
#   icon-square: full bleed, the website's touch icon (iOS rounds it)
#   icon-rounded: the icon shape on a clear background (website)
#   icon-macos: Apple's macOS grid, 824 px shape on 1024 with a shadow (the app)
set -euo pipefail
cd "$(dirname "$0")/../Resources/Icon"
python3 ../../scripts/icon.py .
rsvg-convert -w 1024 icon-rounded.svg -o icon-rounded.png
set="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$set"
for p in 16 32 128 256 512; do
    rsvg-convert -w "$p" icon-macos.svg -o "$set/icon_${p}x${p}.png"
    rsvg-convert -w "$((p * 2))" icon-macos.svg -o "$set/icon_${p}x${p}@2x.png"
done
iconutil -c icns "$set" -o AppIcon.icns
rsvg-convert -w 256 icon-rounded.svg -o ../../website/icon.png
rsvg-convert -w 180 icon-square.svg -o ../../website/apple-touch-icon.png
echo "Rendered $(pwd)"
