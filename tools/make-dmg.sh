#!/bin/bash
# Builds dist/Islet-<version>.dmg: the app, an Applications shortcut and install notes.
# Usage: tools/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Islet.app/Contents/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/Islet.app "$STAGE/Islet.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<TXT
Islet $VERSION: mission control for background work
Requires a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later.

INSTALL
1. Drag Islet onto the Applications folder.
2. Open Islet from Applications.

FIRST LAUNCH ("Apple could not verify Islet…")
Islet isn't notarized by Apple yet, so macOS asks you to approve it once:
1. Click "Done" on the warning.
2. Open System Settings → Privacy & Security.
3. Scroll down to "Islet was blocked…" and click "Open Anyway", then confirm.
You only do this once.

SETUP
A short setup opens on first launch: permissions, and connecting Claude Code
(agent status, the \`notch\` command). You can rerun it from the control panel:
click the gear in the notch → About → Show setup again.

PRIVACY
Everything stays on your Mac. No accounts, no analytics, no network calls,
except "Share publicly", which you start yourself.

UNINSTALL
Quit Islet, delete it from Applications. If you connected Claude Code, first
use Control panel → Agents → Remove (or restore ~/.claude/settings.json.mynotch-backup).
TXT
mkdir -p dist
OUT="dist/Islet-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Islet $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
SIGN=$(security find-certificate -c "MyNotch Dev" -Z 2>/dev/null | awk '/SHA-1/{print $3}')
[ -n "$SIGN" ] && codesign --force --sign "$SIGN" "$OUT"
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
