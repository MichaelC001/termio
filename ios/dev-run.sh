#!/bin/zsh
# Build TermioMobile, install it on the first connected iPhone, and launch it
# pointed at this Mac's companion server. Usage: ./dev-run.sh [roster-url]
set -euo pipefail
cd "$(dirname "$0")"

# xctrace lists physical devices as "Name (OS) (UDID)"; the UDID works for
# both xcodebuild's `id=` destination and devicectl's `--device`.
DEVICE=$(xcrun xctrace list devices 2>/dev/null \
    | sed -n '/Simulators/q;p' \
    | grep -m1 'iPhone' \
    | sed -E 's/.*\(([0-9A-Fa-f-]+)\)[[:space:]]*$/\1/')
if [[ -z "${DEVICE}" ]]; then
    echo "No iPhone found. Plug it in (or pair over Wi-Fi) and trust this Mac." >&2
    echo "Devices xctrace can see:" >&2
    xcrun xctrace list devices >&2 || true
    exit 1
fi
echo "Device: ${DEVICE}"

MAC_IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
ROSTER_URL="${1:-ws://${MAC_IP}:8787}"
echo "Roster URL: ${ROSTER_URL}"

xcodebuild \
    -project TermioMobile.xcodeproj \
    -scheme TermioMobile \
    -configuration Debug \
    -destination "id=${DEVICE}" \
    -derivedDataPath build \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build

APP="build/Build/Products/Debug-iphoneos/TermioMobile.app"
xcrun devicectl device install app --device "${DEVICE}" "${APP}"
xcrun devicectl device process launch --terminate-existing --device "${DEVICE}" \
    sh.termio.mobile -- -roster-url "${ROSTER_URL}"
