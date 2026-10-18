#!/usr/bin/env bash
# Cuts a release into build/release/<version>: YapSketch.app signed with Developer ID,
# notarized and stapled; a .zip (what Sparkle downloads) and a .dmg (for the website);
# and appcast.xml, the feed the app reads. Publishes nothing: it prints the gh command.
#
#   NOTARY_PROFILE=yapsketch scripts/release.sh 0.2.0 notes.md
#
# notes.md: what's new, one point per line ("- " in front is fine). The app shows them when
# it offers the update, and they're the GitHub release's description.
#
# NOTARY_PROFILE      notarytool keychain profile (xcrun notarytool store-credentials)
# NOTARY_KEYCHAIN     the keychain holding it, if not the default one (CI)
# SIGN_IDENTITY       signing identity (default: the keychain's Developer ID Application)
# SPARKLE_PRIVATE_KEY Sparkle's private EdDSA key (default: the keychain, as generate_keys left it)
# SKIP_NOTARIZE=1     everything but notarizing, to try the script without credentials
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ || ! -s "$NOTES" ]]; then
    echo "usage: scripts/release.sh <version> <notes.md>, e.g. 0.2.0 notes.md" >&2
    exit 1
fi
# Sparkle compares CFBundleVersion: one number that grows with the version (1.2.3 → 10203).
BUILD=$((BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3]))
REPO="farouqaldori/yapsketch"
KEY_ACCOUNT="com.yapsketch.app"
OUT="build/release/$VERSION"
APP="$OUT/YapSketch.app"
ZIP="$OUT/YapSketch-$VERSION.zip"
DMG="$OUT/YapSketch-$VERSION.dmg"
# The same .dmg under a name that never changes: the website links to
# releases/latest/download/YapSketch.dmg, which is always the newest.
LATEST_DMG="$OUT/YapSketch.dmg"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | awk '{print $2}' || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "No Developer ID Application identity in the keychain (or set SIGN_IDENTITY)." >&2
    exit 1
fi
if [[ "${SKIP_NOTARIZE:-}" != 1 && -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Set NOTARY_PROFILE to a notarytool keychain profile (or SKIP_NOTARIZE=1 to try without)." >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
rm -rf "$OUT"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
APP="$APP" SIGN_IDENTITY="$SIGN_IDENTITY" HARDENED=1 FEED_URL="$FEED_URL" scripts/build-app.sh
codesign --verify --strict --deep "$APP"

notarize() {
    [[ "${SKIP_NOTARIZE:-}" == 1 ]] && { echo "Skipping notarization of $1"; return; }
    local result="$OUT/notary.json"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} \
        --wait --output-format json >"$result"
    if [[ "$(plutil -extract status raw -o - "$result")" != Accepted ]]; then
        xcrun notarytool log "$(plutil -extract id raw -o - "$result")" --keychain-profile "$NOTARY_PROFILE" \
            ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} >&2 || true
        echo "Notarization of $1 failed." >&2
        exit 1
    fi
    rm "$result"
}

# The app: notarized as a zip, stapled, then zipped again with its ticket.
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
if [[ "${SKIP_NOTARIZE:-}" != 1 ]]; then
    xcrun stapler staple "$APP"
    spctl --assess --type execute -vv "$APP"
fi
rm "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# The .dmg: the app and an Applications link on Resources/Installer/background.tiff
# (scripts/make-dmg-background.sh). dmgbuild writes the window's .DS_Store without Finder.
[[ -x build/dmgbuild/bin/dmgbuild ]] || { python3 -m venv build/dmgbuild && build/dmgbuild/bin/pip install -q dmgbuild==1.6.7; }
build/dmgbuild/bin/python -I - "$APP" "$DMG" <<'EOF'
import sys, dmgbuild
app, dmg = sys.argv[1:]
dmgbuild.build_dmg(dmg, "YapSketch", settings={
    "files": [app],
    "symlinks": {"Applications": "/Applications"},
    "hide_extensions": ["YapSketch.app"],
    "format": "UDZO",
    "filesystem": "HFS+",
    "background": "Resources/Installer/background.tiff",
    "window_rect": ((390, 400), (660, 416)),  # Finder counts from the bottom left; 28 of 416 are the title bar
    "show_status_bar": False, "show_tab_view": False, "show_toolbar": False,
    "show_pathbar": False, "show_sidebar": False,
    "default_view": "icon-view",
    "icon_size": 128,
    "text_size": 13,
    "icon_locations": {"YapSketch.app": (182, 200), "Applications": (478, 200)},
})
EOF
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"
[[ "${SKIP_NOTARIZE:-}" == 1 ]] || xcrun stapler staple "$DMG"
cp "$DMG" "$LATEST_DMG"

# Sparkle's EdDSA signature of the zip: sparkle:edSignature="…" length="…".
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    ENCLOSURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")"
else
    ENCLOSURE="$("$SIGN_UPDATE" --account "$KEY_ACCOUNT" "$ZIP")"
fi

# appcast.xml: this version on top of the items already published (if any).
curl -fsSL "$FEED_URL" -o "$OUT/previous.xml" 2>/dev/null || rm -f "$OUT/previous.xml"
ITEM="        <item>
            <title>$VERSION</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")]]></description>
            <enclosure url=\"https://github.com/$REPO/releases/download/v$VERSION/YapSketch-$VERSION.zip\" type=\"application/octet-stream\" $ENCLOSURE/>
        </item>"
python3 -I - "$OUT/appcast.xml" "$OUT/previous.xml" "$BUILD" "$ITEM" <<'EOF'
import os, re, sys
out, previous, build, item = sys.argv[1:]
old = open(previous).read() if os.path.exists(previous) else ""
items = [i for i in re.findall(r"[ \t]*<item>.*?</item>", old, re.S) if f"<sparkle:version>{build}</sparkle:version>" not in i]
open(out, "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>YapSketch</title>
{chr(10).join([item] + items)}
    </channel>
</rss>
""")
EOF
rm -f "$OUT/previous.xml"
xmllint --noout "$OUT/appcast.xml"

echo
echo "Release $VERSION (build $BUILD) is in $OUT:"
ls -1 "$OUT"
echo
echo "Commit the version bump in Resources/Info.plist, tag v$VERSION, then publish with:"
echo "  gh release create v$VERSION --repo $REPO --title \"YapSketch $VERSION\" --notes-file $NOTES \\"
echo "    $ZIP $DMG $LATEST_DMG $OUT/appcast.xml"
