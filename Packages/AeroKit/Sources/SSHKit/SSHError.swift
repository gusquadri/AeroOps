import Foundation

/// Why an ssh invocation failed.
///
/// `ssh` exits with 255 for its own errors and with the remote command's status otherwise, so
/// transport failures are told apart by ``classify(stderr:)``, which matches OpenSSH's messages
/// (checked against OpenSSH 10.3). A remote command that itself exits 255 is indistinguishable
/// from a transport failure; it classifies as ``other(_:)`` unless its stderr imitates ssh.
public enum SSHError: Error, Sendable, Hashable, LocalizedError {
    /// No pinned key for the host (`No ED25519 host key is known for ...`). Run the TOFU flow.
    case hostKeyUnknown
    /// The server's key differs from the pinned one (`REMOTE HOST IDENTIFICATION HAS CHANGED`).
    /// The host is blocked until the user decides.
    case hostKeyChanged
    /// `Permission denied (publickey,...)`: the key is not authorized, the agent is locked, or the
    /// password was rejected (or, for a password host, there is none to try).
    case authFailed
    /// Nothing listens on the port.
    case connectionRefused
    /// `ConnectTimeout` expired, the banner exchange timed out, or SSHKit's own deadline passed.
    case timeout
    /// `No route to host`, `Network is unreachable`, `Host is down`.
    case hostUnreachable
    /// DNS lookup failed.
    case nameResolutionFailed
    /// The server closed or reset the connection during setup.
    case connectionClosed
    /// `/usr/bin/ssh` (or `ssh-keyscan`) could not be started.
    case launchFailed(String)
    /// The remote command ran and exited non-zero (only produced by checked results and streams).
    case remoteCommandFailed(exitCode: Int32, stderr: String)
    /// The caller passed something SSHKit refuses to send (empty command, NUL byte, bad alias).
    case invalidRequest(String)
    /// Anything else; carries ssh's (trimmed, capped) stderr.
    case other(String)

    /// Longest stderr kept in ``other(_:)`` and ``remoteCommandFailed(exitCode:stderr:)``.
    static let messageLimit = 4096

    /// How `aeroops-askpass` starts its error messages on ssh's stderr.
    public static let askpassMarker = "aeroops-askpass: "

    /// Maps ssh's stderr (after exit status 255) to an error.
    public static func classify(stderr: String) -> SSHError {
        let text = stderr
        // Order matters: the "changed" banner also ends in "Host key verification failed.".
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
            || (text.contains("Host key for ") && text.contains(" has changed"))
            || text.contains("POSSIBLE DNS SPOOFING DETECTED") {
            return .hostKeyChanged
        }
        if text.contains("host key is known for") || text.contains("Host key verification failed.") {
            return .hostKeyUnknown
        }
        if text.contains("Permission denied (")
            || text.contains(askpassMarker)
            || text.contains("Too many authentication failures")
            || text.contains("No more authentication methods") {
            return .authFailed
        }
        if text.contains("Could not resolve hostname")
            || text.contains("nodename nor servname provided")
            || text.contains("Name or service not known")
            || text.contains("Temporary failure in name resolution")
            || text.contains("getaddrinfo") {
            return .nameResolutionFailed
        }
        if text.contains("Connection refused") && (text.contains("ssh: connect to host") || text.contains("connect failed")) {
            return .connectionRefused
        }
        if text.contains("Operation timed out")
            || text.contains("Connection timed out")
            || text.contains("timed out during banner exchange") {
            return .timeout
        }
        if text.contains("No route to host")
            || text.contains("Network is unreachable")
            || text.contains("Host is down") {
            return .hostUnreachable
        }
        if text.contains("Connection closed by")
            || text.contains("Connection reset by")
            || text.contains("kex_exchange_identification")
            || text.contains("ssh_dispatch_run_fatal") {
            return .connectionClosed
        }
        return .other(trimmed(text))
    }

    /// Trims whitespace (including ssh's `\r\n` line ends) and caps the length.
    static func trimmed(_ text: String) -> String {
        let clean = text.replacing("\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > messageLimit else { return clean }
        return String(clean.prefix(messageLimit)) + "…"
    }

    public var errorDescription: String? {
        switch self {
        case .hostKeyUnknown: "The host key is not trusted yet."
        case .hostKeyChanged: "The host key has changed. Connections are blocked until you review it."
        case .authFailed: "Authentication failed. Check the host's key or password."
        case .connectionRefused: "The connection was refused."
        case .timeout: "The connection timed out."
        case .hostUnreachable: "The host is unreachable."
        case .nameResolutionFailed: "The host name could not be resolved."
        case .connectionClosed: "The server closed the connection."
        case .launchFailed(let reason): "Could not start ssh: \(reason)"
        case .remoteCommandFailed(let code, let stderr):
            stderr.isEmpty ? "The remote command failed with exit status \(code)." : "The remote command failed with exit status \(code): \(stderr)"
        case .invalidRequest(let reason): "Invalid ssh request: \(reason)"
        case .other(let stderr): stderr.isEmpty ? "ssh failed without an error message." : stderr
        }
    }
}
