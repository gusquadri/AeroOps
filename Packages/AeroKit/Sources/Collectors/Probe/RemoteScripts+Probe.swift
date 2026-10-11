// Embeds Scripts/remote/probe.sh. Do not edit the text below by hand: edit the script, then
// paste it between the delimiters. `ProbeScriptTests` fails until both are byte-identical.

extension RemoteScripts {
    /// `Scripts/remote/probe.sh`, byte for byte: the one-time capability probe.
    /// Run it as ``RemoteScripts/shellCommand`` with this text on stdin and
    /// parse the output with `HostCapabilities(probeOutput:)`; ``CapabilityCache`` does both.
    public static let probe: String = #"""
#!/bin/sh
# AeroOps capability probe. Run once per host, cached until the user refreshes.
# Run as: ssh aero-<id> 'LC_ALL=C sh -s' < probe.sh
# Prints one capability token per line, in this order, only when present:
#   docker podman kubectl k3s docker-ok kube-ok
# POSIX sh, BusyBox-compatible.
#
# Changes from the first version of this script:
# 1. "export LC_ALL=C" at the top (same reason as metrics.sh).
# 2. "exit 0" at the end. Without it the script's exit status was that of the
#    last "&&" list, so every host without a working kubectl failed: 127 where
#    kubectl is not installed (measured on the dev container), 1 where it
#    exists but cannot reach a cluster. A caller that checks the exit status
#    would treat a successful probe as a failure. Exit status is now 0
#    whenever the probe ran.
export LC_ALL=C
command -v docker  >/dev/null && echo docker
command -v podman  >/dev/null && echo podman
command -v kubectl >/dev/null && echo kubectl
command -v k3s     >/dev/null && echo k3s
docker info >/dev/null 2>&1 && echo docker-ok
kubectl get ns --request-timeout=3s -o name >/dev/null 2>&1 && echo kube-ok
exit 0

"""#
}
