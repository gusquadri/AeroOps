import AeroCore
import Foundation

/// Hard limits shared by the app and the CLI.
public enum BridgeLimits {
    /// Longest request line the app accepts (1 MiB). Longer lines fail with `malformed_request`.
    public static let maxRequestLineBytes = 1 << 20
    /// Longest reply line the CLI accepts (16 MiB): two 64 KB outputs or 1 MiB of logs, JSON-escaped.
    public static let maxReplyLineBytes = 16 << 20
    /// Most requests one connection may have in flight.
    public static let maxConcurrentRequestsPerConnection = 32

    /// Longest `run_command` command, in UTF-8 bytes.
    public static let maxCommandBytes = 16 * 1024
    /// Longest `run_command` reason, in characters.
    public static let maxReasonCharacters = 1000
    /// Longest `host` argument, in UTF-8 bytes.
    public static let maxHostQueryBytes = 256
    /// Longest container, pod, namespace or tag name.
    public static let maxNameLength = 253

    /// Most log lines `get_logs` returns.
    public static let maxTail = LogRequest.maxTail
    /// `get_logs` lines when `tail` is not given.
    public static let defaultTail = 200
    /// Most bytes of log text `get_logs` returns.
    public static let maxLogBytes = LogText.defaultMaxBytes
    /// Longest `since` window: 30 days.
    public static let maxSinceSeconds = 30 * 24 * 3600

    /// `run_command` timeout range, in seconds.
    public static let timeoutRange = 1...300
    /// `run_command` timeout when `timeoutSec` is not given.
    public static let defaultTimeoutSeconds = 60
    /// Cap on each of stdout and stderr of `run_command` (64 KB).
    public static let maxCommandOutputBytes = 64 * 1024

    public static let maxPathBytes = 4096
    public static let maxListedFiles = 1000
}
