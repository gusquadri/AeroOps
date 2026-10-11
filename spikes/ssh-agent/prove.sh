#!/bin/sh
# Re-runs the Phase 0 ssh-agent / Secure Enclave proof against the dev container.
# Usage: spikes/ssh-agent/prove.sh [--cleanup]
#   --cleanup  also delete the spike Keychain items and de-authorize the spike keys
# Needs: the aeroops-ssh container running (docker compose -f dev/compose.yml up -d).
# Signs with the first "Apple Development" identity if present (stable designated
# requirement => Keychain items survive rebuilds without a GUI prompt); otherwise
# ad-hoc, which only works for items this exact binary created.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
sock="$HOME/.aeroops/spike-agent.sock"
tmp=$(mktemp -d /tmp/aeroops-spike.XXXXXX)
to() { perl -e 'alarm shift; exec @ARGV' "$@"; } # no coreutils timeout on macOS
agent_pid=
finish() {
  [ -n "$agent_pid" ] && kill "$agent_pid" 2>/dev/null && sleep 0.3
  rm -rf "$tmp"
}
trap finish EXIT INT TERM

swift build --package-path "$here" -c debug >/dev/null
cp "$(swift build --package-path "$here" --show-bin-path)/spike-agent" "$tmp/spike-agent"
id=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$id" ]; then
  to 30 codesign -f -s "$id" --identifier app.aeroops.spike-agent --timestamp=none "$tmp/spike-agent" 2>/dev/null
  echo "signed with: $id"
else
  echo "WARNING: no Apple Development identity; ad-hoc build (items from earlier builds will be unreadable)"
fi
bin="$tmp/spike-agent"

echo "== selftest";  to 60 "$bin" selftest 2>&1 | grep -E '\] (FAIL|selftest:)'
echo "== probe-se";  to 30 "$bin" probe-se 2>&1 | sed 's/^\[[^]]*\] //' | grep -v '^pid '

"$bin" serve --no-ui >"$tmp/agent.log" 2>&1 &
agent_pid=$!
i=0; while [ ! -S "$sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
grep -E 'ed25519:|se-p256:|rsa:|listening' "$tmp/agent.log" | sed 's/^\[[^]]*\] //'
stat -f '%Sp %N' "$HOME/.aeroops" "$sock"

echo "== ssh-add -L"
SSH_AUTH_SOCK="$sock" ssh-add -L
fail=0
for t in ed25519 se-p256 rsa3072; do
  SSH_AUTH_SOCK="$sock" ssh-add -L | grep " aeroops-spike-$t\$" >"$tmp/$t.pub"
  "$repo/dev/add-key.sh" "$tmp/$t.pub" >/dev/null
  if to 30 env -u SSH_AUTH_SOCK ssh -o IdentityAgent="$sock" -o IdentitiesOnly=yes -i "$tmp/$t.pub" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR \
      -p 2222 dev@localhost true; then echo "login $t: OK"; else echo "login $t: FAILED"; fail=1; fi
done

echo "== refused operations (each should fail)"
ssh-keygen -q -t ed25519 -N '' -C throwaway -f "$tmp/throwaway"
SSH_AUTH_SOCK="$sock" ssh-add -D 2>&1 || true
SSH_AUTH_SOCK="$sock" ssh-add "$tmp/throwaway" 2>&1 || true
SSH_AUTH_SOCK="$sock" ssh-add -d "$tmp/ed25519.pub" 2>&1 || true
rm -f "$tmp/throwaway" "$tmp/throwaway.pub"
echo "keys still listed: $(SSH_AUTH_SOCK="$sock" ssh-add -l | wc -l | tr -d ' ')"

echo "== agent log (sign requests and peers)"
grep -E 'peer|SIGN|EXTENSION|refused' "$tmp/agent.log" | sed 's/^\[[^]]*\] //' | sort -u | head -20

if [ "${1:-}" = "--cleanup" ]; then
  kill "$agent_pid"; agent_pid=
  for t in ed25519 se-p256 rsa3072; do
    docker exec -i aeroops-ssh sh -c 'f=/config/.ssh/authorized_keys; read -r k; grep -vxF "$k" "$f" > "$f.tmp" || true; cat "$f.tmp" > "$f"; rm -f "$f.tmp"' <"$tmp/$t.pub"
  done
  to 30 "$bin" cleanup 2>&1 | sed 's/^\[[^]]*\] //' | grep delete
  # -25244 (errSecInvalidOwnerEdit): legacy-keychain items can only be deleted by
  # the exact binary (cdhash) that created them; remove them in Keychain Access
  # (search "app.aeroops.spike") if an older build created them.
  rmdir "$HOME/.aeroops" 2>/dev/null || true
fi
exit $fail
