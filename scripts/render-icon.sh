#!/usr/bin/env bash
# Render packaging/icon-static.svg -> packaging/AppIcon.png at 1024x1024.
#
# The icon uses SVG gradients + blur filters (frosted-glass look) that
# ImageMagick's built-in SVG renderer drops, so we rasterize through a real
# WebKit/Blink engine. Headless Chrome is the only renderer we can rely on
# being present on a dev Mac; falls back to `rsvg-convert` if installed.
#
# Run this whenever icon-static.svg changes, then ./scripts/build-app.sh to
# fold the PNG into AppIcon.icns.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
svg="$repo_root/packaging/icon-static.svg"
out="$repo_root/packaging/AppIcon.png"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if [[ -x "$chrome" ]]; then
    "$chrome" --headless=new --disable-gpu --force-device-scale-factor=1 \
        --hide-scrollbars --default-background-color=00000000 \
        --window-size=1024,1024 --screenshot="$out" "file://$svg" >/dev/null 2>&1
elif command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 1024 -h 1024 "$svg" -o "$out"
else
    echo "error: need headless Chrome or rsvg-convert to render the icon (filters)." >&2
    exit 1
fi

echo "==> Wrote $out"
