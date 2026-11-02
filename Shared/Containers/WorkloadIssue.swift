import AeroCore
import AeroTheme
import Collectors
import Foundation
import SSHKit

/// A problem to show in the Containers tab instead of (or above) a table, with the collectors'
/// user-facing hint and how polling should react.
struct WorkloadIssue: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Fix on the host or in the host's settings (docker group, sudo, kubeconfig, prefix):
        /// polling that section stops until Refresh or a host edit.
        case setup
        /// ssh can't sign in or the host key isn't trusted: all polling stops until Refresh, so a
        /// failing login is never retried in a loop (sshd penalises repeated auth failures).
        case access
        /// The service is installed but down (the Docker daemon, the Kubernetes API server): the
        /// section's rows are cleared and polling keeps checking, so it recovers once the service
        /// is back (after `systemctl restart docker`, a k3s restart, or a reboot).
        case unavailable
        /// May go away by itself (timeout, unreachable, a failed command): polling continues.
        case transient
    }

    var title: String
    var hint: String?
    var kind: Kind
    /// A kubectl prefix that would likely fix the problem (k3s: `sudo -n k3s kubectl`).
    var suggestedPrefix: String?

    /// Whether the host editor is the place to fix it.
    var offersHostEditor: Bool { kind != .transient }

    /// Maps a collector, SSH or input error. `nil` for cancellation.
    static func from(_ error: any Error, capabilities: HostCapabilities? = nil, host: RemoteHost? = nil) -> WorkloadIssue? {
        switch error {
        case is CancellationError:
            return nil
        case let error as DockerError:
            return dockerIssue(error)
        case let error as KubectlError:
            return kubectlIssue(error, capabilities: capabilities, host: host)
        case let error as CollectorInputError:
            return inputIssue(error)
        case let error as SSHError:
            return sshIssue(error, host: host)
        default:
            return WorkloadIssue(title: error.localizedDescription, hint: nil, kind: .transient)
        }
    }

    private static func dockerIssue(_ error: DockerError) -> WorkloadIssue {
        let kind: Kind = switch error {
        case .permissionDenied, .sudoRefused, .notInstalled: .setup
        case .daemonNotRunning: .unavailable
        case .failed: .transient
        }
        return WorkloadIssue(title: error.errorDescription ?? "Docker failed.", hint: hint(error.hint, kind), kind: kind)
    }

    private static func kubectlIssue(_ error: KubectlError, capabilities: HostCapabilities?, host: RemoteHost?) -> WorkloadIssue {
        let kind: Kind = switch error {
        case .kubeconfigUnreadable, .sudoRefused, .notInstalled: .setup
        case .connectionRefused: .unavailable
        case .noPreviousContainer, .invalidOutput, .failed: .transient
        }
        var issue = WorkloadIssue(title: error.errorDescription ?? "kubectl failed.", hint: hint(error.hint, kind), kind: kind)
        if case .kubeconfigUnreadable = error, host?.kubectlPrefix == nil {
            issue.suggestedPrefix = capabilities?.suggestedKubectlPrefix
        }
        return issue
    }

    private static func inputIssue(_ error: CollectorInputError) -> WorkloadIssue {
        let kind: Kind = if case .invalidKubectlPrefix = error { .setup } else { .transient }
        return WorkloadIssue(title: error.errorDescription ?? "Invalid request.", hint: error.recoverySuggestion, kind: kind)
    }

    /// The collector's hint, telling the user that AeroOps keeps checking a service that is down.
    private static func hint(_ hint: String?, _ kind: Kind) -> String? {
        guard kind == .unavailable else { return hint }
        return [hint, "AeroOps keeps checking."].compactMap(\.self).joined(separator: " ")
    }

    private static func sshIssue(_ error: SSHError, host: RemoteHost?) -> WorkloadIssue {
        let title = error.errorDescription ?? "ssh failed."
        switch error {
        case .authFailed:
            return WorkloadIssue(title: title, hint: authFailedHint(host), kind: .access)
        case .hostKeyUnknown:
            return WorkloadIssue(
                title: title,
                hint: "Open the host editor and run Test Connection to review and trust the host key.",
                kind: .access
            )
        case .hostKeyChanged:
            return WorkloadIssue(
                title: title,
                hint: "Review the new key in the host editor before connecting again.",
                kind: .access
            )
        case .timeout, .hostUnreachable, .connectionRefused, .nameResolutionFailed, .connectionClosed:
            return WorkloadIssue(title: title, hint: "Check that the host is up and reachable. AeroOps keeps trying.", kind: .transient)
        case .remoteCommandFailed, .launchFailed, .invalidRequest, .other:
            return WorkloadIssue(title: title, hint: nil, kind: .transient)
        }
    }

    private static func authFailedHint(_ host: RemoteHost?) -> String {
        if host?.auth == .password {
            return "Save the host's password in the host editor (Test Connection checks it), then press Refresh. "
                + "AeroOps does not retry a rejected password on its own."
        }
        return "Authorize the host's key on the server (Test Connection in the host editor shows how), "
            + "then press Refresh. AeroOps does not retry failed logins on its own."
    }
}

extension WorkloadHealth {
    /// The orb and tag colour for a container or pod row.
    var workloadTone: OrbTone {
        switch self {
        case .healthy: .healthy
        case .warning: .warning
        case .failing: .error
        case .inactive: .neutral
        }
    }
}
