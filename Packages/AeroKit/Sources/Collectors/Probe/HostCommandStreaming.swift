import AeroCore
import Foundation
import SSHKit

/// Streams the stdout lines of one long-running remote command (`docker logs -f`,
/// `kubectl logs -f`). ``SSHRunner`` is the only production conformer; tests substitute a
/// scripted fake.
///
/// Follows `SSHRunner.stream(_:on:stdin:timeout:maxBufferedLines:)`: the stream finishes
/// normally on exit 0, throws `SSHError` otherwise, and kills the local ssh process when the
/// consumer cancels or drops it.
public protocol HostCommandStreaming: Sendable {
    func stream(
        _ command: String,
        on host: RemoteHost,
        stdin: Data?,
        timeout: Duration?,
        maxBufferedLines: Int
    ) async throws -> AsyncThrowingStream<String, any Error>
}

extension SSHRunner: HostCommandStreaming {}

/// What the Docker, Kubernetes and log collectors need: ``HostCommandRunning`` for one-shot
/// commands plus ``HostCommandStreaming`` for follows. `SSHRunner` conforms to both.
public typealias RemoteCommandRunning = HostCommandRunning & HostCommandStreaming

/// Building blocks for the remote command strings of the collectors in this module.
enum RemoteShell {
    /// Prepended to every command so tool messages (sudo's above all) are not localized and
    /// error classification keeps working on hosts with a non-English locale.
    static let localePrefix = "LC_ALL=C"

    /// `LC_ALL=C sh -c '<script>'`: runs a multi-statement POSIX script whatever the login
    /// user's shell is. The login shell only has to parse one simple command.
    static func script(_ script: String) -> String {
        "\(localePrefix) sh -c \(ShellQuote.quote(script))"
    }

    /// The text to classify after a failed command: stderr, or stdout when stderr is empty
    /// (commands run with `2>&1` put their errors on stdout).
    static func errorText(_ result: SSHResult) -> String {
        let stderr = result.stderrString
        return stderr.allSatisfy(\.isWhitespace) ? result.stdoutString : stderr
    }

    /// Throws ssh's own failure (`SSHError`) if the command never ran.
    static func requireTransport(_ result: SSHResult) throws(SSHError) {
        if let error = result.transportError { throw error }
    }
}
