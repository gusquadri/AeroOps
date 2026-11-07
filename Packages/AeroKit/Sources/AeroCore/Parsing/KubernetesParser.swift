import Foundation

/// Parses kubectl JSON output.
///
/// ```swift
/// let pods = try KubernetesParser.parsePods(stdout)       // kubectl get pods -A -o json
/// let events = try KubernetesParser.parseEvents(stdout)   // kubectl get events ... -o json
/// ```
/// When kubectl exits non-zero, classify its stderr with ``KubectlError/classify(_:)``.
public enum KubernetesParser {
    /// Parses `kubectl get pods -A -o json` (a `List`/`PodList`, or a single `Pod`), merged with
    /// `kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods` (a `PodMetricsList`).
    /// Pods without a name are skipped; one undecodable pod does not hide the others.
    ///
    /// Metrics attach by namespace and name; pods without metrics (not running, or no
    /// metrics-server, so `metrics` is empty or an error) have `nil` CPU and memory use.
    ///
    /// - Throws: ``KubectlError``: a known error when the text is a kubectl/sudo error message,
    ///   otherwise ``KubectlError/invalidOutput``.
    public static func parsePods(_ data: Data, metrics: Data = Data()) throws(KubectlError) -> [PodInfo] {
        var pods: [PodInfo]
        if let list = decodeJSONTolerantly(ListJSON<PodJSON>.self, from: data), let items = list.items {
            pods = items.elements.compactMap { $0.pod() }
        } else if let single = decodeJSONTolerantly(PodJSON.self, from: data), let pod = single.pod() {
            pods = [pod]
        } else {
            throw failure(data)
        }
        let usage = parsePodMetrics(metrics)
        guard !usage.isEmpty else { return pods }
        let byID = Dictionary(usage.map { ("\($0.namespace)/\($0.name)", $0) }, uniquingKeysWith: { first, _ in first })
        for index in pods.indices {
            guard let entry = byID[pods[index].id] else { continue }
            pods[index].cpuMillicores = entry.cpuMillicores
            pods[index].memUsedBytes = entry.memUsedBytes
        }
        return pods
    }

    /// Parses `kubectl get pods -A -o json` text. See ``parsePods(_:metrics:)-(Data,_)``.
    public static func parsePods(_ text: String, metrics: String = "") throws(KubectlError) -> [PodInfo] {
        try parsePods(Data(text.utf8), metrics: Data(metrics.utf8))
    }

    /// Parses `kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods` (a `PodMetricsList`), summing
    /// each pod's containers. Anything else (an error message, no output) is no metrics.
    public static func parsePodMetrics(_ data: Data) -> [PodMetrics] {
        guard !data.isEmpty,
              let list = decodeJSONTolerantly(ListJSON<PodMetricsJSON>.self, from: data),
              let items = list.items
        else { return [] }
        return items.elements.compactMap { $0.metrics() }
    }

