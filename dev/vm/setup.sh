#!/bin/sh
# Create (if missing) and provision the AeroOps test VM: an OrbStack Ubuntu
# 24.04 machine "aeroops-vm" with openssh-server, Docker, k3s and demo
# workloads. Idempotent; demo workloads are recreated on every run.
#
# Usage: dev/vm/setup.sh            create if missing, then provision
#        dev/vm/setup.sh --fresh    delete the machine first, rebuild from scratch
#
# Public keys in dev/keys/*.pub are authorized for the VM users dev and nodocker.
set -eu

VM=aeroops-vm
here=$(cd "$(dirname "$0")" && pwd)
devdir=$(dirname "$here")

fresh=0
case "${1:-}" in
  --fresh) fresh=1 ;;
  "") ;;
  *) echo "usage: $0 [--fresh]" >&2; exit 2 ;;
esac

command -v orb >/dev/null 2>&1 || { echo "OrbStack CLI 'orb' not found" >&2; exit 1; }

exists() { orb list -q | grep -qx "$VM"; }

if [ "$fresh" = 1 ] && exists; then
  echo "==> deleting $VM"
  orb delete -f "$VM"
fi

if ! exists; then
  echo "==> creating $VM (Ubuntu 24.04)"
  orb create --isolated --memory 2G --cpus 2 --disk 20G ubuntu:noble "$VM"
fi
orb start "$VM" >/dev/null 2>&1 || true

vm() { orb -m "$VM" -u root "$@"; }

echo "==> copying provisioning files"
vm mkdir -p /opt/aeroops/k8s
vm sh -c 'cat > /opt/aeroops/provision.sh'   < "$here/provision.sh"
vm sh -c 'cat > /opt/aeroops/ansi-logger.sh' < "$here/ansi-logger.sh"
vm sh -c 'cat > /opt/aeroops/k8s/demo.yaml'  < "$here/k8s/demo.yaml"
for f in "$devdir"/keys/*.pub; do
  [ -f "$f" ] && cat "$f"
done | vm sh -c 'cat > /opt/aeroops/authorized_keys'

vm sh /opt/aeroops/provision.sh

ip=$(orb info "$VM" | sed -n 's/^IPv4: *//p')
cat <<EOF

AeroOps test VM is ready.
  SSH:      ssh -p 22 dev@${ip:-<see: orb list>}   (key-only; dev/add-key.sh <key.pub> to authorize)
  Also:     nodocker@ the same address (no docker group; sudo -n docker allowed)
  kubectl:  sudo -n k3s kubectl get pods -A        (as dev)
  Root:     orb -m $VM -u root
EOF
