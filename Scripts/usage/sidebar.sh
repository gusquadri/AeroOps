#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

derived=build/DerivedData-quality
report="$(mktemp -d)/sidebar.json"

xcodebuild -scheme AeroOps -destination 'platform=macOS' -allowProvisioningUpdates -derivedDataPath "$derived" -quiet build
deadline=$((SECONDS + 120))
"$derived/Build/Products/Debug/AeroOps.app/Contents/MacOS/AeroOps" -AeroSelfTest sidebar -AeroSelfTestOutput "$report" &
pid=$!

while kill -0 "$pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    kill "$pid"
    echo "sidebar: FAIL (AeroOps -AeroSelfTest sidebar did not quit within 120 s)"
    exit 1
  fi
  sleep 1
done

if ! grep -q '"ok" : true' "$report" 2>/dev/null; then
  echo "sidebar: FAIL ($(cat "$report" 2>/dev/null || echo "no report at $report"))"
  exit 1
fi
echo "sidebar: rows stay in place and no stray row is drawn after folders, terminals, tags, deletes and clearing a search"
