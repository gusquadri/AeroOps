#!/bin/sh
# Revoke a public key that dev/add-key.sh authorized, on every running AeroOps dev server:
#   aeroops-ssh     dev@localhost:2222
#   aeroops-alpine  dev@localhost:2223 (BusyBox)
#   aeroops-vm      dev@ and nodocker@ <vm address>:22
# Removes exactly the matching authorized_keys line; other keys are kept. The file is
# rewritten in place (cat into it), so its owner and mode stay as they were.
# Servers that are not running are skipped.
# Usage: dev/remove-key.sh path/to/key.pub
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <key.pub>" >&2; exit 2; }
key=$(cat "$1")
case "$key" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) echo "not an OpenSSH public key: $1" >&2; exit 1 ;;
esac
short=$(printf '%s' "$key" | cut -c1-40)

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

revoke='
  read -r k
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -qxF "$k" "$f" || continue
    t=$(mktemp)
    grep -vxF "$k" "$f" > "$t" || true
    cat "$t" > "$f"
    rm -f "$t"
  done
'

if running aeroops-ssh; then
  docker exec -i aeroops-ssh sh -c "$revoke" sh /config/.ssh/authorized_keys <<EOF
$key
EOF
  echo "aeroops-ssh     dev@localhost:2222   revoked: $short..."
fi

if running aeroops-alpine; then
  docker exec -i aeroops-alpine sh -c "$revoke" sh /home/dev/.ssh/authorized_keys <<EOF
$key
EOF
  echo "aeroops-alpine  dev@localhost:2223   revoked: $short..."
fi

if command -v orb >/dev/null 2>&1 && orb list -r -q 2>/dev/null | grep -qx aeroops-vm; then
  orb -m aeroops-vm -u root sh -c "$revoke" sh /home/dev/.ssh/authorized_keys /home/nodocker/.ssh/authorized_keys <<EOF
$key
EOF
  echo "aeroops-vm      dev@,nodocker@ :22   revoked: $short..."
fi
