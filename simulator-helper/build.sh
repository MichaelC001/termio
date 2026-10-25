#!/usr/bin/env bash
# Build termio-sim, the helper behind the Simulator pane, into OUT_DIR:
#
#   OUT_DIR/termio-sim                              the helper executable
#   OUT_DIR/Simulator/SimulatorFrameworkBridge-iOS  idb's in-simulator accessibility guest
#   OUT_DIR/Simulator/LICENSE-idb                   idb's MIT license, shipped with its code
#
# The helper links idb's simulator libraries (github.com/facebook/idb, MIT) at the
# commit pinned below. idb builds with xcodebuild from XcodeGen projects, not
# SwiftPM, so the libraries are built once per commit into a cache and the helper
# is compiled against them with swiftc. Nothing here touches the app's Package.swift:
# a contributor without XcodeGen still builds termio, just without this pane.
#
# Exit status: 0 built, 3 skipped (a prerequisite is missing; the reason is printed),
# anything else a real failure.
#
# Usage: simulator-helper/build.sh OUT_DIR
set -euo pipefail

out_dir="${1:?usage: build.sh OUT_DIR}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bump deliberately: idb tracks CoreSimulator's private API per Xcode release, and
# a new Xcode is the usual reason to move this.
idb_repository="https://github.com/facebook/idb.git"
idb_commit="6079df9f441313b20b476e084b5a8747a14571bf"

skip() {
    echo "==> Skipping the simulator helper: $1"
    exit 3
}

[[ "$(uname -m)" == "arm64" ]] || skip "idb builds arm64 only"
command -v xcodegen >/dev/null 2>&1 || skip "XcodeGen not found (brew install xcodegen)"
xcrun --find xcodebuild >/dev/null 2>&1 || skip "full Xcode not found"

cache_root="${TERMIO_IDB_CACHE:-$HOME/Library/Caches/termio/idb}"
idb="$cache_root/$idb_commit"
products="$idb/Build/Products"

if [[ ! -f "$idb/.termio-built" ]]; then
    echo "==> Building idb ${idb_commit:0:12} into $idb (once per pinned commit)"
    rm -rf "$idb"
    mkdir -p "$cache_root"
    git clone --quiet --filter=blob:none "$idb_repository" "$idb"
    git -C "$idb" checkout --quiet "$idb_commit"
    (
        cd "$idb"
        ./build.sh generate >/dev/null
        mkdir -p Build
        # The same settings idb's own build.sh passes (invoke_xcodebuild), minus
        # its log formatting. `Libraries` is every library; the helper links the
        # handful it imports and the linker drops the rest.
        xcrun xcodebuild \
            -project FBSimulatorControl.xcodeproj -scheme Libraries -sdk macosx \
            -configuration Release -derivedDataPath Build \
            SYMROOT="$products" OBJROOT="$idb/Build/Intermediates" \
            -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile \
            -disableAutomaticPackageResolution ENABLE_USER_SCRIPT_SANDBOXING=NO \
            CLANG_ENABLE_EXPLICIT_MODULES=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
            build >"$idb/Build/libraries.log" 2>&1 \
            || { tail -40 "$idb/Build/libraries.log" >&2; exit 1; }
        # Only the iOS guest: idb's `build libraries` also wants the tvOS and
        # watchOS ones, and fails outright on a Mac without those SDKs.
        ./build.sh build SimulatorFrameworkBridge-iOS >"$idb/Build/bridge.log" 2>&1 \
            || { tail -40 "$idb/Build/bridge.log" >&2; exit 1; }
    )
    touch "$idb/.termio-built"
fi

release="$products/Release"
bridge="$products/Release-iphonesimulator/SimulatorFrameworkBridge-iOS"
[[ -f "$bridge" ]] || { echo "error: idb built no SimulatorFrameworkBridge-iOS at $bridge" >&2; exit 1; }

libraries=()
for name in FBControlCore FBControlCoreObjC FBSimulatorControl FBSimulatorBridgeProtocol \
            SimulatorIPC FBSimulatorAX FBSimulatorServices IDBConcurrency; do
    libraries+=("$release/lib$name.a")
done

echo "==> Compiling termio-sim"
mkdir -p "$out_dir/Simulator"
# The swiftmodules are binary, so the helper must be compiled by the same Swift
# that built idb — which is the case whenever both come from this script.
xcrun swiftc -O -target arm64-apple-macos15 \
    -I "$release" \
    -I "$idb/FBControlCoreObjC/include" \
    -I "$idb/PrivateHeaders" -Xcc "-I$idb/PrivateHeaders" \
    "$here"/Sources/*.swift \
    "${libraries[@]}" \
    -Xlinker -weak_library -Xlinker "$idb/PrivateHeaders/CoreSimulator/CoreSimulator.tbd" \
    -Xlinker -weak_library \
    -Xlinker "$idb/PrivateHeaders/AccessibilityPlatformTranslation/AccessibilityPlatformTranslation.tbd" \
    -o "$out_dir/termio-sim"

cp "$bridge" "$out_dir/Simulator/SimulatorFrameworkBridge-iOS"
cp "$idb/LICENSE" "$out_dir/Simulator/LICENSE-idb"
echo "==> termio-sim ready in $out_dir"
