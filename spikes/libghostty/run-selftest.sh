#!/bin/sh
# Builds the libghostty spike and runs its self-test against the dev container.
#
# Usage: spikes/libghostty/run-selftest.sh [MODE ...]   (default: all)
#   surface | app | osc | app-osc   full self-test with that exit-handling mode
#   fail-default | fail-zero        app-osc against a closed port (fast ssh exit),
#                                   abnormal-command-exit-runtime default / 0
#        SKIP_BUILD=1 spikes/libghostty/run-selftest.sh surface
#
# A throwaway ed25519 key is generated in a temp dir OUTSIDE the repo, loaded
# into a temp ssh-agent, authorized with dev/add-key.sh, and deleted on exit.
# The app only ever sees the .pub file plus SSH_AUTH_SOCK (the AeroOps scheme).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
modes=${*:-surface app osc app-osc fail-default fail-zero}
derived="$here/build/DerivedData"
app="$derived/Build/Products/Debug/GhosttySpike.app/Contents/MacOS/GhosttySpike"
results="$here/results"
mkdir -p "$results"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  (cd "$here" && xcodegen generate --quiet)
  xcodebuild -project "$here/GhosttySpike.xcodeproj" -scheme GhosttySpike \
    -destination 'platform=macOS' -derivedDataPath "$derived" build -quiet
fi

tmp=$(mktemp -d /tmp/aero-ghostty-spike.XXXXXX)
agent_pid=
cleanup() {
  [ -n "$agent_pid" ] && kill "$agent_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

ssh-keygen -q -t ed25519 -N '' -C aeroops-libghostty-spike -f "$tmp/id_ed25519"
"$repo/dev/add-key.sh" "$tmp/id_ed25519.pub" >/dev/null
eval "$(ssh-agent -a "$tmp/agent.sock" -s)" >/dev/null
agent_pid=$SSH_AGENT_PID
SSH_AUTH_SOCK="$tmp/agent.sock" ssh-add -q "$tmp/id_ed25519"
rm -f "$tmp/id_ed25519" # private key now lives only in the temp agent

status=0
for mode in $modes; do
  out="$results/selftest-$mode.json"
  rm -f "$out" "$out.ghostty.log"
  echo "== mode=$mode"
  case $mode in
    fail-default) extra="--exit-mode app-osc --port 1 --expect-fail" ;;
    fail-zero) extra="--exit-mode app-osc --port 1 --expect-fail --abnormal-runtime 0" ;;
    *) extra="--exit-mode $mode" ;;
  esac
  # Clear SSH_AUTH_SOCK so only the per-surface env can supply the agent.
  # shellcheck disable=SC2086 # $extra is a word list
  if env -u SSH_AUTH_SOCK "$app" --selftest "$out" $extra \
      --key "$tmp/id_ed25519.pub" --agent-sock "$tmp/agent.sock" >/dev/null 2>&1; then
    echo "   PASS"
  elif [ "$mode" = fail-default ]; then
    # Documents upstream behaviour: a command that exits within
    # abnormal-command-exit-runtime (250 ms) shows an error and never closes.
    echo "   EXPECTED FAIL (fast exit is 'abnormal': error text, no close callback)"
  else
    echo "   FAIL (exit $?)"; status=1
  fi
  if [ -f "$out" ]; then
    /usr/bin/python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
for c in r["checks"]:
    print("   %-18s %s  %s" % (c["name"], "pass" if c["pass"] else "FAIL", c["detail"]))
print("   close needed keypress:", r.get("closeNeededKeypress"), " close s after OK:", r.get("closeSecondsAfterOK"))
' "$out"
  else
    echo "   no result file"
  fi
done
exit $status
