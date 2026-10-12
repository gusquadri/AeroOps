import AeroCore
import Foundation
import SSHKit

/// Checks that a host is reachable with its configured address, port, user and key or password.
/// Settings › Hosts' **Test connection** button calls it with the (possibly unsaved) draft.
///
/// The app uses ``SSHConnectionTester`` (`ssh … uname -sr` through SSHKit and the in-app agent);
/// previews use ``SimulatedConnectionTester``.
///
/// Implementations must honour task cancellation: the editor cancels a running test when the
/// connection fields change or the form goes away. They must not retry on their own: OpenSSH 9.8+
/// (`PerSourcePenalties`) bans addresses that fail authentication repeatedly.
protocol ConnectionTester: Sendable {
    /// - Parameter password: For a password host, a password typed in the editor to try instead
    ///   of the saved one. It is not saved.
    func testConnection(to host: RemoteHost, password: String?) async -> ConnectionTestResult
}

extension ConnectionTester {
    /// Tests `host` with what is saved for it.
    func testConnection(to host: RemoteHost) async -> ConnectionTestResult {
        await testConnection(to: host, password: nil)
    }
}

/// The outcome of a ``ConnectionTester`` run.
struct ConnectionTestResult: Sendable, Hashable {
    enum Outcome: Sendable, Hashable {
        case success
        case failure
        /// First contact: nothing is pinned for the host yet. The editor shows the offered keys
        /// for the user to trust or cancel; no login was attempted.
        case hostKeyUnknown(offered: [HostKey])
        /// The host presented a key other than the pinned one. The host is blocked until the user
        /// reviews the change.
        case hostKeyChanged(HostKeyBlock)
    }

    var outcome: Outcome
    /// One line for the UI, e.g. "Connected as deploy" or "Permission denied (publickey)".
    var message: String
    /// Wall-clock time the test took.
    var elapsed: Duration
    /// A follow-up suggestion shown under the message.
    var hint: String? = nil
    /// Set when the server rejected the key: the editor offers "Copy authorized_keys line".
    var keyToAuthorize: UUID? = nil

    var succeeded: Bool { outcome == .success }
}

/// Stand-in for the real SSH test in previews: waits a moment, then reports a simulated result
/// without opening any connection.
///
/// Addresses under the reserved `.invalid` and `.test` TLDs (RFC 2606) simulate a failure, so
/// the failure path can be seen in previews.
struct SimulatedConnectionTester: ConnectionTester {
    /// How long the simulated test takes.
    var delay: Duration = .milliseconds(1200)

    func testConnection(to host: RemoteHost, password: String?) async -> ConnectionTestResult {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await Task.sleep(for: delay)
        } catch {
            return ConnectionTestResult(outcome: .failure, message: "Test cancelled.", elapsed: start.duration(to: clock.now))
        }
        let elapsed = start.duration(to: clock.now)
        let address = host.address.lowercased()
        if address.hasSuffix(".invalid") || address.hasSuffix(".test") {
            return ConnectionTestResult(
                outcome: .failure,
                message: "Simulated failure: \(host.address) could not be resolved.",
                elapsed: elapsed
            )
        }
        return ConnectionTestResult(
            outcome: .success,
            message: "Simulated success for \(host.user)@\(host.address):\(host.port). No SSH connection was made.",
            elapsed: elapsed
        )
    }
}
