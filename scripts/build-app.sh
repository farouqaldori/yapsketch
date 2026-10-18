#!/usr/bin/env bash
# Builds YapSketch.app into ./build and signs it.
#
# macOS ties privacy permissions to the code signature, and an ad-hoc one changes on every
# build, so a stable "Apple Development" identity is preferred when one exists.
# Override with SIGN_IDENTITY="..." (or "-" for ad-hoc). HARDENED=1 signs for distribution
# and FEED_URL turns on Sparkle updates (release.sh sets both).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/YapSketch"

DEST="${APP:-build/YapSketch.app}"
# Assembled beside it and swapped in at the end: replacing a running app's files bit by bit
# breaks its signature, and macOS then refuses it screen capture.
APP="$DEST.new"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/YapSketch"
# ditto keeps Sparkle.framework's symlinks.
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${FEED_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
fi
cp -R Resources/Providers "$APP/Contents/Resources/Providers"
# Loaded by the app itself (Brand.registerFonts).
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Icon/icon-rounded.png "$APP/Contents/Resources/AppMark.png"

# Live-caption helper. Optional: without it YapSketch falls back to Apple's speech recognizer.
if command -v cargo >/dev/null; then
    cargo build --release --manifest-path asr-helper/Cargo.toml
    cp asr-helper/target/release/yapsketch-asr "$APP/Contents/MacOS/yapsketch-asr"
else
    echo "cargo not found; building without the Parakeet live-caption helper"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | awk '{print $2}' || true)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

# Inside out: Sparkle's helpers, the framework, our helper, then the app.
FLAGS=(--force --sign "$SIGN_IDENTITY")
[[ "${HARDENED:-}" == 1 ]] && FLAGS+=(--options runtime --timestamp)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${FLAGS[@]}" "$SPARKLE/XPCServices/Installer.xpc"
codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
codesign "${FLAGS[@]}" "$SPARKLE/Autoupdate"
codesign "${FLAGS[@]}" "$SPARKLE/Updater.app"
codesign "${FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
if [[ -f "$APP/Contents/MacOS/yapsketch-asr" ]]; then
    codesign "${FLAGS[@]}" "$APP/Contents/MacOS/yapsketch-asr"
fi
codesign "${FLAGS[@]}" --entitlements Resources/YapSketch.entitlements "$APP"
rm -rf "$DEST"
mv "$APP" "$DEST"
APP="$DEST"
echo "Built $APP (signed with: $SIGN_IDENTITY)"
