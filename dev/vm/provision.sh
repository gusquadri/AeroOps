#!/bin/sh
# Provision the AeroOps test VM. Runs INSIDE the VM as root; dev/vm/setup.sh
# copies it (with k8s/demo.yaml and the public keys) to /opt/aeroops and runs it.
# Idempotent: safe to run again; demo workloads are recreated every run.
set -eu
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

D=/opt/aeroops
log() { printf '\n==> %s\n' "$*"; }

# --- kubelet needs /dev/kmsg, which OrbStack machines do not have ---------
log "/dev/kmsg"
cat > /etc/tmpfiles.d/aeroops-kmsg.conf <<'EOF'
L /dev/kmsg - - - - /dev/console
EOF
[ -e /dev/kmsg ] || ln -s /dev/console /dev/kmsg

# --- packages -------------------------------------------------------------
log "packages"
need=
for p in openssh-server docker.io curl ca-certificates sudo; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || need="$need $p"
done
if [ -n "$need" ]; then
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $need >/dev/null
fi

# --- users ----------------------------------------------------------------
# dev:      key-only SSH, in the docker group, sudo only for "k3s kubectl".
# nodocker: key-only SSH, NOT in the docker group (exercises the docker
#           "permission denied" path), sudo only for "docker" (the app's
#           per-host "use sudo -n" toggle).
log "users"
for u in dev nodocker; do
  id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
  usermod -p '*' "$u"            # no password, but not "locked"
  install -d -o "$u" -g "$u" -m 700 "/home/$u/.ssh"
  ak="/home/$u/.ssh/authorized_keys"
  touch "$ak"
  if [ -f "$D/authorized_keys" ]; then
    while IFS= read -r k; do
      case "$k" in ssh-*|ecdsa-*|sk-*) grep -qxF "$k" "$ak" || printf '%s\n' "$k" >> "$ak" ;; esac
    done < "$D/authorized_keys"
  fi
  chown "$u:$u" "$ak"; chmod 600 "$ak"
done
usermod -aG docker dev
gpasswd -d nodocker docker >/dev/null 2>&1 || true

cat > /etc/sudoers.d/aeroops <<'EOF'
# AeroOps test VM: the narrowest sudo the app needs.
# k3s keeps /etc/rancher/k3s/k3s.yaml root-only, so the app uses the kubectl
# prefix "sudo -n k3s kubectl" for dev.
dev      ALL=(root) NOPASSWD: /usr/local/bin/k3s kubectl, /usr/local/bin/k3s kubectl *
# The docker "sudo -n" toggle, for the user without docker group access.
nodocker ALL=(root) NOPASSWD: /usr/bin/docker, /usr/bin/docker *
EOF
chmod 440 /etc/sudoers.d/aeroops
visudo -cf /etc/sudoers.d/aeroops >/dev/null

# --- sshd -----------------------------------------------------------------
log "sshd"
cat > /etc/ssh/sshd_config.d/10-aeroops.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers dev nodocker
EOF
mkdir -p /run/sshd                     # needed by "sshd -t"; normally made at start
sshd -t
# Ubuntu 24.04 socket-activates sshd: ssh.socket listens on :22 and starts
# ssh.service on the first connection; restart the service only if running.
systemctl enable --now ssh.socket >/dev/null 2>&1
systemctl try-restart ssh.service

# --- docker ---------------------------------------------------------------
log "docker"
systemctl enable --now docker >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && break; sleep 1; done

