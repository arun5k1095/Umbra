#!/bin/bash
# Packages build/Umbra.app into dist/Umbra-<version>.dmg (drag-to-Applications) + .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
APP=build/Umbra.app
OUT=dist/Umbra-${VERSION}.dmg
[ -d "$APP" ] || { echo "Build the app first: ./build.sh" >&2; exit 1; }
STAGE=build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/Umbra.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
cp NOTICE.md "$STAGE/NOTICE.txt"
rm -f "$OUT"
hdiutil create -volname "Umbra ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null 2>&1
hdiutil verify "$OUT" >/dev/null 2>&1
(cd dist && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
