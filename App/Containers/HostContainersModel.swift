import AeroCore
import Collectors
import Foundation
import Observation

/// The Containers tab's live state for one host: probed capabilities, Docker containers and
/// Kubernetes pods, filters, and the open Logs / Inspect / pod-detail presentations.
///
/// Refreshes never overlap: a refresh requested while one is running waits for it instead of
/// starting another. ``poll()`` refreshes every ``pollInterval`` while the tab is visible.
///
/// Errors become ``WorkloadIssue``s. A setup problem (docker group, sudo, kubeconfig) stops
/// polling that section until Refresh or a host edit; an ssh login or host-key problem stops all
/// polling until Refresh, so a failing login is never retried in a loop.
@MainActor
@Observable
final class HostContainersModel {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case docker
        case kubernetes

        var id: Self { self }

        var title: String {
            switch self {
            case .docker: "Docker"
            case .kubernetes: "Kubernetes"
            }
        }
    }

    static let pollInterval = Duration.seconds(5)

    let hostID: RemoteHost.ID
    @ObservationIgnored private unowned let service: ContainerService

    // MARK: Data

    /// The probe result; `nil` before the first probe or when it failed.
    private(set) var capabilities: HostCapabilities?
    /// Why the probe failed (ssh login, host key, unreachable).
    private(set) var connectionIssue: WorkloadIssue?

    private(set) var containers: [ContainerInfo] = []
    private(set) var dockerIssue: WorkloadIssue?
    private(set) var dockerLoaded = false

    private(set) var pods: [PodInfo] = []
    private(set) var podsIssue: WorkloadIssue?
    private(set) var podsLoaded = false

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    // MARK: Filters and selection

    var section: Section?
    /// Docker: show exited and created containers too.
    var showStopped = false
    var dockerSearch = ""
    /// Kubernetes: `nil` means all namespaces.
    var namespace: String?
    var podSearch = ""
    var selectedContainerID: ContainerInfo.ID?
    var selectedPodID: PodInfo.ID? {
        didSet {
            guard selectedPodID != oldValue else { return }
            loadPodDetail()
        }
    }

    var inspectorPresented = false

    enum InspectorTab: String, CaseIterable, Identifiable, Hashable {
        case events = "Events"
        case describe = "Describe"
        var id: Self { self }
    }

    /// The inspector's pane; events first, so a Pending pod's FailedScheduling is the first thing seen.
    var inspectorTab = InspectorTab.events

    // MARK: Presentations

    /// The Logs sheet; `nil` when closed. Closing it stops any follow.
    var logs: LogViewerModel? {
        didSet {
            if let oldValue, oldValue !== logs { oldValue.stop() }
        }
    }

    /// The Inspect sheet; `nil` when closed.
    var inspection: ContainerInspectionModel? {
        didSet {
            if let oldValue, oldValue !== inspection { oldValue.cancel() }
        }
    }

    /// Describe and events for ``selectedPodID``, shown in the inspector.
    private(set) var podDetail: PodDetailModel?

    // MARK: Statistics (self-test)

    private(set) var refreshCount = 0
    @ObservationIgnored private(set) var maxConcurrentRefreshes = 0
    @ObservationIgnored private var runningRefreshes = 0

    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var activePollers = 0
    @ObservationIgnored private var lastHost: RemoteHost?

    init(hostID: RemoteHost.ID, service: ContainerService) {
        self.hostID = hostID
        self.service = service
        lastHost = service.host(id: hostID)
    }

    var host: RemoteHost? { service.host(id: hostID) }

    // MARK: - Derived

    /// Docker is installed (the probe found the `docker` command).
    var showsDocker: Bool {
        guard let capabilities else { return false }
        return capabilities.contains(.docker)
    }

    /// kubectl or k3s is installed, or the host has a kubectl prefix.
    var showsKubernetes: Bool {
        guard let capabilities else { return false }
        return !capabilities.isDisjoint(with: [.kubectl, .k3s]) || host?.kubectlPrefix != nil
    }

    /// The sections to offer, in order.
    var availableSections: [Section] {
        var sections: [Section] = []
        if showsDocker { sections.append(.docker) }
        if showsKubernetes { sections.append(.kubernetes) }
        return sections
    }

    /// The section to show: the chosen one if still available, else the first available one.
    var visibleSection: Section? {
        let available = availableSections
        if let section, available.contains(section) { return section }
        return available.first
    }

    /// Polling stopped because ssh could not sign in or the host key is not trusted.
    var isPollingHalted: Bool {
        [connectionIssue, dockerIssue, podsIssue].contains { $0?.kind == .access }
    }

    var filteredContainers: [ContainerInfo] {
        let query = dockerSearch.trimmingCharacters(in: .whitespaces)
        return containers.filter { container in
            (showStopped || container.state == .running || container.state == .restarting || container.state == .paused)
                && (query.isEmpty
                    || container.name.localizedStandardContains(query)
                    || container.image.localizedStandardContains(query)
                    || container.status.localizedStandardContains(query)
                    || (container.ports ?? "").localizedStandardContains(query))
        }
    }

    var namespaces: [String] {
        Array(Set(pods.map(\.namespace))).sorted()
    }

    var filteredPods: [PodInfo] {
        let query = podSearch.trimmingCharacters(in: .whitespaces)
        return pods.filter { pod in
            (namespace == nil || pod.namespace == namespace)
                && (query.isEmpty
                    || pod.name.localizedStandardContains(query)
                    || pod.namespace.localizedStandardContains(query)
                    || pod.displayStatus.localizedStandardContains(query)
                    || (pod.nodeName ?? "").localizedStandardContains(query))
        }
    }

    var selectedPod: PodInfo? {
        selectedPodID.flatMap { id in pods.first { $0.id == id } }
    }

    // MARK: - Polling

    /// Refreshes now and then every ``pollInterval`` until cancelled (the tab or window hides).
    func poll() async {
        activePollers += 1
        defer { activePollers -= 1 }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Refreshes once. Waits for a refresh that is already running instead of overlapping it;
    /// `reprobe` (the Refresh button) probes capabilities again and retries stopped sections.
    func refresh(reprobe: Bool = false) async {
        if let running = inFlight {
            await running.value
            guard reprobe else { return }
        }
        while let running = inFlight { await running.value }
        let task = Task { await self.performRefresh(reprobe: reprobe) }
        inFlight = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlight == task { inFlight = nil }
    }

    private func performRefresh(reprobe: Bool) async {
        guard let host = service.host(id: hostID) else { return }
        if isPollingHalted, !reprobe { return }
        runningRefreshes += 1
        maxConcurrentRefreshes = max(maxConcurrentRefreshes, runningRefreshes)
        isRefreshing = true
        defer {
            runningRefreshes -= 1
            isRefreshing = false
            refreshCount += 1
        }

        let cache = service.capabilityCache
        let caps: HostCapabilities
        do {
            caps = reprobe ? try await cache.refresh(host) : try await cache.capabilities(for: host)
            capabilities = caps
            connectionIssue = nil
        } catch {
            guard let issue = WorkloadIssue.from(error, host: host), !Task.isCancelled else { return }
            connectionIssue = issue
            lastRefresh = .now
            return
        }

        if reprobe {
            if dockerIssue?.kind != .transient { dockerIssue = nil }
            if podsIssue?.kind != .transient { podsIssue = nil }
        }
        let fetchDocker = caps.contains(.docker) && dockerIssue?.kind != .setup && dockerIssue?.kind != .access
        let fetchPods = showsKubernetes && podsIssue?.kind != .setup && podsIssue?.kind != .access
        if !caps.contains(.docker) {
            containers = []
            dockerIssue = nil
        }
        if !showsKubernetes {
            pods = []
            podsIssue = nil
        }

        let docker = service.docker
        let kubernetes = service.kubernetes
        async let dockerResult = Self.load(fetchDocker) { try await docker.containers(on: host, includeStopped: true) }
        async let podsResult = Self.load(fetchPods) { try await kubernetes.pods(on: host) }
        let (dockerOutcome, podsOutcome) = await (dockerResult, podsResult)
        guard !Task.isCancelled else { return }

        switch dockerOutcome {
        case .success(let list)?:
            containers = list
            dockerIssue = nil
            dockerLoaded = true
        case .failure(let error)?:
            if let issue = WorkloadIssue.from(error, capabilities: caps, host: host) {
                dockerIssue = issue
                if issue.kind != .transient { containers = [] }
                dockerLoaded = true
            }
        case nil:
            break
        }
        switch podsOutcome {
        case .success(let list)?:
            pods = list
            podsIssue = nil
            podsLoaded = true
            if let selectedPodID, !list.contains(where: { $0.id == selectedPodID }) {
                podDetail?.markGone()
            }
        case .failure(let error)?:
            if let issue = WorkloadIssue.from(error, capabilities: caps, host: host) {
                podsIssue = issue
                if issue.kind != .transient { pods = [] }
                podsLoaded = true
            }
        case nil:
            break
        }
        lastRefresh = .now
    }

    private nonisolated static func load<T: Sendable>(
        _ enabled: Bool, _ operation: @Sendable () async throws -> T
    ) async -> Result<T, any Error>? {
        guard enabled else { return nil }
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Host changes

    /// A new kubectl prefix, docker sudo setting or address may fix a stopped section: clear the
    /// stop and refresh if the tab is showing this host.
    func hostDidChange(_ host: RemoteHost) {
        defer { lastHost = host }
        guard let old = lastHost else { return }
        let endpointChanged = old.address != host.address || old.port != host.port || old.user != host.user
            || old.keyId != host.keyId
        let dockerChanged = old.dockerSudo != host.dockerSudo
        let kubeChanged = old.kubectlPrefix != host.kubectlPrefix
        guard endpointChanged || dockerChanged || kubeChanged else { return }
        if endpointChanged {
            connectionIssue = nil
            dockerIssue = nil
            podsIssue = nil
        }
        if dockerChanged { dockerIssue = nil }
        if kubeChanged { podsIssue = nil }
        if activePollers > 0 {
            Task { await refresh() }
        }
    }

    // MARK: - Actions

    /// Opens the Logs sheet for a container (following while it runs).
    func showLogs(_ container: ContainerInfo) {
        guard let host else { return }
        logs = LogViewerModel(
            host: host, target: .container(name: container.name, running: container.state == .running), service: service
        )
    }

    /// Opens the Logs sheet for a pod, optionally for one container or its previous instance.
    func showLogs(_ pod: PodInfo, container: String? = nil, previous: Bool = false) {
        guard let host else { return }
        logs = LogViewerModel(
            host: host,
            target: .pod(namespace: pod.namespace, name: pod.name, containers: pod.containers),
            service: service,
            container: container,
            previous: previous
        )
    }

    /// One click for a crashed pod: the previous instance's logs of its most-restarted container.
    func showPreviousLogs(_ pod: PodInfo) {
        let crashed = pod.containers.filter(\.hasPreviousInstance)
        let container = crashed.first { $0.waitingReason == "CrashLoopBackOff" }
            ?? crashed.max { $0.restartCount < $1.restartCount }
        showLogs(pod, container: container?.name, previous: container != nil)
    }

    /// Opens the Inspect sheet for a container.
    func inspect(_ container: ContainerInfo) {
        guard let host else { return }
        let model = ContainerInspectionModel(name: container.name, host: host, docker: service.docker)
        inspection = model
        model.load()
    }

    /// Shows a pod's describe and events in the inspector.
    func showDetail(_ pod: PodInfo) {
        selectedPodID = pod.id
        inspectorPresented = true
        if podDetail == nil { loadPodDetail() }
    }

    /// Reloads the inspector's describe and events.
    func reloadPodDetail() {
        podDetail?.load()
    }

    private func loadPodDetail() {
        podDetail?.cancel()
        guard let host, let id = selectedPodID, let pod = pods.first(where: { $0.id == id }) else {
            podDetail = nil
            return
        }
        let detail = PodDetailModel(namespace: pod.namespace, name: pod.name, host: host, kubernetes: service.kubernetes)
        podDetail = detail
        detail.load()
    }

    // MARK: - Terminal

    var canOpenTerminal: Bool {
        service.canOpenSSH(hostID)
    }

    /// `docker logs -f --tail 500 <name>` in a terminal tab.
    func openLogsInTerminal(_ container: ContainerInfo) {
        guard let host,
              let command = try? DockerCommands.terminalFollow(container: container.name, tail: LogViewerModel.tail, sudo: host.dockerSudo)
        else { return }
        service.openSSH(hostID, remoteCommand: command, title: "logs \(container.name)")
    }

    /// `kubectl logs -f --tail=500 …` in a terminal tab.
    func openLogsInTerminal(_ pod: PodInfo, container: String? = nil) {
        guard let host,
              let command = try? KubectlCommands(host: host).logs(
                  pod: pod.name, namespace: pod.namespace, container: container, tail: LogViewerModel.tail, follow: true
              )
        else { return }
        service.openSSH(hostID, remoteCommand: command, title: "logs \(pod.namespace)/\(pod.name)")
    }

    /// The Logs sheet's terminal button.
    func openLogsInTerminal(_ viewer: LogViewerModel) {
        guard let command = viewer.terminalCommand else { return }
        service.openSSH(hostID, remoteCommand: command, title: viewer.terminalTitle)
    }

    // MARK: - Teardown

    /// Stops every follow and closes the sheets and the inspector.
    func stopPresentations() {
        logs = nil
        inspection = nil
        podDetail?.cancel()
        podDetail = nil
        inspectorPresented = false
    }
}