# --- k3s ------------------------------------------------------------------
# Default kubeconfig mode (0600 root) on purpose: the app's kubectl-prefix
# path ("sudo -n k3s kubectl") must be exercised. Extras disabled to save RAM.
# Pinned version: reproducible, and skips the update.k3s.io channel lookup
# (unreachable from this network when the VM was first built).
#
# OrbStack workaround: OrbStack machines run in a user namespace whose uid map
# looks like the host's ("0 0 4294967295"), so kubelet thinks it is not in a
# user namespace and, on kernels >= 6.4, mounts every tmpfs volume (including
# each pod's service-account token) with "-o noswap", which the kernel rejects
# here: every pod sticks in ContainerCreating with FailedMount. Showing k3s a
# pre-6.4 /proc/sys/kernel/osrelease makes kubelet test-mount noswap instead,
# see it fail, and leave the option out. Only k3s's mount namespace sees it.
# The same mis-detection stops k3s from setting containerd's
# restrict_oom_score_adj, so runc fails every pod sandbox with
# "failed to update /proc/self/oom_score_adj: Permission denied"; a containerd
# config template (k3s's generated config plus that one line) fixes it.
log "k3s"
mkdir -p /etc/aeroops /etc/systemd/system/k3s.service.d
echo "6.3.0-aeroops-kubelet-noswap-workaround" > /etc/aeroops/osrelease-for-k3s
cat > /etc/systemd/system/k3s.service.d/10-aeroops-noswap.conf <<'EOF'
[Service]
BindReadOnlyPaths=/etc/aeroops/osrelease-for-k3s:/proc/sys/kernel/osrelease
EOF
systemctl daemon-reload
K3S_VERSION=${K3S_VERSION:-v1.36.5+k3s1}
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="server \
    --disable=traefik --disable=servicelb --disable=metrics-server \
    --kube-proxy-arg=conntrack-max-per-core=0" sh -
fi
systemctl enable --now k3s >/dev/null 2>&1
ctd=/var/lib/rancher/k3s/agent/etc/containerd
i=0
until [ -f "$ctd/config.toml" ]; do
  i=$((i + 1)); [ "$i" -lt 60 ] || { echo "k3s wrote no containerd config" >&2; exit 1; }
  sleep 2
done
if ! grep -q restrict_oom_score_adj "$ctd/config-v3.toml.tmpl" 2>/dev/null; then
  sed -e '/^# File generated by k3s/d' \
      -e 's/^\(  device_ownership_from_security_context = .*\)$/\1\n  restrict_oom_score_adj = true  # aeroops: OrbStack userns/' \
      "$ctd/config.toml" > "$ctd/config-v3.toml.tmpl"
  grep -q restrict_oom_score_adj "$ctd/config-v3.toml.tmpl" || { echo "containerd template patch failed" >&2; exit 1; }
  systemctl restart k3s
fi
printf 'waiting for node Ready'
i=0
until k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; do
  i=$((i + 1)); [ "$i" -lt 120 ] || { echo " timed out" >&2; exit 1; }
  printf '.'; sleep 2
done
echo

# --- Kubernetes demo workloads (namespace "demo", recreated) --------------
log "k8s demo namespace"
k3s kubectl delete namespace demo --ignore-not-found --wait=true
k3s kubectl apply -f "$D/k8s/demo.yaml"

# --- Docker demo containers (recreated) -----------------------------------
log "docker demo containers"
docker rm -f demo-web demo-logger demo-exited >/dev/null 2>&1 || true
for img in nginx:1.27-alpine busybox:1.36 alpine:3.22; do docker pull -q "$img" >/dev/null; done

docker run -d --name demo-web --restart unless-stopped -p 8080:80 \
  --health-cmd 'wget -q -O /dev/null http://127.0.0.1/ || exit 1' \
  --health-interval 10s --health-start-period 5s \
  --label aeroops.demo=healthy nginx:1.27-alpine >/dev/null

docker run -d --name demo-logger --restart unless-stopped \
  --label aeroops.demo=logger busybox:1.36 sh -c "$(cat "$D/ansi-logger.sh")" >/dev/null

docker run --name demo-exited --label aeroops.demo=exited alpine:3.22 \
  sh -c 'echo "batch job starting"; echo "processed 42 records"; echo "fatal: /etc/job/config.yaml not found" >&2; exit 3' \
  >/dev/null 2>&1 || true

log "done"
docker ps -a --format 'table {{.Names}}\t{{.Status}}'
k3s kubectl get pods -n demo -o wide
