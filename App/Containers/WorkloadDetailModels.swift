import AeroCore
import Collectors
import Foundation
import Observation

/// The Inspect sheet's state: `docker inspect` summary and pretty-printed JSON.
///
/// The JSON includes the container's environment, which often holds secrets: it is only shown
/// and copied on request, never logged or written anywhere.
@MainActor
@Observable
final class ContainerInspectionModel: Identifiable {
    nonisolated let id = UUID()
    let name: String
    private(set) var summary: DockerInspectSummary?
    private(set) var json = ""
    private(set) var issue: WorkloadIssue?
    private(set) var isLoading = false

    @ObservationIgnored private let host: RemoteHost
    @ObservationIgnored private let docker: DockerCollector
    @ObservationIgnored private var task: Task<Void, Never>?

    init(name: String, host: RemoteHost, docker: DockerCollector) {
        self.name = name
        self.host = host
        self.docker = docker
    }

    func load() {
        task?.cancel()
        isLoading = true
        issue = nil
        let docker = docker
        let host = host
        let name = name
        task = Task { [weak self] in
            do {
                let inspection = try await docker.inspect(name, on: host)
                let pretty = await Self.prettyPrinted(inspection.json)
                guard let self, !Task.isCancelled else { return }
                summary = inspection.summary
                json = pretty
                isLoading = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                issue = WorkloadIssue.from(error, host: host)
                isLoading = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    @concurrent
    private nonisolated static func prettyPrinted(_ data: Data) async -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }
}

/// The pod inspector's state: `kubectl describe pod` text and the pod's events.
@MainActor
@Observable
final class PodDetailModel {
    let namespace: String
    let name: String
    private(set) var describe = ""
    private(set) var describeTruncated = false
    private(set) var events: [PodEvent] = []
    private(set) var describeIssue: WorkloadIssue?
    private(set) var eventsIssue: WorkloadIssue?
    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    /// The pod no longer exists (deleted or replaced by a new one).
    private(set) var isGone = false

    @ObservationIgnored private let host: RemoteHost
    @ObservationIgnored private let kubernetes: KubernetesCollector
    @ObservationIgnored private var task: Task<Void, Never>?

    init(namespace: String, name: String, host: RemoteHost, kubernetes: KubernetesCollector) {
        self.namespace = namespace
        self.name = name
        self.host = host
        self.kubernetes = kubernetes
    }

    var id: String { "\(namespace)/\(name)" }

    /// Warnings first (FailedScheduling, BackOff…), then the newest.
    var sortedEvents: [PodEvent] {
        events.sorted { lhs, rhs in
            if lhs.isWarning != rhs.isWarning { return lhs.isWarning }
            return (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
        }
    }

    func load() {
        task?.cancel()
        isLoading = true
        let kubernetes = kubernetes
        let host = host
        let namespace = namespace
        let name = name
        task = Task { [weak self] in
            async let describeResult = Self.capture { try await kubernetes.describe(pod: name, namespace: namespace, on: host) }
            async let eventsResult = Self.capture { try await kubernetes.events(pod: name, namespace: namespace, on: host) }
            let (describe, events) = await (describeResult, eventsResult)
            guard let self, !Task.isCancelled else { return }
            switch describe {
            case .success(let text):
                self.describe = text.text
                describeTruncated = text.truncated
                describeIssue = nil
            case .failure(let error):
                describeIssue = WorkloadIssue.from(error, host: host)
            }
            switch events {
            case .success(let list):
                self.events = list
                eventsIssue = nil
            case .failure(let error):
                eventsIssue = WorkloadIssue.from(error, host: host)
            }
            isLoading = false
            loadedAt = .now
        }
    }

    func markGone() {
        isGone = true
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private nonisolated static func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}
