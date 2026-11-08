#!/bin/bash
# Downloads the latest EasyList, EasyPrivacy and Public Suffix List, converts them, checks
# every rule compiles in WebKit, and updates Resources/. Run it, then rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
D=build/downloads
mkdir -p "$D" build/filters
curl -sfL -m 60 -o "$D/public_suffix_list.dat" https://publicsuffix.org/list/public_suffix_list.dat
curl -sfL -m 60 -o "$D/easylist.txt" https://easylist.to/easylist/easylist.txt
curl -sfL -m 60 -o "$D/easyprivacy.txt" https://easylist.to/easylist/easyprivacy.txt
for f in "$D"/*; do file -b "$f" | grep -qi text || { echo "$f is not a text file" >&2; exit 1; }; done

python3 -I tools/build_filters.py "$D/easylist.txt" "$D/easyprivacy.txt" build/filters
swiftc -O tools/validate_rules.swift -o build/validate_rules
build/validate_rules build/filters/rules-ads.json build/filters/rules-privacy.json build/filters/rules-cosmetic.json

cp build/filters/rules-*.json build/filters/host-rules.txt build/filters/filters-stats.json Resources/lists/
cp "$D/public_suffix_list.dat" Resources/
echo "✓ Filters updated: $(grep -m1 '^! Version' "$D/easylist.txt") / $(grep -m1 '^! Version' "$D/easyprivacy.txt")"
