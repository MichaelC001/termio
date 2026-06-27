#!/usr/bin/env bash
# Assemble termio.app — a real macOS application bundle with a Dock icon.
#
# termio is a plain SwiftPM executable; `swift run` produces a bare binary with
# no bundle, so macOS shows a generic Dock icon. This script builds the release
# binary and wraps it in a `.app` bundle whose Info.plist + AppIcon.icns give it
# a proper name and Dock icon.
#
# Usage:
#   ./scripts/build-app.sh            # release build into ./termio.app
#   open ./termio.app                 # launch it
#
# Drop a 1024x1024 PNG at packaging/AppIcon.png to set the icon. Without it the
# bundle is still built (just iconless).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

configuration="release"
app_name="termio"
app_dir="$repo_root/${app_name}.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
source_icon="$repo_root/packaging/AppIcon.png"

echo "==> Building $app_name ($configuration)"
swift build -c "$configuration"

binary_path="$(swift build -c "$configuration" --show-bin-path)/$app_name"
if [[ ! -x "$binary_path" ]]; then
    echo "error: built binary not found at $binary_path" >&2
    exit 1
fi

echo "==> Assembling bundle at $app_dir"
rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"
cp "$binary_path" "$macos_dir/$app_name"
cp "$repo_root/packaging/Info.plist" "$contents_dir/Info.plist"

if [[ -f "$source_icon" ]]; then
    echo "==> Generating AppIcon.icns from packaging/AppIcon.png"
    iconset_dir="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$iconset_dir"
    # macOS expects these exact names/sizes inside the .iconset directory.
    for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
                "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
                "512:512x512" "1024:512x512@2x"; do
        px="${spec%%:*}"
        label="${spec##*:}"
        sips -z "$px" "$px" "$source_icon" --out "$iconset_dir/icon_${label}.png" >/dev/null
    done
    iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"
    rm -rf "$(dirname "$iconset_dir")"
else
    echo "==> No packaging/AppIcon.png found — building without a Dock icon."
    echo "    Drop a 1024x1024 PNG there and re-run to add one."
fi

# Ad-hoc sign so macOS treats it as a stable app identity (no developer cert
# needed for local use). Harmless if codesign is unavailable.
codesign --force --deep --sign - "$app_dir" >/dev/null 2>&1 || true

echo "==> Done: $app_dir"
echo "    Launch with:  open \"$app_dir\""
