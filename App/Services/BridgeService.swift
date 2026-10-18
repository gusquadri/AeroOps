import AeroCore
import AgentBridge
import BridgeProtocol
import Collectors
import Foundation
import Observation
import os
import SSHKit
import Synchronization

/// Phases 7 and 8: the MCP bridge on `~/.aeroops/bridge.sock` and everything the app shows about
/// it (live `run_command` output, connections).
///
/// One instance per app, owned by ``AppModel/agents``. ``start()`` runs after the agent and the
/// monitors are up; ``beginShutdown()`` runs first when the app quits, so no agent call opens a
/// connection while monitors and ControlMasters close.
///
/// - Every call goes through AgentBridge's pipeline: peer check (the embedded, team-signed
///   `aeroops-mcp` only), PolicyEngine, CommandExecutor. The app only supplies data
///   (``AppBridgeHandler``).
/// - AeroOps does not ask before `run_command`: the host's MCP tier decides, and the agent is
///   told to confirm with the user in its own conversation.
/// - Remote access goes through the app's ``SSHRunner`` (system ssh, `~/.aeroops/ssh_config`,
///   the in-app agent), swapped when the agent choice changes.
@MainActor
@Observable
final class BridgeService {
    /// Whether the socket is open.
    enum Status: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    /// A connected, validated MCP client process.
    struct ConnectedPeer: Identifiable, Hashable {
        let id: UInt64
        let peer: BridgePeer
        let since: Date
    }

    /// One bridge connection event, kept in memory only (the Phase 7 self-test checks them).
    struct ConnectionRecord: Identifiable, Hashable {
        enum Kind: Hashable {
            case connected(BridgePeer)
            case rejected(String)
            case protocolError(String)
            case disconnected
        }

        let id: UUID
        let date: Date
        let connectionID: UInt64
        let kind: Kind
    }

    static let eventLimit = 200
    /// Finished commands kept in the Activity tab (with their output) besides the running ones.
    static let finishedCommandsKept = 5
    /// Command activity is applied at most this often, in one change to ``liveCommands``: live
    /// output can arrive as hundreds of small reads a second.
    static let activityFlushInterval = Duration.milliseconds(100)

    private(set) var status: Status = .stopped
    /// Connected clients, oldest first.
    private(set) var peers: [ConnectedPeer] = []
    /// Bridge connection events, oldest first (at most ``eventLimit``).
    private(set) var connectionEvents: [ConnectionRecord] = []
    /// Running `run_command` calls (newest first), then the last few finished ones.
    private(set) var liveCommands: [LiveCommand] = []

    /// `false` keeps the bridge closed (demo and snapshot launches show sample state instead).
    @ObservationIgnored var isEnabled = true
    /// Called with each command event once its batch is applied (self-test only). Consecutive
    /// output may come merged into one event.
    @ObservationIgnored var didReceiveCommandActivity: ((CommandActivity) -> Void)?

    @ObservationIgnored private let ssh: SSHServices
    @ObservationIgnored private let runner: BridgeCommandRunner
    @ObservationIgnored private let dataSource = BridgeDataSource()
    @ObservationIgnored private(set) var bridge: Bridge?
    @ObservationIgnored private var executor: CommandExecutor?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingActivity = CommandActivityBuffer()
    @ObservationIgnored private var activityFlush: Task<Void, Never>?
    @ObservationIgnored private var isShutDown = false

    init(ssh: SSHServices) {
        self.ssh = ssh
        runner = BridgeCommandRunner(ssh.runner)
    }

    /// Connects the read tools to the model's hosts and live state. Called once by ``AppModel``.
    func bind(model: AppModel) {
        dataSource.model = model
    }

    /// `~/.aeroops/bridge.sock`, or the debug root's.
    var socketURL: URL { ssh.paths.bridgeSocket }
    /// Whether an agent command is running.
    var hasRunningCommands: Bool { liveCommands.contains(where: \.isRunning) }

    // MARK: - Lifecycle

