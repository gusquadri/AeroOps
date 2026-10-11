#!/bin/sh
# Start sshd for the BusyBox test server. Host keys persist in the
# "alpine-hostkeys" volume so the fingerprint survives container recreation;
# public keys from /pubkeys/*.pub (dev/keys) are authorized for dev.
set -eu
for t in ed25519 ecdsa; do
  f=/etc/ssh/hostkeys/ssh_host_${t}_key
  [ -f "$f" ] || ssh-keygen -q -t "$t" -N '' -f "$f"
done

install -d -o dev -g dev -m 700 /home/dev/.ssh
ak=/home/dev/.ssh/authorized_keys
touch "$ak"
for f in /pubkeys/*.pub; do
  [ -f "$f" ] || continue
  while IFS= read -r k; do
    case "$k" in ssh-*|ecdsa-*|sk-*) grep -qxF "$k" "$ak" || printf '%s\n' "$k" >> "$ak" ;; esac
  done < "$f"
done
chown dev:dev "$ak"
chmod 600 "$ak"

exec /usr/sbin/sshd -D -e
