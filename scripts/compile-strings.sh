#!/usr/bin/env bash
# Compile the String Catalog into the .lproj/.strings resources SwiftPM ships.
#
# `swift build` copies an .xcstrings file into the resource bundle verbatim
# instead of compiling it — String Catalog compilation is an Xcode-build-system
# feature SwiftPM lacks (swiftlang/swift-package-manager#6993). So the catalog
# stays the single editing source, and this script regenerates the checked-in
# compiled output under Sources/termio/Resources/Localization whenever
# Localizable.xcstrings changes. Run it after editing the catalog and commit
# both together.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$repo_root/Sources/termio/Resources/Localizable.xcstrings"
output_dir="$repo_root/Sources/termio/Resources/Localization"

rm -rf "$output_dir"
xcrun xcstringstool compile "$catalog" --output-directory "$output_dir"

# xcstringstool emits only translated languages; the source language exists
# solely as the keys. Emit an explicit en.lproj so an English user resolves to
# real English strings instead of whatever localization CFBundle falls back to.
python3 - "$catalog" "$output_dir/en.lproj/Localizable.strings" <<'PYTHON'
import json, os, plistlib, sys

catalog_path, out_path = sys.argv[1], sys.argv[2]
with open(catalog_path) as f:
    catalog = json.load(f)
source_language = catalog["sourceLanguage"]
strings = {}
for key, entry in catalog.get("strings", {}).items():
    unit = entry.get("localizations", {}).get(source_language, {}).get("stringUnit")
    strings[key] = unit["value"] if unit else key
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "wb") as f:
    plistlib.dump(strings, f)
PYTHON

echo "Compiled $(basename "$catalog") -> ${output_dir#$repo_root/}:"
ls "$output_dir"
echo "Reminder: each .lproj needs its own verbatim .copy entry in Package.swift" \
     "(SwiftPM's .process lowercases zh-Hans.lproj, which CFBundle then ignores)."
