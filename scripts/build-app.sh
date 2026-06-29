#!/usr/bin/env bash
# Assemble termio.app — a real macOS application bundle with a Dock icon and the
# embedded Sparkle.framework that powers in-app auto-update.
#
# termio is a plain SwiftPM executable; `swift run` produces a bare binary with
# no bundle, so macOS shows a generic Dock icon. This script builds the release
# binary and wraps it in a `.app` bundle whose Info.plist + AppIcon.icns give it
# a proper name and Dock icon, then embeds Sparkle (which SwiftPM links but does
# NOT bundle on its own) under Contents/Frameworks.
#
# Usage:
#   ./scripts/build-app.sh            # ad-hoc-signed release build into ./termio.app
#   open ./termio.app                 # launch it
#
# Environment overrides (used by the release workflow; all optional):
#   TERMIO_VERSION   CFBundleShortVersionString to stamp (default: keep Info.plist's)
#   TERMIO_BUILD     CFBundleVersion to stamp; must increase across shipped builds
#                    because Sparkle compares it (default: keep Info.plist's)
#   SIGN_IDENTITY    codesign identity, e.g. "Developer ID Application: …" for a
#                    notarizable build (default: "-", ad-hoc, for local use)
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
frameworks_dir="$contents_dir/Frameworks"
source_icon="$repo_root/packaging/AppIcon.png"
sign_identity="${SIGN_IDENTITY:--}"

echo "==> Building $app_name ($configuration)"
swift build -c "$configuration"

bin_path="$(swift build -c "$configuration" --show-bin-path)"
binary_path="$bin_path/$app_name"
if [[ ! -x "$binary_path" ]]; then
    echo "error: built binary not found at $binary_path" >&2
    exit 1
fi

sparkle_src="$bin_path/Sparkle.framework"
if [[ ! -d "$sparkle_src" ]]; then
    echo "error: Sparkle.framework not found at $sparkle_src — did the SPM build run?" >&2
    exit 1
fi

echo "==> Assembling bundle at $app_dir"
rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir" "$frameworks_dir"
cp "$binary_path" "$macos_dir/$app_name"
cp "$repo_root/packaging/Info.plist" "$contents_dir/Info.plist"

# Ship the `termio` command-line tool inside the bundle. The app installs it onto
# the user's PATH by symlinking to this copy, so it version-updates with the app.
echo "==> Bundling termio command-line tool"
cp "$repo_root/scripts/termio" "$resources_dir/termio"
chmod +x "$resources_dir/termio"

# Build, sign, and bundle the sandbox helper — the entitled binary that boots a
# Linux micro-VM per session (see sandbox-helper/). It is a separate SwiftPM package
# so it can require macOS 26 (what Apple's Containerization needs) without raising
# the app's own minimum. The app runs it via a PTY; only this binary carries the
# com.apple.security.virtualization entitlement. The Linux kernel it boots is fetched
# once (Kata static build) and cached under packaging/.cache.
helper_pkg="$repo_root/sandbox-helper"
helper_entitlements="$repo_root/packaging/termio-sandbox.entitlements"
kernel_cache="$repo_root/packaging/.cache/vmlinux-arm64"

echo "==> Building termio-sandbox helper ($configuration)"
( cd "$helper_pkg" && swift build -c "$configuration" )
helper_bin_dir="$(cd "$helper_pkg" && swift build -c "$configuration" --show-bin-path)"
helper_bin="$helper_bin_dir/termio-sandbox"
if [[ ! -x "$helper_bin" ]]; then
    echo "error: helper binary not found at $helper_bin" >&2
    exit 1
fi
cp "$helper_bin" "$resources_dir/termio-sandbox"

if [[ ! -f "$kernel_cache" ]]; then
    echo "==> Fetching Linux kernel (kata-static)"
    mkdir -p "$(dirname "$kernel_cache")"
    kernel_tmp="$(mktemp -d)"
    curl -SsL -o "$kernel_tmp/kata.tar.xz" \
        "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz"
    tar -xf "$kernel_tmp/kata.tar.xz" -C "$kernel_tmp"
    found_kernel="$(find "$kernel_tmp" -name 'vmlinux.container' | head -1)"
    if [[ -z "$found_kernel" ]]; then
        echo "error: vmlinux.container not found in kata package" >&2
        exit 1
    fi
    cp -L "$found_kernel" "$kernel_cache"
    rm -rf "$kernel_tmp"
fi
cp "$kernel_cache" "$resources_dir/vmlinux-arm64"

# Sign the helper now (with its own entitlements) so the outer-app seal below covers
# the already-signed binary. A Developer ID build also gets the hardened runtime.
helper_sign_args=(--force --sign "$sign_identity" --entitlements "$helper_entitlements")
if [[ "$sign_identity" != "-" ]]; then
    helper_sign_args+=(--options runtime --timestamp)
fi
echo "==> Signing termio-sandbox helper"
codesign "${helper_sign_args[@]}" "$resources_dir/termio-sandbox"

# Stamp version / build number when the release workflow supplies them. The
# binary's rpath already resolves @rpath/Sparkle.framework via @executable_path
# below, so embedding is purely a copy + one rpath entry.
plist="$contents_dir/Info.plist"
if [[ -n "${TERMIO_VERSION:-}" ]]; then
    echo "==> Stamping CFBundleShortVersionString=$TERMIO_VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TERMIO_VERSION" "$plist"
fi
if [[ -n "${TERMIO_BUILD:-}" ]]; then
    echo "==> Stamping CFBundleVersion=$TERMIO_BUILD"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TERMIO_BUILD" "$plist"
fi

echo "==> Embedding Sparkle.framework"
cp -R "$sparkle_src" "$frameworks_dir/"
# SwiftPM links @rpath/Sparkle.framework with only an @loader_path rpath, which
# would look beside the binary. Point @rpath at Contents/Frameworks so the
# embedded copy is found at runtime. (Harmless if the entry already exists.)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$macos_dir/$app_name" 2>/dev/null || true

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

# Sign inside-out. A Developer ID identity (with the hardened runtime) makes the
# bundle notarizable; the default "-" ad-hoc identity is enough for local runs.
# Either way Sparkle's nested helpers must be sealed before the framework, and
# the framework before the outer app, or codesign rejects the bundle.
sign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi

echo "==> Signing with identity: $sign_identity"
sparkle="$frameworks_dir/Sparkle.framework"
sparkle_version="$(readlink "$sparkle/Versions/Current" || echo B)"
sparkle_v="$sparkle/Versions/$sparkle_version"
for component in \
    "$sparkle_v/XPCServices/Installer.xpc" \
    "$sparkle_v/XPCServices/Downloader.xpc" \
    "$sparkle_v/Autoupdate" \
    "$sparkle_v/Updater.app"; do
    [[ -e "$component" ]] && codesign "${sign_args[@]}" "$component"
done
codesign "${sign_args[@]}" "$sparkle"
# Seal the outer app last so CodeResources covers the embedded framework. NOT
# --deep: the framework's components are already individually signed above.
codesign "${sign_args[@]}" "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "==> Done: $app_dir"
echo "    Launch with:  open \"$app_dir\""