    /// A Kubernetes quantity (`resource.Quantity`) in base units: cores for CPU, bytes for
    /// memory. Accepts decimal suffixes (`2367103n`, `250m`, `1k`, `1M`), binary suffixes
    /// (`14304Ki`, `64Mi`, `1Gi`) and exponents (`1e3`). `nil` for negative values or junk.
    public static func parseQuantity(_ text: some StringProtocol) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let suffixStart = trimmed.firstIndex { !"0123456789.+-".contains($0) } ?? trimmed.endIndex
        guard let number = Double(trimmed[..<suffixStart]), number.isFinite, number >= 0 else { return nil }
        let suffix = trimmed[suffixStart...]
        let multiplier: Double
        if let scale = quantitySuffixes[String(suffix)] {
            multiplier = scale
        } else if suffix.first == "e" || suffix.first == "E", let exponent = Int(suffix.dropFirst()), abs(exponent) <= 30 {
            multiplier = pow(10, Double(exponent))
        } else {
            return nil
        }
        let value = number * multiplier
        return value.isFinite ? value : nil
    }

    private static let quantitySuffixes: [String: Double] = [
        "": 1, "n": 1e-9, "u": 1e-6, "m": 1e-3,
        "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15, "E": 1e18,
        "Ki": 1_024, "Mi": 1_048_576, "Gi": 1_073_741_824,
        "Ti": 1_099_511_627_776, "Pi": 1_125_899_906_842_624, "Ei": 1_152_921_504_606_846_976,
    ]

    /// `value` rounded up to a whole number, as Kubernetes' `Quantity.ScaledValue` does (so
    /// `2.4m` is `3m`, like `kubectl top`). Float noise (`0.1 * 1000`) does not round up.
    static func roundedUp(_ value: Double) -> Int64? {
        guard value.isFinite, value >= 0, value < 9.0e18 else { return nil }
        let nearest = value.rounded()
        return Int64(abs(value - nearest) < 1e-6 ? nearest : value.rounded(.up))
    }

    /// Cores to whole millicores, rounded up.
    static func millicores(_ cores: Double?) -> Int? {
        cores.flatMap { roundedUp($0 * 1000) }.map(Int.init)
    }

    /// Parses `kubectl get events -o json` into rows sorted oldest first by ``PodEvent/lastSeen``.
    ///
    /// - Throws: ``KubectlError``, as ``parsePods(_:metrics:)-(Data,_)``.
    public static func parseEvents(_ data: Data) throws(KubectlError) -> [PodEvent] {
        guard let list = decodeJSONTolerantly(ListJSON<EventJSON>.self, from: data), let items = list.items else {
            throw failure(data)
        }
        let events = items.elements.enumerated().map { $0.element.event(index: $0.offset) }
        return events.enumerated()
            .sorted { a, b in
                let lhs = a.element.lastSeen ?? .distantPast
                let rhs = b.element.lastSeen ?? .distantPast
                return lhs != rhs ? lhs < rhs : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Parses `kubectl get events -o json` text. See ``parseEvents(_:)-(Data)``.
    public static func parseEvents(_ text: String) throws(KubectlError) -> [PodEvent] {
        try parseEvents(Data(text.utf8))
    }

    /// The error for output that is not the expected JSON.
    private static func failure(_ data: Data) -> KubectlError {
        let error = KubectlError.classify(String(decoding: data, as: UTF8.self))
        if case .failed = error { return .invalidOutput }
        return error
    }
}

/// One pod's CPU and memory use from the metrics API (metrics-server), summed over its containers.
public struct PodMetrics: Sendable, Hashable {
    /// `metadata.namespace`.
    public var namespace: String
    /// `metadata.name`.
    public var name: String
    /// Sum of `containers[].usage.cpu`, in millicores (rounded up).
    public var cpuMillicores: Int?
    /// Sum of `containers[].usage.memory` (working set), in bytes.
    public var memUsedBytes: Int64?

    /// Creates a metrics row.
    public init(namespace: String, name: String, cpuMillicores: Int?, memUsedBytes: Int64?) {
        self.namespace = namespace
        self.name = name
        self.cpuMillicores = cpuMillicores
        self.memUsedBytes = memUsedBytes
    }
}

/// One row of a pod's events (`kubectl get events --field-selector involvedObject.name=<pod>`).
public struct PodEvent: Identifiable, Codable, Sendable, Hashable {
    /// `metadata.uid`, else `metadata.name`, else the position in the list.
    public var id: String
    /// `type`: `Normal` or `Warning`.
    public var type: String
    /// `reason`, e.g. `BackOff`, `FailedScheduling`.
    public var reason: String
    /// `message` (untrusted remote text).
    public var message: String
    /// How many times it happened: `count`, else `series.count`, else 1.
    public var count: Int
    /// `firstTimestamp`, else `eventTime`, else `metadata.creationTimestamp`.
    public var firstSeen: Date?
    /// `lastTimestamp`, else `series.lastObservedTime`, else `eventTime`, else ``firstSeen``.
    public var lastSeen: Date?
    /// `source.component`, else `reportingComponent` (e.g. `kubelet`, `default-scheduler`).
    public var source: String?

    /// Creates an event row.
    public init(id: String, type: String, reason: String, message: String, count: Int = 1,
                firstSeen: Date? = nil, lastSeen: Date? = nil, source: String? = nil) {
        self.id = id
        self.type = type
        self.reason = reason
        self.message = message
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.source = source
    }

    /// `true` for `Warning` events (shown in the failing colour).
    public var isWarning: Bool { type.caseInsensitiveCompare("Warning") == .orderedSame }

    /// Short age of the last occurrence (`5m`), or `nil` when unknown.
    public func age(now: Date = .now) -> String? {
        lastSeen.map { AgeFormat.short(since: $0, now: now) }
    }
}

/// Errors from kubectl commands, with user-facing hints.
public enum KubectlError: Error, Sendable, Hashable, LocalizedError {
    /// The kubeconfig cannot be read by the login user (k3s writes it root-only).
    case kubeconfigUnreadable(path: String?)
    /// `sudo -n` was refused: no passwordless sudo rule for the kubectl prefix.
    case sudoRefused
    /// `kubectl logs --previous` for a container that has not restarted.
    case noPreviousContainer(container: String?, pod: String?)
    /// The API server refused the connection (cluster down, or the wrong kubeconfig).
    case connectionRefused(server: String?)
    /// kubectl (or k3s) is not installed or not on the PATH.
    case notInstalled
    /// The command succeeded but its output was not the expected JSON.
    case invalidOutput
    /// Anything else; the first meaningful line of the error output.
    case failed(message: String)

    /// Classifies a failed kubectl command's stderr (or merged output).
    public static func classify(_ output: String) -> KubectlError {
        let lower = output.lowercased()
        if CommandErrorText.isSudoRefusal(output) { return .sudoRefused }
        if let line = CommandErrorText.meaningfulLines(output).first(where: Self.isKubeconfigError) {
            return .kubeconfigUnreadable(path: Self.kubeconfigPath(in: line))
        }
        if let line = CommandErrorText.meaningfulLines(output).first(where: {
            $0.lowercased().contains("previous terminated container")
        }) {
            let names = CommandErrorText.quoted(line)
            return .noPreviousContainer(container: names.first, pod: names.dropFirst().first)
        }
        if lower.contains("connection refused") || lower.contains("was refused - did you specify the right host") {
            return .connectionRefused(server: Self.server(in: output))
        }
        if CommandErrorText.isCommandNotFound(output, commands: ["kubectl", "k3s"]) { return .notInstalled }
        return .failed(message: CommandErrorText.summary(output))
    }

    /// What the user can do about it.
    public var hint: String? {
        switch self {
        case .kubeconfigUnreadable:
            "The kubeconfig is not readable by this user. On k3s, set the host's kubectl prefix to "
                + "\"sudo -n k3s kubectl\" (with a NOPASSWD sudoers rule), or point KUBECONFIG at a readable copy."
        case .sudoRefused:
            "sudo -n needs a passwordless sudoers rule (NOPASSWD) for the kubectl command. "
                + "Add one, or change the host's kubectl prefix."
        case .noPreviousContainer:
            "This container has not restarted, so there are no previous logs. Show the current logs instead."
        case .connectionRefused:
            "The Kubernetes API server is not reachable. Check that the cluster is running and the kubeconfig is right."
        case .notInstalled:
            "kubectl was not found on this host. Install it, or set the host's kubectl prefix (e.g. \"k3s kubectl\")."
        case .invalidOutput:
            "kubectl returned output that is not the expected JSON. Check the kubectl version and prefix."
        case .failed:
            nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .kubeconfigUnreadable(let path?): "Cannot read the kubeconfig (\(path))."
        case .kubeconfigUnreadable(nil): "Cannot read the kubeconfig."
        case .sudoRefused: "sudo refused to run kubectl without a password."
        case .noPreviousContainer(let container?, let pod?):
            "No previous instance of container \"\(container)\" in pod \"\(pod)\"."
        case .noPreviousContainer: "No previous container instance."
        case .connectionRefused(let server?): "Connection to the Kubernetes API (\(server)) was refused."
        case .connectionRefused(nil): "Connection to the Kubernetes API was refused."
        case .notInstalled: "kubectl was not found."
        case .invalidOutput: "kubectl returned unexpected output."
        case .failed(let message): message.isEmpty ? "The kubectl command failed." : message
        }
    }

    public var recoverySuggestion: String? { hint }

    private static func isKubeconfigError(_ line: String) -> Bool {
        let lower = line.lowercased()
        return (lower.contains("error loading config file") && lower.contains("permission denied"))
            || (lower.contains("unable to read") && lower.contains("kube"))
            || (lower.contains("kubeconfig") && lower.contains("permission denied"))
    }

    /// The kubeconfig path in `error loading config file "/etc/rancher/k3s/k3s.yaml": ...`
    /// or `msg="Unable to read /etc/rancher/k3s/k3s.yaml, ..."`.
    private static func kubeconfigPath(in line: String) -> String? {
        if let quoted = CommandErrorText.quoted(line).first(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }) {
            return quoted
        }
        return line.split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("/") }
            .map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: ",:;\"'"))) }
    }

    /// The `host:port` in `The connection to the server 127.0.0.1:6443 was refused ...`
    /// or `dial tcp 127.0.0.1:6443: connect: connection refused`.
    private static func server(in output: String) -> String? {
        let words = output.split(whereSeparator: \.isWhitespace)
        for (index, word) in words.enumerated() where word == "server" || word == "tcp" {
            guard index + 1 < words.count else { continue }
            let candidate = words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
            if candidate.contains(":") || candidate.contains(".") { return candidate }
        }
        return nil
    }
}