    /// Opens the socket. Call after ``SSHServices/start()`` and ``MonitorService/start()``.
    func start() {
        guard isEnabled, !isShutDown, bridge == nil else { return }
        runner.update(ssh.runner)
        trackAgentChoice()

        let executor = CommandExecutor(runner: runner)
        let bridge = Bridge(
            socketURL: socketURL,
            handler: AppBridgeHandler(source: dataSource, runner: runner),
            executor: executor,
            peerValidator: CodeSignaturePeerValidator.forApp()
        )
        self.bridge = bridge
        self.executor = executor

        // Subscribe before the socket opens so no event is missed.
        observe(bridge.events()) { $0.receive($1) }
        observe(executor.activity()) { $0.receive($1) }

        do {
            try bridge.start()
            status = .listening
        } catch {
            status = .failed(error.localizedDescription)
            Self.logger.error("Bridge did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Closes the socket on the main actor (in-flight calls are cancelled, running commands are
    /// killed) and returns the rest: waiting briefly for killed commands to end their ssh
    /// processes. `nil` if the bridge never started.
    func beginShutdown() -> (@Sendable () async -> Void)? {
        guard !isShutDown else { return nil }
        isShutDown = true
        tasks.forEach { $0.cancel() }
        tasks = []
        activityFlush?.cancel()
        activityFlush = nil
        peers = []
        status = .stopped
        guard let bridge else { return nil }
        self.bridge = nil
        executor = nil
        bridge.stop()
        let executor = bridge.executor
        return {
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline, await !executor.running().isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Actions

    /// Stops a running command (the Activity tab's Cancel). ssh is killed and the remote watchdog
    /// kills the command's process group within a few seconds.
    @discardableResult
    func cancel(_ commandID: LiveCommand.ID) async -> Bool {
        guard let executor else { return false }
        return await executor.cancel(commandID)
    }

    /// Removes finished commands from the Activity tab.
    func clearFinishedCommands() {
        liveCommands.removeAll { !$0.isRunning }
    }

    // MARK: - Events

    private func observe<Element: Sendable>(_ stream: AsyncStream<Element>, _ handler: @escaping @MainActor (BridgeService, Element) -> Void) {
        tasks.append(Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                handler(self, element)
            }
        })
    }

    private func receive(_ event: BridgeServerEvent) {
        let kind: ConnectionRecord.Kind
        switch event.kind {
        case .connected(let peer):
            peers.append(ConnectedPeer(id: event.connectionID, peer: peer, since: .now))
            kind = .connected(peer)
        case .rejected(let reason):
            kind = .rejected(reason)
        case .protocolError(let message):
            kind = .protocolError(message)
        case .disconnected:
            peers.removeAll { $0.id == event.connectionID }
            kind = .disconnected
        }
        connectionEvents.append(ConnectionRecord(id: UUID(), date: .now, connectionID: event.connectionID, kind: kind))
        if connectionEvents.count > Self.eventLimit {
            connectionEvents.removeFirst(connectionEvents.count - Self.eventLimit)
        }
    }

    /// Buffers the event; the first one after a flush schedules the next.
    private func receive(_ activity: CommandActivity) {
        pendingActivity.append(activity)
        guard activityFlush == nil else { return }
        activityFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.activityFlushInterval)
            guard !Task.isCancelled else { return }
            self?.flushActivity()
        }
    }

    /// Applies the buffered events to a copy of ``liveCommands`` and stores it once, only when
    /// something changed (output past a command's cap changes nothing).
    private func flushActivity() {
        activityFlush = nil
        let batch = pendingActivity.drain()
        var commands = liveCommands
        for activity in batch {
            switch activity {
            case .started(let command):
                commands.insert(LiveCommand(command), at: 0)
            case .output(let id, let chunk):
                Self.update(id, in: &commands) { $0.append(chunk) }
            case .finished(let id, let result):
                Self.update(id, in: &commands) { $0.end(.finished(exitCode: result.exitCode, durationMs: result.durationMs)) }
            case .failed(let id, let message):
                Self.update(id, in: &commands) { $0.end(.failed(message)) }
            case .cancelled(let id, let byUser):
                Self.update(id, in: &commands) { $0.end(.cancelled(byUser: byUser)) }
            }
        }
        let finished = commands.indices.filter { !commands[$0].isRunning }
        if finished.count > Self.finishedCommandsKept {
            let drop = Set(finished.dropFirst(Self.finishedCommandsKept).map { commands[$0].id })
            commands.removeAll { drop.contains($0.id) }
        }
        if commands != liveCommands { liveCommands = commands }
        if let didReceiveCommandActivity { batch.forEach(didReceiveCommandActivity) }
    }

    private static func update(_ id: LiveCommand.ID, in commands: inout [LiveCommand], _ change: (inout LiveCommand) -> Void) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        change(&commands[index])
    }

