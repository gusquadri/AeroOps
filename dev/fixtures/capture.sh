#!/bin/sh
# Re-capture every fixture in dev/fixtures/ from the dev servers.
# Needs: aeroops-ssh, aeroops-alpine and aeroops-vm running, a key authorized
# on all of them (dev/add-key.sh), Docker on the Mac (for the Debian sample).
# Usage: dev/fixtures/capture.sh [metrics] [probe] [docker] [kubectl]   (default: all)
#   SSH="ssh -i /path/to/key -o IdentitiesOnly=yes" dev/fixtures/capture.sh
# The kubectl section first waits (up to ~6 min) until the crasher pod's
# container is in waiting/CrashLoopBackOff; between back-offs Kubernetes shows
# it as terminated/Error instead.
# Everything goes through ssh exactly as the app runs it, except the Debian
# sample (docker exec: no sshd), the macOS sample (local) and vm-root probe (orb).
set -u
SSH=${SSH:-ssh}
VMHOST=${VMHOST:-aeroops-vm.orb.local}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
M="$root/Scripts/remote/metrics.sh"
P="$root/Scripts/remote/probe.sh"
cd "$here" || exit 1
mkdir -p metrics probe docker kubectl

# shellcheck disable=SC2086  # $SSH is a command line
dev()      { $SSH "dev@$VMHOST" "$@"; }
# shellcheck disable=SC2086
nodocker() { $SSH "nodocker@$VMHOST" "$@"; }
# shellcheck disable=SC2086
devc()     { $SSH -p 2222 dev@localhost "$@"; }
# shellcheck disable=SC2086
alp()      { $SSH -p 2223 dev@localhost "$@"; }
K='sudo -n k3s kubectl'
# Run "$@" capturing stdout+stderr into $1 and appending the exit status.
witherr()  { out=$1; shift; "$@" > "$out" 2>&1; echo "[exit status $?]" >> "$out"; }
sections=$*
want()     { [ -z "$sections" ] && return 0; case " $sections " in *" $1 "*) return 0 ;; esac; return 1; }

if want metrics; then
echo "metrics: two samples ~2 s apart per host"
dev  'LC_ALL=C sh -s' < "$M" > metrics/ubuntu-vm-1.txt;     sleep 2
dev  'LC_ALL=C sh -s' < "$M" > metrics/ubuntu-vm-2.txt
devc 'LC_ALL=C sh -s' < "$M" > metrics/devcontainer-1.txt;  sleep 2
devc 'LC_ALL=C sh -s' < "$M" > metrics/devcontainer-2.txt
alp  'LC_ALL=C sh -s' < "$M" > metrics/alpine-busybox-1.txt; sleep 2
alp  'LC_ALL=C sh -s' < "$M" > metrics/alpine-busybox-2.txt
docker rm -f aeroops-fx-debian >/dev/null 2>&1
docker run -d --name aeroops-fx-debian --hostname debian-fixture debian:stable-slim sleep 60 >/dev/null
docker exec -i aeroops-fx-debian env LC_ALL=C sh -s < "$M" > metrics/debian-1.txt; sleep 2
docker exec -i aeroops-fx-debian env LC_ALL=C sh -s < "$M" > metrics/debian-2.txt
docker rm -f aeroops-fx-debian >/dev/null
# Old kernel (< 3.14, no MemAvailable): hand-made from ubuntu-vm-1.
sed -e '/^MemAvailable:/d' \
    -e 's/^Linux [^ ]* aarch64$/Linux 3.10.0-1160.el7.x86_64 x86_64/' \
    -e 's/^aeroops-vm$/oldkernel-fixture/' \
    metrics/ubuntu-vm-1.txt > metrics/synthetic-oldkernel-no-memavailable.txt