/// `{"kind": "List", "items": [...]}`. `items` is `nil` when the key is missing (not a list).
private struct ListJSON<Item: Decodable>: Decodable {
    var items: LossyArray<Item>?

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: any Decoder) throws {
        items = try decoder.container(keyedBy: CodingKeys.self).lenient(LossyArray<Item>.self, .items)
    }
}

private struct MetadataJSON: Decodable {
    var name, namespace, uid, creationTimestamp: String?

    enum CodingKeys: String, CodingKey { case name, namespace, uid, creationTimestamp }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.nonEmptyString(.name)
        namespace = c.nonEmptyString(.namespace)
        uid = c.nonEmptyString(.uid)
        creationTimestamp = c.nonEmptyString(.creationTimestamp)
    }
}

/// A pod's `metadata.ownerReferences` and its `pod-template-hash` label, for ``PodOwner``.
private struct PodOwnershipJSON: Decodable {
    struct Reference: Decodable {
        var kind, name: String?
        var controller: Bool?

        enum CodingKeys: String, CodingKey { case kind, name, controller }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = c.nonEmptyString(.kind)
            name = c.nonEmptyString(.name)
            controller = c.lenient(Bool.self, .controller)
        }
    }

    var references: [Reference]
    var podTemplateHash: String?

    enum CodingKeys: String, CodingKey { case ownerReferences, labels }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        references = c.lenient(LossyArray<Reference>.self, .ownerReferences)?.elements ?? []
        podTemplateHash = c.lenient([String: String].self, .labels)?["pod-template-hash"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The controller reference; a Deployment's ReplicaSet (`<deployment>-<pod-template-hash>`)
    /// becomes the Deployment.
    var owner: PodOwner? {
        guard let reference = references.first(where: { $0.controller == true }),
              let kind = reference.kind, let name = reference.name
        else { return nil }
        if kind == "ReplicaSet", let hash = podTemplateHash, name.hasSuffix("-\(hash)"), name.count > hash.count + 1 {
            return PodOwner(kind: "Deployment", name: String(name.dropLast(hash.count + 1)))
        }
        return PodOwner(kind: kind, name: name)
    }
}