    /// Keeps the runner's agent environment and askpass route in step with ``SSHServices``.
    private func trackAgentChoice() {
        guard !isShutDown else { return }
        withObservationTracking {
            _ = ssh.agentChoice
            _ = ssh.askpassRoute
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.runner.update(self.ssh.runner)
                self.trackAgentChoice()
            }
        }
    }

    // MARK: - Samples

    #if DEBUG
    /// Sample state for demo and snapshot launches: a running command with output, a finished
    /// one and a connection.
    func applySampleState(hosts: [RemoteHost]) {
        guard bridge == nil, let host = hosts.first else { return }
        let other = hosts.dropFirst().first ?? host
        status = .listening
        let now = Date.now

        let peer = BridgePeer(pid: 48213, uid: getuid(), executablePath: "/Applications/AeroOps.app/Contents/MacOS/aeroops-mcp",
                              signingIdentifier: "app.aeroops.mcp", teamIdentifier: "VUDQQS32NW", trust: .codeSignature)
        peers = [ConnectedPeer(id: 7, peer: peer, since: now.addingTimeInterval(-340))]

        var running = LiveCommand(id: UUID(), hostID: other.id, hostName: other.name,
                                  command: "journalctl -u api --since '10 min ago' --no-pager | tail -n 40",
                                  startedAt: now.addingTimeInterval(-12))
        running.append(CommandOutputChunk(stream: .stdout, data: Data("""
            Oct 11 09:41:02 web-1 api[812]: GET /health 200 2ms
            Oct 11 09:41:07 web-1 api[812]: GET /api/orders 200 41ms
            Oct 11 09:41:12 web-1 api[812]: \u{1B}[33mWARN\u{1B}[0m pool exhausted, waiting for a connection

            """.utf8)))
        running.append(CommandOutputChunk(stream: .stderr, data: Data("journalctl: some lines were rotated away\n".utf8)))
        var finished = LiveCommand(id: UUID(), hostID: host.id, hostName: host.name, command: "uname -a", startedAt: now.addingTimeInterval(-95))
        finished.append(CommandOutputChunk(stream: .stdout, data: Data("Linux web-1 6.8.0-45-generic #45-Ubuntu SMP x86_64 GNU/Linux\n".utf8)))
        finished.end(.finished(exitCode: 0, durationMs: 412))
        liveCommands = [running, finished]
    }
    #endif

    nonisolated static let logger = Logger(subsystem: "app.aeroops.AeroOps", category: "bridge")
}

// MARK: - Data for the read tools

/// The model-side answers to the bridge's read tools. Main-actor work only (host list, live
/// state); remote fetches run in ``AppBridgeHandler`` off the main actor.
@MainActor
final class BridgeDataSource {
    /// A sample this young (and a host currently online) is returned as is.
    static let freshness: TimeInterval = 45
    /// How long `get_host_metrics` waits for a one-off poll.
    static let pollWait: Duration = .seconds(15)

    weak var model: AppModel?

    /// Every configured host with its card's status. Called on every request, so it stays cheap.
    func hostStates() -> [BridgeHostState] {
        guard let model else { return [] }
        return model.hosts.map { BridgeHostState(host: $0, status: model.displayState(for: $0.id).status) }
    }

