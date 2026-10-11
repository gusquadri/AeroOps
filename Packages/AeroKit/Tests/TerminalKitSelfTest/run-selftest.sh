#!/bin/sh
# TerminalKit self-test against the dev SSH container (dev@localhost:2222).
# Opens real libghostty tabs in a window, so it needs a logged-in GUI session.
#
# Usage: Packages/AeroKit/Tests/TerminalKitSelfTest/run-selftest.sh
#
# A throwaway ed25519 key is generated in a mktemp dir OUTSIDE the repo, authorized with
# dev/add-key.sh and loaded into a temp ssh-agent; the private key file is deleted right after
# ssh-add. The temp ssh config names the public key as IdentityFile (IdentitiesOnly), the
# agent socket reaches ssh only through the launch spec's environment (SSH_AUTH_SOCK), like
# the app's in-app agent. Everything is removed on exit, including the authorized_keys line.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/../.." && pwd)
repo=$(cd "$pkg/../.." && pwd)

tmp=$(mktemp -d /tmp/aeroops-terminalkit.XXXXXX)
agent_pid=
pub=
cleanup() {
  [ -n "$agent_pid" ] && kill "$agent_pid" 2>/dev/null || true
  # dev/add-key.sh authorizes the key on every dev server; remove-key.sh revokes it there.
  if [ -n "$pub" ]; then
    "$repo/dev/remove-key.sh" "$tmp/id_ed25519.pub" >/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

ssh-keygen -q -t ed25519 -N '' -C aeroops-terminalkit-selftest -f "$tmp/id_ed25519"
pub=$(cat "$tmp/id_ed25519.pub")
"$repo/dev/add-key.sh" "$tmp/id_ed25519.pub" >/dev/null
eval "$(ssh-agent -a "$tmp/agent.sock" -s)" >/dev/null
agent_pid=$SSH_AGENT_PID
SSH_AUTH_SOCK="$tmp/agent.sock" ssh-add -q "$tmp/id_ed25519"
rm -f "$tmp/id_ed25519"

# Port 1 on localhost is closed on a stock Mac: ssh fails with "Connection refused", exit 255.
cat > "$tmp/ssh_config" <<EOF
Host aero-selftest
  HostName localhost
  Port 2222
Host aero-closed
  HostName 127.0.0.1
  Port 1
Host *
  User dev
  IdentityFile $tmp/id_ed25519.pub
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ControlMaster no
  ConnectTimeout 5
EOF

swift build --package-path "$pkg" --product TerminalKitSelfTest
bin="$(swift build --package-path "$pkg" --show-bin-path)/TerminalKitSelfTest"

# No inherited agent: only the launch spec's SSH_AUTH_SOCK can authenticate.
env -u SSH_AUTH_SOCK "$bin" --ssh-config "$tmp/ssh_config" --host aero-selftest \
  --closed-host aero-closed --agent-sock "$tmp/agent.sock"
