#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

derived=build/DerivedData-quality
report="$(mktemp -d)/host-search.json"

xcodebuild -scheme AeroOps -destination 'platform=macOS' -allowProvisioningUpdates -derivedDataPath "$derived" -quiet build
deadline=$((SECONDS + 60))
"$derived/Build/Products/Debug/AeroOps.app/Contents/MacOS/AeroOps" -AeroSelfTest host-search -AeroSelfTestOutput "$report" &
pid=$!

while kill -0 "$pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    kill "$pid"
    echo "host-search: FAIL (AeroOps -AeroSelfTest host-search did not quit within 60 s)"
    exit 1
  fi
  sleep 1
done

if ! grep -q '"ok" : true' "$report" 2>/dev/null; then
  echo "host-search: FAIL ($(cat "$report" 2>/dev/null || echo "no report at $report"))"
  exit 1
fi
echo "host-search: the sidebar and Dashboard search matches names and addresses, ignoring case, accents and blanks, and keeps the selection"
