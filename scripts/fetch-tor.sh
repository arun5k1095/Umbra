#!/bin/bash
# Downloads the official Tor program for Tor windows into vendor/tor/ and verifies it.
#
# Source: the Tor Project's "Tor Expert Bundle" for macOS (Apple Silicon). The download is
# checked against the SHA-256 pinned below, and also against the Tor Browser Developers'
# GPG signature when gpg is installed. To update Tor, change TOR_BUNDLE and TOR_SHA256.
set -euo pipefail
cd "$(dirname "$0")/.."

TOR_BUNDLE=16.0
TOR_SHA256=b8da251eccbe9e82f3681ee3af3c97fb4291c4a4e153e5b824bde48a1117cd6a
SIGNING_KEY=EF6E286DDA85EA2A4BA7DE684E2C6E8793298290    # Tor Browser Developers (signing key)
URL="https://dist.torproject.org/torbrowser/${TOR_BUNDLE}/tor-expert-bundle-macos-aarch64-${TOR_BUNDLE}.tar.gz"
OUT=vendor/tor

if [ -x "$OUT/tor" ] && [ "$(cat "$OUT/BUNDLE" 2>/dev/null)" = "$TOR_BUNDLE" ]; then
    echo "• Tor ${TOR_BUNDLE} already in $OUT"; exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [ -n "${TOR_TARBALL:-}" ]; then          # an already-downloaded bundle (still verified below)
    cp "$TOR_TARBALL" "$WORK/tor.tar.gz"
else
    echo "• Downloading Tor Expert Bundle ${TOR_BUNDLE}"
    curl -sSfL --retry 5 --retry-all-errors --connect-timeout 20 -o "$WORK/tor.tar.gz" "$URL"
fi
echo "$TOR_SHA256  $WORK/tor.tar.gz" | shasum -a 256 -c - >/dev/null || { echo "✗ Tor download doesn't match the pinned SHA-256" >&2; exit 1; }
echo "  SHA-256 matches"

if command -v gpg >/dev/null; then
    curl -sSfL --retry 5 --retry-all-errors -o "$WORK/tor.tar.gz.asc" "$URL.asc"
    curl -sSfL --retry 5 --retry-all-errors -o "$WORK/key.asc" "https://keys.openpgp.org/vks/v1/by-fingerprint/${SIGNING_KEY}"
    mkdir -m 700 "$WORK/gnupg"
    GNUPGHOME="$WORK/gnupg" gpg --batch --quiet --import "$WORK/key.asc" 2>/dev/null
    GNUPGHOME="$WORK/gnupg" gpg --batch --status-fd 1 --verify "$WORK/tor.tar.gz.asc" "$WORK/tor.tar.gz" 2>/dev/null \
        | grep -q "VALIDSIG .* ${SIGNING_KEY}$" || { echo "✗ Tor GPG signature check failed" >&2; exit 1; }
    echo "  GPG signature by the Tor Browser Developers key is valid"
fi

mkdir -p "$WORK/x"
tar -xzf "$WORK/tor.tar.gz" -C "$WORK/x"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$WORK/x/tor/tor" "$WORK/x/tor/libevent-2.1.7.dylib" "$OUT/"
cp "$WORK/x/docs/tor.txt" "$OUT/LICENSE-tor.txt"
cp "$WORK/x/docs/libevent.txt" "$OUT/LICENSE-libevent.txt"
cp "$WORK/x/docs/openssl.txt" "$OUT/LICENSE-openssl.txt"
chmod 755 "$OUT/tor" "$OUT/libevent-2.1.7.dylib"; chmod 644 "$OUT"/LICENSE-*.txt
echo "$TOR_BUNDLE" > "$OUT/BUNDLE"
echo "✓ Tor bundle ${TOR_BUNDLE} ready in $OUT (signed when the app is built)"
