#!/bin/sh
# AeroOps capability probe. Run once per host, cached until the user refreshes.
# Run as: ssh aero-<id> 'LC_ALL=C sh -s' < probe.sh
# Prints one capability token per line, in this order, only when present:
#   docker podman kubectl k3s docker-ok kube-ok
export LC_ALL=C
command -v docker  >/dev/null && echo docker
command -v podman  >/dev/null && echo podman
command -v kubectl >/dev/null && echo kubectl
command -v k3s     >/dev/null && echo k3s
docker info >/dev/null 2>&1 && echo docker-ok
kubectl get ns --request-timeout=3s -o name >/dev/null 2>&1 && echo kube-ok
exit 0
