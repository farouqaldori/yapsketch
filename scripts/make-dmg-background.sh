#!/usr/bin/env bash
# Renders Resources/Installer/background.svg into background.tiff, the dmg window's background
# (scripts/release.sh), at 1× and 2× for Retina. Needs rsvg-convert; fetches Fraunces and Geist
# into build/fonts and renders with only those, Fraunces at its 26 pt optical size.
set -euo pipefail
cd "$(dirname "$0")/.."
fonts="$PWD/build/fonts"
mkdir -p "$fonts"
for font in fraunces/Fraunces%5BSOFT,WONK,opsz,wght%5D.ttf geist/Geist%5Bwght%5D.ttf; do
    file="$fonts/$(basename "${font%%%5B*}").ttf"
    [[ -f "$file" ]] || curl -fsSL "https://github.com/google/fonts/raw/main/ofl/$font" -o "$file"
done
cat >"$fonts/fonts.conf" <<CONF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$fonts</dir>
  <cachedir>$fonts/cache</cachedir>
  <match target="pattern">
    <test name="family"><string>Fraunces</string></test>
    <edit name="fontvariations" mode="append"><string>opsz=26</string></edit>
  </match>
</fontconfig>
CONF
cd Resources/Installer
export PANGOCAIRO_BACKEND=fc FONTCONFIG_FILE="$fonts/fonts.conf"
tmp="$(mktemp -d)"
rsvg-convert -z 1 background.svg -o "$tmp/background.png"
rsvg-convert -z 2 background.svg -o "$tmp/background@2x.png"
tiffutil -cathidpicheck "$tmp/background.png" "$tmp/background@2x.png" -out background.tiff
rm -rf "$tmp"
echo "Rendered $(pwd)/background.tiff"