    /// The card's latest sample when fresh; otherwise one poll now, waiting up to ``pollWait``.
    func metrics(for host: RemoteHost) async throws -> MetricsSnapshot {
        guard let model, model.host(id: host.id) != nil else {
            throw BridgeHandlerError.unavailable("This host is no longer configured in AeroOps.")
        }
        if model.ssh.configRejections[host.id] != nil {
            throw BridgeHandlerError.unavailable("AeroOps does not connect to this host: its connection settings were rejected. The user can fix them in Settings › Hosts.")
        }
        if model.host(id: host.id)?.monitored == false {
            throw BridgeHandlerError.unavailable("Monitoring is off for this host in AeroOps, so there are no metrics. The user can turn it back on from the host's card.")
        }
        let state = model.displayState(for: host.id)
        if let error = Self.blocked(state) { throw error }
        if let metrics = state.metrics, Self.isFresh(metrics, state) { return metrics }
        if state.status == .unsupported { throw Self.unsupported }
        guard model.monitoring.isRunning else {
            if let metrics = state.metrics { return metrics }
            throw BridgeHandlerError.unavailable("Monitoring is not running in AeroOps, so there are no metrics for this host.")
        }

        let previous = state.metrics?.sampledAt
        let failures = state.consecutiveFailures
        model.refresh(host.id)
        let deadline = ContinuousClock.now + Self.pollWait
        var latest = state
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            latest = model.displayState(for: host.id)
            if let error = Self.blocked(latest) { throw error }
            if let metrics = latest.metrics, metrics.sampledAt != previous, Self.isFresh(metrics, latest) { return metrics }
            if latest.status == .unsupported { throw Self.unsupported }
            if latest.consecutiveFailures > failures { break }
        }
        if latest.status == .offline || latest.consecutiveFailures > failures {
            throw BridgeHandlerError.sshFailed("AeroOps could not reach this host just now (it shows as \(latest.status.rawValue) in the app).")
        }
        throw BridgeHandlerError.unavailable("No metrics for this host yet. Try again in a few seconds.")
    }

    private static let unsupported = BridgeHandlerError.notSupported("AeroOps cannot collect metrics from this host's operating system.")

    private static func isFresh(_ metrics: MetricsSnapshot, _ state: HostDisplayState) -> Bool {
        state.status == .online && Date.now.timeIntervalSince(metrics.sampledAt) <= freshness
    }

    /// The monitor holds the host because of its host key: never connect from here either.
    private static func blocked(_ state: HostDisplayState) -> BridgeHandlerError? {
        switch state.hostKeyIssue {
        case .unknown:
            .unavailable("AeroOps has not trusted this host's key yet. The user must trust it in AeroOps first.")
        case .changed:
            .unavailable("This host's key has changed. AeroOps blocks connections until the user reviews it.")
        case nil:
            nil
        }
    }
}

/// The app's ``BridgeToolHandler``: hosts and metrics from the model, containers, pods and logs
/// fetched with Collectors over the app's ssh. Error messages go to the agent, so they are written
/// here and never carry remote error text (remote output is untrusted).
struct AppBridgeHandler: BridgeToolHandler {
    let source: BridgeDataSource
    let runner: BridgeCommandRunner

    func hosts() async -> [BridgeHostState] {
        await source.hostStates()
    }

    func metrics(for host: RemoteHost) async throws -> MetricsSnapshot {
        try await source.metrics(for: host)
    }

    func containers(on host: RemoteHost, includeStopped: Bool) async throws -> [ContainerInfo] {
        do {
            return try await DockerCollector(runner: runner).containers(on: host, includeStopped: includeStopped)
        } catch {
            throw Self.agentError(error, host: host)
        }
    }

    func pods(on host: RemoteHost, namespace: String?) async throws -> [PodInfo] {
        do {
            return try await KubernetesCollector(runner: runner).pods(on: host, namespace: namespace)
        } catch {
            throw Self.agentError(error, host: host)
        }
    }

    func logs(_ request: LogRequest, on host: RemoteHost) async throws -> String {
        do {
            return try await LogCollector(runner: runner).fetch(request, on: host).text
        } catch {
            throw Self.agentError(error, host: host)
        }
    }

