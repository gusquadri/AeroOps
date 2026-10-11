#!/bin/sh
# Authorize a public key on the running dev SSH container (dev@localhost:2222).
# Usage: dev/add-key.sh path/to/key.pub
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <key.pub>" >&2; exit 2; }
key=$(cat "$1")
case "$key" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) echo "not an OpenSSH public key: $1" >&2; exit 1 ;;
esac
docker exec -i aeroops-ssh sh -c '
  f=/config/.ssh/authorized_keys
  mkdir -p /config/.ssh && touch "$f"
  read -r k
  grep -qxF "$k" "$f" || printf "%s\n" "$k" >> "$f"
  chown -R 1000:1000 /config/.ssh && chmod 700 /config/.ssh && chmod 600 "$f"
' <<EOF
$key
EOF
echo "authorized: $(printf '%s' "$key" | cut -c1-40)..."
