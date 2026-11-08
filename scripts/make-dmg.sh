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
# hdiutil sometimes fails with "Resource busy" on CI machines, so retry and show the error.
for attempt in 1 2 3 4; do
    if ERR=$(hdiutil create -volname "Umbra ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$OUT" 2>&1); then break; fi
    echo "hdiutil create failed (attempt $attempt): $ERR" >&2
    [ "$attempt" = 4 ] && exit 1
    sleep $((attempt * 5))
done
hdiutil verify "$OUT" >/dev/null 2>&1 || { echo "hdiutil verify failed" >&2; hdiutil verify "$OUT" >&2; exit 1; }
(cd dist && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
