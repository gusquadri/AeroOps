import Foundation

/// One Kubernetes pod, from `kubectl get pods -A -o json`.
///
/// Built by ``KubernetesParser``. Also the row type of the MCP `list_pods` tool. Only the fields
/// the plan reads are kept: namespace, name, phase, container statuses, node, creation time,
/// resource limits, and CPU and memory use from the metrics API.
public struct PodInfo: Identifiable, Codable, Sendable, Hashable {
    /// Namespace.
    public var namespace: String
    /// Pod name.
    public var name: String
    /// `status.phase`.
    public var phase: PodPhase
    /// One entry per `spec.containers[]`, in spec order, merged with its `status.containerStatuses[]`
    /// entry. Containers without a status yet (e.g. an unscheduled pod) are not ready, with 0 restarts.
    public var containers: [PodContainerStatus]
    /// `spec.nodeName`; `nil` while unscheduled.
    public var nodeName: String?
    /// `metadata.creationTimestamp`, used for the age column.
    public var createdAt: Date?
    /// CPU in use, in millicores (rounded up, like `kubectl top`), from the metrics API
    /// (`metrics.k8s.io`). `nil` when the pod is not running or the cluster has no metrics-server.
    public var cpuMillicores: Int?
    /// Memory in use (working set), in bytes, from the metrics API. `nil` as ``cpuMillicores``.
    public var memUsedBytes: Int64?
    /// The pod's CPU limit, in millicores: `spec.resources.limits.cpu`, else the sum of the
    /// containers' limits. `nil` when a container has no CPU limit.
    public var cpuLimitMillicores: Int?
    /// The pod's memory limit, in bytes, chosen as ``cpuLimitMillicores``.
    public var memLimitBytes: Int64?
    /// The workload that manages the pod; `nil` for a bare pod.
    public var owner: PodOwner?

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
        createdAt: Date? = nil,
        cpuMillicores: Int? = nil,
        memUsedBytes: Int64? = nil,
        cpuLimitMillicores: Int? = nil,
        memLimitBytes: Int64? = nil,
        owner: PodOwner? = nil
    ) {
        self.namespace = namespace
        self.name = name
        self.phase = phase
        self.containers = containers
        self.nodeName = nodeName
        self.createdAt = createdAt
        self.cpuMillicores = cpuMillicores
        self.memUsedBytes = memUsedBytes
        self.cpuLimitMillicores = cpuLimitMillicores
        self.memLimitBytes = memLimitBytes
        self.owner = owner
    }
}

/// The workload that manages a pod: the controller among `metadata.ownerReferences`, with a
/// Deployment's ReplicaSet resolved to the Deployment (its name minus the `pod-template-hash`).
public struct PodOwner: Codable, Sendable, Hashable {
    /// `kind` as Kubernetes spells it: `Deployment`, `StatefulSet`, `ReplicaSet`, `DaemonSet`,
    /// `Job`, `Node` (a static pod), …
    public var kind: String
    /// The owner's name, in the pod's namespace.
    public var name: String

    /// Creates an owner.
    public init(kind: String, name: String) {
        self.kind = kind
        self.name = name
    }

    /// Kinds that `kubectl scale` works on.
    public static let scalableKinds: Set<String> = ["Deployment", "StatefulSet", "ReplicaSet", "ReplicationController"]
    /// Kinds that always replace a deleted pod. A Job may not (it stops once enough pods
    /// succeeded), and a static pod's Node only recreates the mirror object, not the containers.
    public static let recreatingKinds = scalableKinds.union(["DaemonSet"])

    /// Whether `kubectl scale` works on it.
    public var isScalable: Bool { Self.scalableKinds.contains(kind) }
    /// Whether it replaces a deleted pod with a new one.
    public var recreatesPods: Bool { Self.recreatingKinds.contains(kind) }
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
    /// `state.terminated.reason`, e.g. `Completed`, `Error`, `OOMKilled`.
    public var terminatedReason: String?
    /// `state.terminated.exitCode`; `nil` unless the container is currently terminated.
    public var exitCode: Int?

    /// Creates a container status.
    public init(
        name: String,
        ready: Bool,
        restartCount: Int = 0,
        waitingReason: String? = nil,
        terminatedReason: String? = nil,
        exitCode: Int? = nil
    ) {
        self.name = name
        self.ready = ready
        self.restartCount = restartCount
        self.waitingReason = waitingReason
        self.terminatedReason = terminatedReason
        self.exitCode = exitCode
    }

    /// `true` when the container is currently terminated (it has an exit code or a terminated reason).
    public var isTerminated: Bool { exitCode != nil || terminatedReason != nil }

    /// `true` when a previous instance exists, so `kubectl logs --previous` can work.
    public var hasPreviousInstance: Bool { restartCount > 0 }
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
