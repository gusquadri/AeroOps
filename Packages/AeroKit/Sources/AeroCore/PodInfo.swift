import Foundation

/// One Kubernetes pod, from `kubectl get pods -A -o json`.
///
/// Data shape only; the parser lives in Collectors. Also the row type of the MCP `list_pods`
/// tool. Only the fields the plan reads are kept: namespace, name, phase, container statuses,
/// node and creation time.
public struct PodInfo: Identifiable, Codable, Sendable, Hashable {
    /// Namespace.
    public var namespace: String
    /// Pod name.
    public var name: String
    /// `status.phase`.
    public var phase: PodPhase
    /// `status.containerStatuses[]`, in spec order.
    public var containers: [PodContainerStatus]
    /// `spec.nodeName`; `nil` while unscheduled.
    public var nodeName: String?
    /// `metadata.creationTimestamp`, used for the age column.
    public var createdAt: Date?

    /// Identity is `namespace/name`.
    public var id: String { "\(namespace)/\(name)" }
    /// Number of ready containers (the x in "x/y ready").
    public var readyCount: Int { containers.count(where: \.ready) }
    /// Number of containers (the y in "x/y ready").
    public var containerCount: Int { containers.count }
    /// Sum of container restart counts.
    public var restarts: Int { containers.reduce(0) { $0 + $1.restartCount } }

    /// Creates a pod row.
    public init(
        namespace: String,
        name: String,
        phase: PodPhase,
        containers: [PodContainerStatus] = [],
        nodeName: String? = nil,
        createdAt: Date? = nil
    ) {
        self.namespace = namespace
        self.name = name
        self.phase = phase
        self.containers = containers
        self.nodeName = nodeName
        self.createdAt = createdAt
    }
}

/// One entry of a pod's `status.containerStatuses[]`.
public struct PodContainerStatus: Codable, Sendable, Hashable {
    /// Container name (used by the logs container picker).
    public var name: String
    /// `ready`.
    public var ready: Bool
    /// `restartCount`.
    public var restartCount: Int
    /// `state.waiting.reason`, e.g. `CrashLoopBackOff`, `ImagePullBackOff`, `ContainerCreating`.
    public var waitingReason: String?

    /// Creates a container status.
    public init(name: String, ready: Bool, restartCount: Int = 0, waitingReason: String? = nil) {
        self.name = name
        self.ready = ready
        self.restartCount = restartCount
        self.waitingReason = waitingReason
    }
}

/// Kubernetes pod phase. Raw values match `status.phase`.
public enum PodPhase: String, Codable, Sendable, Hashable, CaseIterable {
    case pending = "Pending"
    case running = "Running"
    case succeeded = "Succeeded"
    case failed = "Failed"
    case unknown = "Unknown"

    /// Tolerant decoding: unrecognised strings become ``unknown``.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PodPhase(rawValue: raw) ?? .unknown
    }
}
