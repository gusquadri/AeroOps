import Foundation

/// Parses kubectl JSON output.
///
/// ```swift
/// let pods = try KubernetesParser.parsePods(stdout)       // kubectl get pods -A -o json
/// let events = try KubernetesParser.parseEvents(stdout)   // kubectl get events ... -o json
/// ```
/// When kubectl exits non-zero, classify its stderr with ``KubectlError/classify(_:)``.
public enum KubernetesParser {
    /// Parses `kubectl get pods -A -o json` (a `List`/`PodList`, or a single `Pod`).
    /// Pods without a name are skipped; one undecodable pod does not hide the others.
    ///
    /// - Throws: ``KubectlError``: a known error when the text is a kubectl/sudo error message,
    ///   otherwise ``KubectlError/invalidOutput``.
    public static func parsePods(_ data: Data) throws(KubectlError) -> [PodInfo] {
        if let list = decodeJSONTolerantly(ListJSON<PodJSON>.self, from: data), let items = list.items {
            return items.elements.compactMap { $0.pod() }
        }
        if let single = decodeJSONTolerantly(PodJSON.self, from: data), let pod = single.pod() {
            return [pod]
        }
        throw failure(data)
    }

    /// Parses `kubectl get pods -A -o json` text. See ``parsePods(_:)-(Data)``.
    public static func parsePods(_ text: String) throws(KubectlError) -> [PodInfo] {
        try parsePods(Data(text.utf8))
    }

    /// Parses `kubectl get events -o json` into rows sorted oldest first by ``PodEvent/lastSeen``.
    ///
    /// - Throws: ``KubectlError``, as ``parsePods(_:)-(Data)``.
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

// MARK: - JSON shapes

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

/// The fields of a Pod that ``PodInfo`` keeps.
private struct PodJSON: Decodable {
    struct Spec: Decodable {
        var nodeName: String?
        var containers: [String]

        enum CodingKeys: String, CodingKey { case nodeName, containers }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nodeName = c.nonEmptyString(.nodeName)
            containers = (c.lenient(LossyArray<NamedJSON>.self, .containers)?.elements ?? []).compactMap(\.name)
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
    var spec: Spec?
    var status: Status?

    enum CodingKeys: String, CodingKey { case metadata, spec, status }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = c.lenient(MetadataJSON.self, .metadata)
        spec = c.lenient(Spec.self, .spec)
        status = c.lenient(Status.self, .status)
    }

    func pod() -> PodInfo? {
        guard let name = metadata?.name else { return nil }
        let statuses = (status?.containerStatuses ?? []).compactMap { $0.status() }
        var containers: [PodContainerStatus] = []
        var seen = Set<String>()
        for containerName in spec?.containers ?? [] where seen.insert(containerName).inserted {
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
            createdAt: metadata?.creationTimestamp.flatMap { Timestamps.parseRFC3339($0) }
        )
    }
}

private struct NamedJSON: Decodable {
    var name: String?

    enum CodingKeys: String, CodingKey { case name }

    init(from decoder: any Decoder) throws {
        name = try decoder.container(keyedBy: CodingKeys.self).nonEmptyString(.name)
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
            // A terminated state always has an exit code; default to 0 if a reason came without one.
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
