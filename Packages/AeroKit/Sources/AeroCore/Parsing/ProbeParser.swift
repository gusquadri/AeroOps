import Foundation

/// What `Scripts/remote/probe.sh` found on a host. Cached per host until the user refreshes.
///
/// ```swift
/// let caps = HostCapabilities(probeOutput: stdout)
/// if caps.dockerNeedsSetup { showDockerPermissionHint() }
/// ```
public struct HostCapabilities: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `docker` is on the PATH.
    public static let docker = HostCapabilities(rawValue: 1 << 0)
    /// `podman` is on the PATH.
    public static let podman = HostCapabilities(rawValue: 1 << 1)
    /// `kubectl` is on the PATH.
    public static let kubectl = HostCapabilities(rawValue: 1 << 2)
    /// `k3s` is on the PATH.
    public static let k3s = HostCapabilities(rawValue: 1 << 3)
    /// `docker info` succeeded as the login user.
    public static let dockerOK = HostCapabilities(rawValue: 1 << 4)
    /// `kubectl get ns` reached a cluster as the login user.
    public static let kubeOK = HostCapabilities(rawValue: 1 << 5)

    /// The probe's output tokens, in the order the script prints them.
    public static let tokens: [(token: String, capability: HostCapabilities)] = [
        ("docker", .docker), ("podman", .podman), ("kubectl", .kubectl), ("k3s", .k3s),
        ("docker-ok", .dockerOK), ("kube-ok", .kubeOK),
    ]

    /// Parses probe output: one token per line (whitespace-separated tokens are accepted too).
    /// Unknown tokens and junk are ignored; empty output means nothing is installed.
    public init(probeOutput: String) {
        self = []
        for word in probeOutput.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if let match = Self.tokens.first(where: { $0.token == word }) { insert(match.capability) }
        }
    }

    /// Docker is installed but `docker info` failed for this user: usually permission denied on
    /// the socket. Show the docker-group hint and the per-host "use `sudo -n`" option.
    public var dockerNeedsSetup: Bool { contains(.docker) && !contains(.dockerOK) }

    /// kubectl or k3s is installed but no cluster was reachable as this user.
    public var kubernetesNeedsSetup: Bool { !isDisjoint(with: [.kubectl, .k3s]) && !contains(.kubeOK) }

    /// The kubectl prefix to suggest when plain kubectl cannot reach the cluster: on k3s the
    /// kubeconfig is root-only, so `sudo -n k3s kubectl`. `nil` when no suggestion applies.
    public var suggestedKubectlPrefix: String? {
        kubernetesNeedsSetup && contains(.k3s) ? "sudo -n k3s kubectl" : nil
    }
}
