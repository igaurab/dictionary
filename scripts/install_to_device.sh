#!/bin/bash
# Build Dictionary and install it on a connected iPhone.
#
# One-time setup (needs Xcode's UI, because only you can sign in as you):
#   1. open Dictionary.xcodeproj
#   2. Xcode ▸ Settings ▸ Accounts ▸ + ▸ Apple ID, sign in (a free Apple ID works)
#   3. Select the Dictionary target ▸ Signing & Capabilities ▸ tick "Automatically
#      manage signing" and pick your name under Team
#   4. Plug the iPhone in and trust the Mac
#
# After that, this script rebuilds and reinstalls without opening Xcode.
#
# Note: with a free (non-paid) Apple ID the signature expires after 7 days —
# re-run this script to get another 7 days. A paid Apple Developer Program
# membership ($99/yr) raises that to a year and is what TestFlight requires.

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

DERIVED=$(mktemp -d)
trap 'rm -rf "$DERIVED"' EXIT

echo "==> Looking for a connected device..."
DEVICE_JSON=$(mktemp)
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1 || true

UDID=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in d.get("result", {}).get("devices", []):
    props = dev.get("deviceProperties", {})
    conn  = dev.get("connectionProperties", {})
    if conn.get("tunnelState") in ("connected", "available") or conn.get("pairingState") == "paired":
        print(dev.get("identifier", ""))
        print(props.get("name", "device"), file=sys.stderr)
        break
' "$DEVICE_JSON" 2>/dev/null) || true
rm -f "$DEVICE_JSON"

if [ -z "${UDID:-}" ]; then
  echo "No paired iPhone found."
  echo "Plug the phone in over USB, unlock it, and tap Trust, then run this again."
  exit 1
fi

echo "==> Building and installing (this signs with your Xcode team)..."
xcodebuild \
  -project Dictionary.xcodeproj \
  -scheme Dictionary \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

APP="$DERIVED/Build/Products/Debug-iphoneos/Dictionary.app"
xcrun devicectl device install app --device "$UDID" "$APP"

echo
echo "Installed. If iOS refuses to open it, go to"
echo "Settings ▸ General ▸ VPN & Device Management and trust your developer certificate."
