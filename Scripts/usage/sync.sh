#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

derived=build/DerivedData-quality
report="$(mktemp -d)/sync.json"
deadline=$((SECONDS + 90))

xcodebuild -scheme AeroOps -destination 'platform=macOS' -allowProvisioningUpdates -derivedDataPath "$derived" -quiet build
"$derived/Build/Products/Debug/AeroOps.app/Contents/MacOS/AeroOps" -AeroSelfTest sync -AeroSelfTestOutput "$report" &
pid=$!

while kill -0 "$pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    kill "$pid"
    echo "sync: FAIL (AeroOps -AeroSelfTest sync did not quit within 90 s)"
    exit 1
  fi
  sleep 1
done

if ! grep -q '"ok" : true' "$report" 2>/dev/null; then
  echo "sync: FAIL (no passing report at $report)"
  exit 1
fi
echo "sync: keys, passwords, hosts and pins sync through the shared iCloud Keychain group; MCP tiers stay local"
