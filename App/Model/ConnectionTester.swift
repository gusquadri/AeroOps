import AeroCore
import Foundation

/// Checks that a host is reachable with its configured address, port, user and key.
/// Settings › Hosts' **Test connection** button calls it with the (possibly unsaved) draft.
///
/// Phase 1 ships ``SimulatedConnectionTester``. Phase 2 adds an SSHKit-backed implementation
/// (`ssh -F ~/.aeroops/ssh_config aero-<id> true` through the in-app agent) and passes it to
/// ``AppModel/init(hostStore:connectionTester:)`` in `AeroOpsApp`; no view changes.
///
/// Implementations must honour task cancellation: the editor cancels a running test when the
/// connection fields change or the form goes away.
protocol ConnectionTester: Sendable {
    func testConnection(to host: RemoteHost) async -> ConnectionTestResult
}

/// The outcome of a ``ConnectionTester`` run.
struct ConnectionTestResult: Sendable, Hashable {
    enum Outcome: Sendable, Hashable {
        case success
        case failure
    }

    var outcome: Outcome
    /// One line for the UI, e.g. "Connected as deploy" or "Permission denied (publickey)".
    var message: String
    /// Wall-clock time the test took.
    var elapsed: Duration

    var succeeded: Bool { outcome == .success }
}

/// Phase 1 stand-in for the real SSH test: waits a moment, then reports a simulated result
/// without opening any connection.
///
/// Addresses under the reserved `.invalid` and `.test` TLDs (RFC 2606) simulate a failure, so
/// the failure path can be seen in previews and by hand.
struct SimulatedConnectionTester: ConnectionTester {
    /// How long the simulated test takes.
    var delay: Duration = .milliseconds(1200)

    func testConnection(to host: RemoteHost) async -> ConnectionTestResult {
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
            message: "Simulated success for \(host.user)@\(host.address):\(host.port). No SSH connection was made; real tests arrive with SSH key support.",
            elapsed: elapsed
        )
    }
}