/// The fields of a Pod that ``PodInfo`` keeps.
private struct PodJSON: Decodable {
    struct Spec: Decodable {
        var nodeName: String?
        var containers: [ContainerSpecJSON]
        /// Pod-level `resources.limits` (Kubernetes 1.32+); overrides the containers' limits.
        var limits: ResourceListJSON?

        enum CodingKeys: String, CodingKey { case nodeName, containers, resources }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nodeName = c.nonEmptyString(.nodeName)
            containers = (c.lenient(LossyArray<ContainerSpecJSON>.self, .containers)?.elements ?? []).filter { $0.name != nil }
            limits = c.lenient(ResourcesJSON.self, .resources)?.limits
        }

        /// The pod-level limit, else the sum of the containers' limits when every container has
        /// one (one unlimited container makes the pod unlimited).
        func limit(_ resource: KeyPath<ResourceListJSON, Double?>) -> Double? {
            if let podLimit = limits?[keyPath: resource] { return podLimit }
            guard !containers.isEmpty else { return nil }
            var total = 0.0
            for container in containers {
                guard let limit = container.limits?[keyPath: resource] else { return nil }
                total += limit
            }
            return total
        }
    }

    struct Status: Decodable {
        var phase: String?
        var containerStatuses: [ContainerStatusJSON]

        enum CodingKeys: String, CodingKey { case phase, containerStatuses }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phase = c.nonEmptyString(.phase)
            containerStatuses = c.lenient(LossyArray<ContainerStatusJSON>.self, .containerStatuses)?.elements ?? []
        }
    }

    var metadata: MetadataJSON?
    var ownership: PodOwnershipJSON?
    var spec: Spec?
    var status: Status?

    enum CodingKeys: String, CodingKey { case metadata, spec, status }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = c.lenient(MetadataJSON.self, .metadata)
        ownership = c.lenient(PodOwnershipJSON.self, .metadata)
        spec = c.lenient(Spec.self, .spec)
        status = c.lenient(Status.self, .status)
    }

    func pod() -> PodInfo? {
        guard let name = metadata?.name else { return nil }
        let statuses = (status?.containerStatuses ?? []).compactMap { $0.status() }
        var containers: [PodContainerStatus] = []
        var seen = Set<String>()
        for containerName in (spec?.containers ?? []).compactMap(\.name) where seen.insert(containerName).inserted {
            containers.append(statuses.first { $0.name == containerName }
                ?? PodContainerStatus(name: containerName, ready: false))
        }
        for extra in statuses where seen.insert(extra.name).inserted {
            containers.append(extra)
        }
        return PodInfo(
            namespace: metadata?.namespace ?? "default",
            name: name,
            phase: status?.phase.map { PodPhase(rawValue: $0) ?? .unknown } ?? .unknown,
            containers: containers,
            nodeName: spec?.nodeName,
            createdAt: metadata?.creationTimestamp.flatMap { Timestamps.parseRFC3339($0) },
            cpuLimitMillicores: KubernetesParser.millicores(spec?.limit(\.cpu)),
            memLimitBytes: spec?.limit(\.memory).flatMap(KubernetesParser.roundedUp),
            owner: ownership?.owner
        )
    }
}

