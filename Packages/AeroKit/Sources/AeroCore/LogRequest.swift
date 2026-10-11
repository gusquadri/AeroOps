import Foundation

/// A request for container or pod logs, from the Logs sheet or the MCP `get_logs` tool.
///
/// Data shape only; Collectors turns it into a `docker logs` or `kubectl logs` command, quoting
/// every value with ``ShellQuote/quote(_:)``. `tail` is always clamped to `1...maxTail`.
public struct LogRequest: Codable, Sendable, Hashable {
    /// Whether the logs come from a Docker container or a Kubernetes pod.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// `docker logs <name>`.
        case container
        /// `kubectl logs -n <namespace> <name> [-c <container>]`.
        case pod
    }

    /// Hard cap on `tail` (2,000 log lines).
    public static let maxTail = 2000
    /// Default `tail` for the Logs sheet.
    public static let defaultTail = 500

    /// The host to read from (MCP host names are resolved to an id before this is built).
    public var hostId: UUID
    /// Container or pod.
    public var kind: Kind
    /// Container name or ID (``Kind/container``) or pod name (``Kind/pod``).
    public var name: String
    /// Pod namespace; `nil` means `default`. Ignored for containers.
    public var namespace: String?
    /// Container inside the pod; `nil` means the pod's default container. Ignored for containers.
    public var container: String?
    /// Number of trailing lines, clamped to `1...maxTail`.
    public var tail: Int {
        didSet { tail = Self.clampTail(tail) }
    }
    /// Only lines newer than this many seconds (`--since <n>s`); `nil` means no limit.
    public var sinceSeconds: Int?
    /// Logs of the previous (crashed) container instance (`kubectl logs --previous`). Pods only.
    public var previous: Bool
    /// Stream new lines until cancelled (`-f`). The MCP tool never sets this.
    public var follow: Bool

    /// Creates a request; `tail` is clamped to `1...maxTail`.
    public init(
        hostId: UUID,
        kind: Kind,
        name: String,
        namespace: String? = nil,
        container: String? = nil,
        tail: Int = LogRequest.defaultTail,
        sinceSeconds: Int? = nil,
        previous: Bool = false,
        follow: Bool = false
    ) {
        self.hostId = hostId
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.container = container
        self.tail = Self.clampTail(tail)
        self.sinceSeconds = sinceSeconds
        self.previous = previous
        self.follow = follow
    }

    /// `true` when every name (`name`, `namespace`, `container`) passes ``ShellQuote/isSafeName(_:)``
    /// and `sinceSeconds`, if set, is positive. Collectors must reject invalid requests.
    public var isValid: Bool {
        guard ShellQuote.isSafeName(name) else { return false }
        if let namespace, !ShellQuote.isSafeName(namespace) { return false }
        if let container, !ShellQuote.isSafeName(container) { return false }
        if let sinceSeconds, sinceSeconds <= 0 { return false }
        return true
    }

    private static func clampTail(_ value: Int) -> Int {
        min(max(value, 1), maxTail)
    }

    private enum CodingKeys: String, CodingKey {
        case hostId, kind, name, namespace, container, tail, sinceSeconds, previous, follow
    }

    /// Tolerant decoding: `hostId`, `kind` and `name` are required; the rest default; `tail` is clamped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostId: try c.decode(UUID.self, forKey: .hostId),
            kind: try c.decode(Kind.self, forKey: .kind),
            name: try c.decode(String.self, forKey: .name),
            namespace: try c.decodeIfPresent(String.self, forKey: .namespace),
            container: try c.decodeIfPresent(String.self, forKey: .container),
            tail: try c.decodeIfPresent(Int.self, forKey: .tail) ?? Self.defaultTail,
            sinceSeconds: try c.decodeIfPresent(Int.self, forKey: .sinceSeconds),
            previous: try c.decodeIfPresent(Bool.self, forKey: .previous) ?? false,
            follow: try c.decodeIfPresent(Bool.self, forKey: .follow) ?? false
        )
    }
}
