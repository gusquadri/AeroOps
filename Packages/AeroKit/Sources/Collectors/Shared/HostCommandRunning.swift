import AeroCore
import Foundation
import SSHKit

/// Runs one remote command to completion. ``SSHRunner`` is the only production conformer;
/// tests substitute a scripted fake so collectors can be exercised without a server.
///
/// Follows ``SSHRunner/run(_:on:stdin:timeout:outputLimit:)``: transport failures and the
/// remote exit status come back in the ``SSHResult``; the call throws only for requests that
/// never reached ssh (a blocked host, an invalid request, a launch failure) and for task
/// cancellation (`CancellationError`, after the process was killed).
public protocol HostCommandRunning: Sendable {
    func run(
        _ command: String,
        on host: RemoteHost,
        stdin: Data?,
        timeout: Duration,
        outputLimit: Int
    ) async throws -> SSHResult
}

extension SSHRunner: HostCommandRunning {}
