#!/bin/bash
# Ships the version set in build.sh: DMG → GitHub release → signed appcast entry → site.
# Usage: tools/release.sh "What's new, one line per change"
# Installed copies find the update within a day (or at once via About → Check for Updates…).
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES=${1:?usage: tools/release.sh "release notes"}
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }

tools/make-dmg.sh
APP=build/Islet.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION already exists: bump VERSION in build.sh."; exit 1; }
grep -q "<sparkle:version>$BUILD<" docs/appcast.xml && { echo "Build $BUILD already shipped: bump VERSION_BUILD in build.sh."; exit 1; }

DMG=dist/Islet-$VERSION.dmg
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/Islet.dmg"
(cd "$STAGE" && shasum -a 256 Islet.dmg) > dist/Islet.dmg.sha256
# Prints: sparkle:edSignature="…" length="…"
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$STAGE/Islet.dmg")

# Newest item first; older items stay so the feed keeps its history.
ITEM="    <item>
      <title>Islet $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>$(sed 's/^/<li>/; s/$/<\/li>/' <<<"$NOTES" | tr -d '\n')</ul>]]></description>
      <enclosure url=\"https://github.com/YashTygi/islet/releases/download/v$VERSION/Islet.dmg\" $SIG type=\"application/octet-stream\"/>
    </item>"
python3 -I - "$ITEM" <<'PY'
import sys
p = "docs/appcast.xml"
s = open(p).read()
marker = "<language>en</language>\n"
assert marker in s, "appcast.xml marker missing"
open(p, "w").write(s.replace(marker, marker + sys.argv[1] + "\n", 1))
PY

# Upload the DMG before publishing the feed, so no installed copy sees an entry whose file is missing.
git tag "v$VERSION" && git push -q origin main "v$VERSION"
gh release create "v$VERSION" "$STAGE/Islet.dmg" dist/Islet.dmg.sha256 --repo YashTygi/islet \
  --title "Islet $VERSION" --notes "$NOTES"
git add docs/appcast.xml && git commit -q -m "Appcast: Islet $VERSION" && git push -q origin main
echo "Released Islet $VERSION (build $BUILD). The site redeploys in about a minute."
