import AeroCore
import AgentBridge
import AppKit
import BridgeProtocol
import Collectors
import Foundation
import LocalAuthentication
import Observation
import os
import SSHKit
import Synchronization

/// Phases 7 and 8: the MCP bridge on `~/.aeroops/bridge.sock` and everything the app shows about
/// it (approvals, live `run_command` output, connections).
///
/// One instance per app, owned by ``AppModel/agents``. ``start()`` runs after the agent and the
/// monitors are up; ``beginShutdown()`` runs first when the app quits, so no agent call opens a
/// connection while monitors and ControlMasters close.
///
/// - Every call goes through AgentBridge's pipeline: peer check (the embedded, team-signed
///   `aeroops-mcp` only), PolicyEngine, ApprovalCenter, CommandExecutor. The app only
///   supplies data (``AppBridgeHandler``) and the approval UI.
/// - Approvals: ``decide(_:_:)`` is the only way the UI (panel, notification, Activity tab)
///   answers one. With ``requiresTouchID`` an allow decision first asks for Touch ID or the
///   login password (``TouchIDApprovalAuthenticator``).
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
    static let touchIDDefaultsKey = "ApprovalsRequireTouchID"

    private(set) var status: Status = .stopped
    /// Connected clients, oldest first.
    private(set) var peers: [ConnectedPeer] = []
    /// Bridge connection events, oldest first (at most ``eventLimit``).
    private(set) var connectionEvents: [ConnectionRecord] = []
    /// Approvals waiting for the user, oldest first.
    private(set) var pending: [PendingApproval] = []
    /// Open "allow this host for 15 minutes" windows.
    private(set) var windows: [AllowWindow] = []
    /// Running `run_command` calls (newest first), then the last few finished ones.
    private(set) var liveCommands: [LiveCommand] = []
    /// Ask for Touch ID (or the login password) before an allow decision takes effect.
    var requiresTouchID: Bool {
        didSet {
            authenticator.setEnabled(requiresTouchID)
            defaults?.set(requiresTouchID, forKey: Self.touchIDDefaultsKey)
        }
    }

    /// `false` keeps the bridge closed (demo and snapshot launches show sample state instead).
    @ObservationIgnored var isEnabled = true
    /// Show the floating approval panel (and the Dock badge) when an approval arrives.
    @ObservationIgnored var presentsApprovals = true
    /// Also post a notification when the app is not frontmost.
    @ObservationIgnored var postsNotifications = true
    /// Where ``requiresTouchID`` is persisted; `nil` keeps it in memory (self-test, demo).
    @ObservationIgnored var defaults: UserDefaults? = .standard
    /// Called after each approval snapshot is applied (self-test only).
    @ObservationIgnored var didUpdateApprovals: ((ApprovalSnapshot) -> Void)?
    /// Called after each command event is applied (self-test only).
    @ObservationIgnored var didReceiveCommandActivity: ((CommandActivity) -> Void)?

    @ObservationIgnored private let ssh: SSHServices
    @ObservationIgnored private let runner: BridgeCommandRunner
    @ObservationIgnored private let authenticator: TouchIDApprovalAuthenticator
    @ObservationIgnored private let dataSource = BridgeDataSource()
    @ObservationIgnored private(set) var bridge: Bridge?
    @ObservationIgnored private var approvals: ApprovalCenter?
    @ObservationIgnored private var executor: CommandExecutor?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var presenter: ApprovalPresenter?
    @ObservationIgnored private var isShutDown = false

    init(ssh: SSHServices) {
        self.ssh = ssh
        runner = BridgeCommandRunner(ssh.runner)
        let touchID = UserDefaults.standard.bool(forKey: Self.touchIDDefaultsKey)
        requiresTouchID = touchID
        authenticator = TouchIDApprovalAuthenticator(enabled: touchID)
    }

    /// Connects the read tools to the model's hosts and live state. Called once by ``AppModel``.
    func bind(model: AppModel) {
        dataSource.model = model
    }

    /// Keeps settings in memory and turns Touch ID off (self-test and demo launches).
    func useTransientSettings() {
        defaults = nil
        requiresTouchID = false
    }

    /// `~/.aeroops/bridge.sock`, or the debug root's.
    var socketURL: URL { ssh.paths.bridgeSocket }
    /// Whether an agent call is in progress or waiting.
    var hasRunningCommands: Bool { liveCommands.contains(where: \.isRunning) }

    // MARK: - Lifecycle

    /// Opens the socket. Call after ``SSHServices/start()`` and ``MonitorService/start()``.
    func start() {
        guard isEnabled, !isShutDown, bridge == nil else { return }
        runner.update(ssh.runner)
        trackAgentChoice()

        let approvals = ApprovalCenter(authenticator: authenticator)
        let executor = CommandExecutor(runner: runner)
        let bridge = Bridge(
            socketURL: socketURL,
            handler: AppBridgeHandler(source: dataSource, runner: runner),
            executor: executor,
            approvals: approvals,
            peerValidator: CodeSignaturePeerValidator.forApp()
        )
        self.bridge = bridge
        self.approvals = approvals
        self.executor = executor
        if presentsApprovals {
            presenter = ApprovalPresenter(service: self, notifications: postsNotifications)
        }

        // Subscribe before the socket opens so no event is missed.
        observe(bridge.events()) { $0.receive($1) }
        observe(executor.activity()) { $0.receive($1) }
        observeApprovals(approvals)

        do {
            try bridge.start()
            status = .listening
        } catch {
            status = .failed(error.localizedDescription)
            Self.logger.error("Bridge did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Closes the socket on the main actor (in-flight calls are cancelled, pending approvals
    /// vanish, running commands are killed) and returns the rest: waiting briefly for killed
    /// commands to end their ssh processes. `nil` if the bridge never started.
    func beginShutdown() -> (@Sendable () async -> Void)? {
        guard !isShutDown else { return nil }
        isShutDown = true
        presenter?.close()
        presenter = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        approvals = nil
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

    /// Answers the pending approval `id`, as every approval control does. With
    /// ``requiresTouchID`` an allow decision asks for Touch ID first. Returns `false` when the
    /// approval is gone or authentication failed (it then stays pending).
    @discardableResult
    func decide(_ id: PendingApproval.ID, _ decision: ApprovalDecision) async -> Bool {
        guard let approvals else { return false }
        return await approvals.decide(id, decision)
    }

    /// Stops a running command (the Activity tab's Cancel). ssh is killed and the remote watchdog
    /// kills the command's process group within a few seconds.
    @discardableResult
    func cancel(_ commandID: LiveCommand.ID) async -> Bool {
        guard let executor else { return false }
        return await executor.cancel(commandID)
    }

    /// Closes the allow window for `hostID` early.
    func revokeWindow(for hostID: UUID) async {
        await approvals?.revokeWindow(for: hostID)
    }

    /// Closes every allow window.
    func revokeAllWindows() async {
        await approvals?.revokeAllWindows()
    }

    /// Removes finished commands from the Activity tab.
    func clearFinishedCommands() {
        liveCommands.removeAll { !$0.isRunning }
    }

    /// Brings the approval panel forward (a notification was clicked, or Activity asked for it).
    func showApprovalPanel() {
        presenter?.showPanel()
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

    private func observeApprovals(_ approvals: ApprovalCenter) {
        tasks.append(Task { [weak self] in
            let updates = await approvals.updates()
            for await snapshot in updates {
                guard let self else { return }
                self.receive(snapshot)
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

    private func receive(_ snapshot: ApprovalSnapshot) {
        if pending != snapshot.pending { pending = snapshot.pending }
        if windows != snapshot.windows { windows = snapshot.windows }
        presenter?.update(pending: snapshot.pending)
        didUpdateApprovals?(snapshot)
    }

    private func receive(_ activity: CommandActivity) {
        switch activity {
        case .started(let command):
            liveCommands.insert(LiveCommand(command), at: 0)
        case .output(let id, let chunk):
            update(id) { $0.append(chunk) }
        case .finished(let id, let result):
            update(id) { $0.end(.finished(exitCode: result.exitCode, durationMs: result.durationMs)) }
        case .failed(let id, let message):
            update(id) { $0.end(.failed(message)) }
        case .cancelled(let id, let byUser):
            update(id) { $0.end(.cancelled(byUser: byUser)) }
        }
        let finished = liveCommands.indices.filter { !liveCommands[$0].isRunning }
        if finished.count > Self.finishedCommandsKept {
            let drop = Set(finished.dropFirst(Self.finishedCommandsKept).map { liveCommands[$0].id })
            liveCommands.removeAll { drop.contains($0.id) }
        }
        didReceiveCommandActivity?(activity)
    }

    private func update(_ id: LiveCommand.ID, _ change: (inout LiveCommand) -> Void) {
        guard let index = liveCommands.firstIndex(where: { $0.id == id }) else { return }
        change(&liveCommands[index])
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
    /// Sample state for demo and snapshot launches: approvals waiting (one with sudo), an allow
    /// window, a running command with output, a finished one and connections. The
    /// approvals live in a private ``ApprovalCenter``, so the controls work; one that times out
    /// is asked again.
    func applySampleState(hosts: [RemoteHost]) {
        guard bridge == nil, approvals == nil, let host = hosts.first else { return }
        let other = hosts.dropFirst().first ?? host
        let center = ApprovalCenter()
        approvals = center
        observeApprovals(center)
        status = .listening
        let now = Date.now
        let claude = BridgeClientInfo(name: "claude-code", version: "2.1.296")
        let asks = [
            ApprovalAsk(client: claude, host: host, command: "docker restart api && docker logs --tail 20 api",
                        reason: "The api container stopped answering health checks; restarting it should clear the stuck worker."),
            ApprovalAsk(client: BridgeClientInfo(name: "codex", version: "0.48.0"), host: other,
                        command: "sudo systemctl restart nginx",
                        reason: "nginx is serving a stale certificate; a restart picks up the renewed one.",
                        alwaysAskReasons: CommandInspector.alwaysAskReasons(for: "sudo systemctl restart nginx")),
        ]
        for (index, ask) in asks.enumerated() {
            tasks.append(Task {
                try? await Task.sleep(for: .milliseconds(100 * index))
                while !Task.isCancelled, await center.authorize(ask) == .timedOut {}
            })
        }
        // An open window: allow a third request for 15 minutes.
        if let third = hosts.dropFirst(4).first {
            tasks.append(Task {
                try? await Task.sleep(for: .milliseconds(400))
                async let outcome = center.authorize(ApprovalAsk(client: claude, host: third, command: "uptime", reason: "Sample"))
                try? await Task.sleep(for: .milliseconds(200))
                if let id = await center.snapshot().pending.first(where: { $0.hostID == third.id })?.id {
                    await center.decide(id, .allowHost15Min)
                }
                _ = await outcome
            })
        }

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

// MARK: - Touch ID

/// Asks for Touch ID (or the login password) before an allow decision takes effect, when the
/// user turned it on in Settings › MCP. Denials never ask.
final class TouchIDApprovalAuthenticator: ApprovalAuthenticator {
    private let enabled: Mutex<Bool>

    init(enabled: Bool) {
        self.enabled = Mutex(enabled)
    }

    func setEnabled(_ value: Bool) {
        enabled.withLock { $0 = value }
    }

    func authenticate(_ approval: PendingApproval, decision: ApprovalDecision) async -> Bool {
        guard enabled.withLock({ $0 }) else { return true }
        let context = LAContext()
        let reason = decision == .allowHost15Min
            ? "allow agent commands on \(approval.hostName) for 15 minutes"
            : "allow an agent command on \(approval.hostName)"
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
