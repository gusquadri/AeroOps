#!/usr/bin/env bash
set -uo pipefail

USAGE_DIR="${USAGE_DIR:-Scripts/usage}"
failed=0
count=0

for script in "$USAGE_DIR"/*; do
  [ -x "$script" ] || continue
  count=$((count + 1))
  echo "  ▸ $script"
  "$script" || { echo "  ✗ $script"; failed=$((failed + 1)); }
done

echo "usage: $count run, $failed failed"
[ "$count" -gt 0 ] && [ "$failed" -eq 0 ]
