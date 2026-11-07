#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

derived=build/DerivedData-quality
report="$(mktemp -d)/termius-import.json"

xcodebuild -scheme AeroOps -destination 'platform=macOS' -allowProvisioningUpdates -derivedDataPath "$derived" -quiet build
deadline=$((SECONDS + 60))
"$derived/Build/Products/Debug/AeroOps.app/Contents/MacOS/AeroOps" -AeroSelfTest termius-import -AeroSelfTestOutput "$report" &
pid=$!

while kill -0 "$pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    kill "$pid"
    echo "termius-import: FAIL (AeroOps -AeroSelfTest termius-import did not quit within 60 s)"
    exit 1
  fi
  sleep 1
done

if ! grep -q '"ok" : true' "$report" 2>/dev/null; then
  echo "termius-import: FAIL ($(cat "$report" 2>/dev/null || echo "no report at $report"))"
  exit 1
fi
echo "termius-import: checked Termius hosts are added with their shared key imported once and their password in the Keychain; duplicates and Telnet hosts are left out"
