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
        if error is CancellationError { return nil }
        switch error {
        case let error as DockerError:
            let kind: Kind = switch error {
            case .permissionDenied, .sudoRefused, .notInstalled, .daemonNotRunning: .setup
            case .failed: .transient
            }
            return WorkloadIssue(title: error.errorDescription ?? "Docker failed.", hint: error.hint, kind: kind)
        case let error as KubectlError:
            let kind: Kind = switch error {
            case .kubeconfigUnreadable, .sudoRefused, .notInstalled, .connectionRefused: .setup
            case .noPreviousContainer, .invalidOutput, .failed: .transient
            }
            var issue = WorkloadIssue(title: error.errorDescription ?? "kubectl failed.", hint: error.hint, kind: kind)
            if case .kubeconfigUnreadable = error, host?.kubectlPrefix == nil {
                issue.suggestedPrefix = capabilities?.suggestedKubectlPrefix
            }
            return issue
        case let error as CollectorInputError:
            let kind: Kind = if case .invalidKubectlPrefix = error { .setup } else { .transient }
            return WorkloadIssue(title: error.errorDescription ?? "Invalid request.", hint: error.recoverySuggestion, kind: kind)
        case let error as SSHError:
            return from(error)
        default:
            return WorkloadIssue(title: error.localizedDescription, hint: nil, kind: .transient)
        }
    }

    private static func from(_ error: SSHError) -> WorkloadIssue? {
        let title = error.errorDescription ?? "ssh failed."
        switch error {
        case .authFailed:
            return WorkloadIssue(
                title: title,
                hint: "Authorize the host's key on the server (Test Connection in the host editor shows how), "
                    + "then press Refresh. AeroOps does not retry failed logins on its own.",
                kind: .access
            )
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