/// One `spec.containers[]` entry: its name and `resources.limits`.
private struct ContainerSpecJSON: Decodable {
    var name: String?
    var limits: ResourceListJSON?

    enum CodingKeys: String, CodingKey { case name, resources }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.nonEmptyString(.name)
        limits = c.lenient(ResourcesJSON.self, .resources)?.limits
    }
}

/// `resources`; only `limits` is read.
private struct ResourcesJSON: Decodable {
    var limits: ResourceListJSON?

    enum CodingKeys: String, CodingKey { case limits }

    init(from decoder: any Decoder) throws {
        limits = try decoder.container(keyedBy: CodingKeys.self).lenient(ResourceListJSON.self, .limits)
    }
}

/// A resource list such as `{"cpu": "500m", "memory": "64Mi"}`: CPU in cores, memory in bytes.
private struct ResourceListJSON: Decodable {
    var cpu: Double?
    var memory: Double?

    enum CodingKeys: String, CodingKey { case cpu, memory }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = c.nonEmptyString(.cpu).flatMap { KubernetesParser.parseQuantity($0) }
        memory = c.nonEmptyString(.memory).flatMap { KubernetesParser.parseQuantity($0) }
    }
}

/// One `PodMetrics` item of `/apis/metrics.k8s.io/v1beta1/pods`.
private struct PodMetricsJSON: Decodable {
    struct Container: Decodable {
        var usage: ResourceListJSON?
    }

    var metadata: MetadataJSON?
    var containers: [Container]