# Non-Linux: the real script on this Mac, sanitized (host name, home, volumes).
if [ "$(uname -s)" = Darwin ]; then
  LC_ALL=C sh -s < "$M" > metrics/nonlinux-darwin.txt 2> metrics/nonlinux-darwin.stderr.txt
  h=$(hostname)
  # Mount points under /Volumes/ (the last column) become /Volumes/External<n>;
  # the column alignment before them is kept.
  sed -e "s#$h#mac-fixture.local#g" -e "s#$HOME#/Users/dev#g" metrics/nonlinux-darwin.txt |
    awk 'match($0, /[ \t]\/Volumes\/[^\/]*$/) { n++; $0 = substr($0, 1, RSTART) "/Volumes/External" n }
         { print }' > metrics/nonlinux-darwin.tmp &&
    mv metrics/nonlinux-darwin.tmp metrics/nonlinux-darwin.txt
fi
fi

if want probe; then
echo "probe"
dev      'LC_ALL=C sh -s' < "$P" > probe/vm-dev.txt
nodocker 'LC_ALL=C sh -s' < "$P" > probe/vm-nodocker.txt
orb -m aeroops-vm -u root sh -c 'LC_ALL=C sh -s' < "$P" > probe/vm-root.txt
devc     'LC_ALL=C sh -s' < "$P" > probe/devcontainer.txt
alp      'LC_ALL=C sh -s' < "$P" > probe/alpine-busybox.txt
fi

if want docker; then
echo "docker"
dev "docker ps -a --no-trunc --format '{{json .}}'"      > docker/ps-a.jsonl
dev "docker stats --no-stream --format '{{json .}}'"     > docker/stats.jsonl
dev 'docker inspect demo-web'                             > docker/inspect-demo-web.json
dev 'docker logs --tail 50 --timestamps demo-logger 2>&1' > docker/logs-demo-logger.txt
dev 'docker logs --tail 50 --timestamps demo-exited 2>&1' > docker/logs-demo-exited.txt
witherr docker/error-permission-denied.txt nodocker "docker ps -a --no-trunc --format '{{json .}}'"
nodocker "sudo -n docker ps -a --no-trunc --format '{{json .}}'" > docker/ps-a-via-sudo.jsonl
fi

if want kubectl; then
echo "kubectl: waiting for crasher to be in CrashLoopBackOff"
i=0
until [ "$(dev "$K get pods -n demo -l app=crasher -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}'")" = CrashLoopBackOff ]; do
  i=$((i + 1)); [ "$i" -lt 80 ] || { echo "crasher never reached CrashLoopBackOff" >&2; exit 1; }
  sleep 5
done
crasher=$(dev "$K get pods -n demo -l app=crasher -o jsonpath='{.items[0].metadata.name}'")
pending=$(dev "$K get pods -n demo -l app=pending -o jsonpath='{.items[0].metadata.name}'")
web=$(dev "$K get pods -n demo -l app=web -o jsonpath='{.items[0].metadata.name}'")
dev "$K get pods -A -o json" > kubectl/pods-all.json
dev "$K get events -n demo --field-selector involvedObject.name=$crasher -o json" > kubectl/events-crasher.json
dev "$K get events -n demo --field-selector involvedObject.name=$pending -o json" > kubectl/events-pending.json
dev "$K logs -n demo $crasher -c crasher --previous --tail=500 --timestamps" > kubectl/logs-crasher-previous.txt 2>&1
dev "$K logs -n demo $web -c log-sidecar --tail=20 --timestamps" > kubectl/logs-web-log-sidecar.txt
dev "$K describe pod -n demo $crasher" > kubectl/describe-crasher.txt
witherr kubectl/error-no-previous-container.txt dev "$K logs -n demo $web -c nginx --previous --tail=500 --timestamps"
witherr kubectl/error-kubeconfig-unreadable.txt dev 'kubectl get pods -A -o json'
witherr kubectl/error-sudo-not-allowed.txt nodocker "$K get pods -A -o json"
fi
echo "done"
