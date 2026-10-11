#!/bin/sh
# Authorize a public key on every running AeroOps dev server:
#   aeroops-ssh     dev@localhost:2222   docker compose service "ssh"
#   aeroops-alpine  dev@localhost:2223   docker compose service "alpine" (BusyBox)
#   aeroops-vm      dev@ and nodocker@ <vm address>:22   OrbStack machine (dev/vm)
# Servers that are not running are skipped. Exits 1 if no server took the key.
# Keys added this way are lost when a container or the VM is rebuilt; to make
# one permanent, also copy the .pub file into dev/keys/.
# Usage: dev/add-key.sh path/to/key.pub
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <key.pub>" >&2; exit 2; }
key=$(cat "$1")
case "$key" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) echo "not an OpenSSH public key: $1" >&2; exit 1 ;;
esac
short=$(printf '%s' "$key" | cut -c1-40)
ok=0

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# dev@localhost:2222 (linuxserver/openssh-server; dev's home is /config)
if running aeroops-ssh; then
  docker exec -i aeroops-ssh sh -c '
    f=/config/.ssh/authorized_keys
    mkdir -p /config/.ssh && touch "$f"
    read -r k
    grep -qxF "$k" "$f" || printf "%s\n" "$k" >> "$f"
    chown -R 1000:1000 /config/.ssh && chmod 700 /config/.ssh && chmod 600 "$f"
  ' <<EOF
$key
EOF
  echo "aeroops-ssh     dev@localhost:2222   authorized: $short..."
  ok=1
else
  echo "aeroops-ssh     not running, skipped (docker compose -f dev/compose.yml up -d ssh)"
fi

# dev@localhost:2223 (BusyBox Alpine)
if running aeroops-alpine; then
  docker exec -i aeroops-alpine sh -c '
    f=/home/dev/.ssh/authorized_keys
    install -d -o dev -g dev -m 700 /home/dev/.ssh && touch "$f"
    read -r k
    grep -qxF "$k" "$f" || printf "%s\n" "$k" >> "$f"
    chown dev:dev "$f" && chmod 600 "$f"
  ' <<EOF
$key
EOF
  echo "aeroops-alpine  dev@localhost:2223   authorized: $short..."
  ok=1
else
  echo "aeroops-alpine  not running, skipped (docker compose -f dev/compose.yml up -d alpine)"
fi

# dev@ and nodocker@ the OrbStack VM
if command -v orb >/dev/null 2>&1 && orb list -r -q 2>/dev/null | grep -qx aeroops-vm; then
  # shellcheck disable=SC2016  # expanded by the remote shell
  orb -m aeroops-vm -u root sh -c '
    read -r k
    for u in dev nodocker; do
      id "$u" >/dev/null 2>&1 || continue
      f=/home/$u/.ssh/authorized_keys
      install -d -o "$u" -g "$u" -m 700 "/home/$u/.ssh" && touch "$f"
      grep -qxF "$k" "$f" || printf "%s\n" "$k" >> "$f"
      chown "$u:$u" "$f" && chmod 600 "$f"
    done
  ' <<EOF
$key
EOF
  echo "aeroops-vm      dev@,nodocker@ :22   authorized: $short..."
  ok=1
else
  echo "aeroops-vm      not running, skipped (dev/vm/setup.sh)"
fi

[ "$ok" = 1 ] || { echo "no dev server is running" >&2; exit 1; }