    enum CodingKeys: String, CodingKey { case metadata, containers }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = c.lenient(MetadataJSON.self, .metadata)
        containers = c.lenient(LossyArray<Container>.self, .containers)?.elements ?? []
    }

    /// The containers' usage summed; a resource no container reports stays `nil`.
    func metrics() -> PodMetrics? {
        guard let name = metadata?.name else { return nil }
        let cpu = containers.compactMap { $0.usage?.cpu }
        let memory = containers.compactMap { $0.usage?.memory }
        return PodMetrics(
            namespace: metadata?.namespace ?? "default",
            name: name,
            cpuMillicores: cpu.isEmpty ? nil : KubernetesParser.millicores(cpu.reduce(0, +)),
            memUsedBytes: memory.isEmpty ? nil : KubernetesParser.roundedUp(memory.reduce(0, +))
        )
    }
}

private struct ContainerStatusJSON: Decodable {
    struct Waiting: Decodable { var reason: String? }
    struct Terminated: Decodable { var reason: String?; var exitCode: Int? }
    struct State: Decodable {
        var waiting: Waiting?
        var terminated: Terminated?

        enum CodingKeys: String, CodingKey { case waiting, terminated }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            waiting = c.lenient(Waiting.self, .waiting)
            terminated = c.lenient(Terminated.self, .terminated)
        }
    }

    var name: String?
    var ready: Bool?
    var restartCount: Int?
    var state: State?

    enum CodingKeys: String, CodingKey { case name, ready, restartCount, state }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.nonEmptyString(.name)
        ready = c.lenient(Bool.self, .ready)
        restartCount = c.lenient(Int.self, .restartCount)
        state = c.lenient(State.self, .state)
    }

    func status() -> PodContainerStatus? {
        guard let name else { return nil }
        let terminated = state?.terminated
        return PodContainerStatus(
            name: name,
            ready: ready ?? false,
            restartCount: max(0, restartCount ?? 0),
            waitingReason: state?.waiting?.reason.flatMap { $0.isEmpty ? nil : $0 },
            terminatedReason: terminated?.reason.flatMap { $0.isEmpty ? nil : $0 },
            exitCode: terminated.map { $0.exitCode ?? 0 }
        )
    }
}

private struct EventJSON: Decodable {
    struct Series: Decodable {
        var count: Int?
        var lastObservedTime: String?
    }
    struct Source: Decodable { var component: String? }

    var metadata: MetadataJSON?
    var type, reason, message: String?
    var count: Int?
    var series: Series?
    var firstTimestamp, lastTimestamp, eventTime: String?
    var source: Source?
    var reportingComponent: String?

    enum CodingKeys: String, CodingKey {
        case metadata, type, reason, message, count, series
        case firstTimestamp, lastTimestamp, eventTime, source, reportingComponent
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = c.lenient(MetadataJSON.self, .metadata)
        type = c.nonEmptyString(.type)
        reason = c.nonEmptyString(.reason)
        message = c.lenient(String.self, .message)
        count = c.lenient(Int.self, .count)
        series = c.lenient(Series.self, .series)
        firstTimestamp = c.nonEmptyString(.firstTimestamp)
        lastTimestamp = c.nonEmptyString(.lastTimestamp)
        eventTime = c.nonEmptyString(.eventTime)
        source = c.lenient(Source.self, .source)
        reportingComponent = c.nonEmptyString(.reportingComponent)
    }

    func event(index: Int) -> PodEvent {
        func date(_ text: String?) -> Date? { text.flatMap { Timestamps.parseRFC3339($0) } }
        let firstSeen = date(firstTimestamp) ?? date(eventTime) ?? date(metadata?.creationTimestamp)
        let component = source?.component.flatMap { $0.isEmpty ? nil : $0 } ?? reportingComponent
        return PodEvent(
            id: metadata?.uid ?? metadata?.name ?? "\(index)",
            type: type ?? "Normal",
            reason: reason ?? "",
            message: message ?? "",
            count: max(1, count ?? series?.count ?? 1),
            firstSeen: firstSeen,
            lastSeen: date(lastTimestamp) ?? date(series?.lastObservedTime) ?? date(eventTime) ?? firstSeen,
            source: component
        )
    }
}