    /// Maps a collector failure to a message for the agent. Cancellation passes through.
    static func agentError(_ error: any Error, host: RemoteHost) -> any Error {
        switch error {
        case is CancellationError, is BridgeHandlerError:
            return error
        case let error as SSHError:
            BridgeService.logger.notice("Bridge fetch on \(host.name, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            switch error {
            case .remoteCommandFailed, .other:
                return BridgeHandlerError.sshFailed("ssh to this host failed.")
            case .hostKeyUnknown:
                return BridgeHandlerError.unavailable("AeroOps has not trusted this host's key yet. The user must trust it in AeroOps first.")
            default:
                return BridgeHandlerError.sshFailed(error.errorDescription ?? "ssh to this host failed.")
            }
        case let error as DockerError:
            BridgeService.logger.notice("Docker on \(host.name, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            return switch error {
            case .notInstalled: BridgeHandlerError.notSupported("Docker is not installed on this host.")
            case .permissionDenied: BridgeHandlerError.unavailable("The login user may not use Docker on this host (not in the docker group, and \"docker via sudo\" is off for it in AeroOps).")
            case .daemonNotRunning: BridgeHandlerError.unavailable("The Docker daemon is not running on this host.")
            case .sudoRefused: BridgeHandlerError.unavailable("sudo refused to run docker without a password on this host.")
            case .failed: BridgeHandlerError.unavailable("Docker reported an error on this host (for logs, the container may not exist).")
            }
        case let error as KubectlError:
            BridgeService.logger.notice("kubectl on \(host.name, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            return switch error {
            case .notInstalled: BridgeHandlerError.notSupported("kubectl is not installed on this host.")
            case .kubeconfigUnreadable: BridgeHandlerError.unavailable("kubectl cannot read its kubeconfig on this host. The user can set a kubectl prefix for the host in AeroOps.")
            case .sudoRefused: BridgeHandlerError.unavailable("sudo refused to run kubectl without a password on this host.")
            case .noPreviousContainer: BridgeHandlerError.unavailable("That container has no previous instance (it has not restarted).")
            case .connectionRefused: BridgeHandlerError.unavailable("The Kubernetes API server refused the connection.")
            case .invalidOutput: BridgeHandlerError.unavailable("kubectl returned output AeroOps could not read.")
            case .failed: BridgeHandlerError.unavailable("kubectl reported an error on this host (the pod or namespace may not exist).")
            }
        case let error as CollectorInputError:
            return BridgeHandlerError.unavailable(error.errorDescription ?? "The request is not valid for this host.")
        default:
            BridgeService.logger.error("Bridge fetch on \(host.name, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            return BridgeHandlerError.unavailable("AeroOps could not fetch this from the host.")
        }
    }
}

// MARK: - Runner

/// The bridge's command runner: the app's current ``SSHRunner`` (swapped when the agent choice
/// changes), for both `run_command` (AgentBridge) and the collectors. Reading it takes a lock,
/// not the main actor.
final class BridgeCommandRunner: RemoteCommandRunner, HostCommandRunning, HostCommandStreaming {
    private let current: Mutex<SSHRunner>

    init(_ runner: SSHRunner) {
        current = Mutex(runner)
    }

    func update(_ runner: SSHRunner) {
        current.withLock { $0 = runner }
    }

    private var runner: SSHRunner { current.withLock { $0 } }

    func run(_ remoteCommand: String, on host: RemoteHost, timeout: Duration, outputLimit: Int,
             output: @escaping @Sendable (CommandOutputChunk) -> Void) async throws -> RemoteCommandOutcome {
        try await SSHCommandRunner(runner: runner).run(remoteCommand, on: host, timeout: timeout, outputLimit: outputLimit, output: output)
    }

    func run(_ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration, outputLimit: Int) async throws -> SSHResult {
        try await runner.run(command, on: host, stdin: stdin, timeout: timeout, outputLimit: outputLimit)
    }

    func stream(_ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration?,
                maxBufferedLines: Int) async throws -> AsyncThrowingStream<String, any Error> {
        try await runner.stream(command, on: host, stdin: stdin, timeout: timeout, maxBufferedLines: maxBufferedLines)
    }
}
