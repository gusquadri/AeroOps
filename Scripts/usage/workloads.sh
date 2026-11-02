#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

derived=build/DerivedData-quality
report="$(mktemp -d)/workloads.json"
deadline=$((SECONDS + 90))

xcodebuild -scheme AeroOps -destination 'platform=macOS' -allowProvisioningUpdates -derivedDataPath "$derived" -quiet build
"$derived/Build/Products/Debug/AeroOps.app/Contents/MacOS/AeroOps" -AeroSelfTest workloads -AeroSelfTestOutput "$report" &
pid=$!

while kill -0 "$pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    kill "$pid"
    echo "workloads: FAIL (AeroOps -AeroSelfTest workloads did not quit within 90 s)"
    exit 1
  fi
  sleep 1
done

if ! grep -q '"ok" : true' "$report" 2>/dev/null; then
  echo "workloads: FAIL ($(cat "$report" 2>/dev/null || echo "no report at $report"))"
  exit 1
fi
echo "workloads: lists, Stop, Restart, Delete with confirmation, Inspect, Logs and search, pods and describe, through the models both apps share"
