import AeroCore
import AppKit
import Collectors
import Foundation
import Observation
import SSHKit
import SwiftUI
import Synchronization

/// Live metrics for every host (Phase 3): drives Collectors' ``MonitorCoordinator`` from the
/// inventory and copies each `HostMonitorUpdate` into the host's ``HostDisplayState``.
///
/// One instance per app, owned by ``AppModel/monitoring`` and registered as a
/// ``HostInventoryObserver`` after ``SSHServices``, so `ssh_config` is rewritten before a
/// monitor connects with new settings. ``start()`` runs after the SSH services are up;
/// ``beginShutdown()`` runs when the app quits.
///
/// - Polling goes through the app's ``SSHRunner`` (system ssh, `~/.aeroops/ssh_config`, the
///   in-app agent) and ``HostKeyStore``. Hosts that `ssh_config` rejected are not polled, nor
///   are hosts with monitoring off (``RemoteHost/monitored``), which show ``HostStatus/unmonitored``.
/// - Activity: ``MonitorActivity/visible`` (5 s) while the main window is visible and the app
///   is active, ``MonitorActivity/background`` (30 s) otherwise, ``MonitorActivity/paused``
///   while the Mac or its displays sleep. Waking refreshes every host at once.
/// - Updates are coalesced: they collect for ``coalescingDelay`` and are applied in one
///   main-actor turn, assigning only the per-host properties that changed.
/// - Host keys: a monitor holds a host with no pinned key (``HostKeyIssue/unknown``, the card
///   offers the trust sheet via ``requestHostKeyTrust(for:)``) or a changed key
///   (``HostKeyIssue/changed(_:)``, the red banner). When ``SSHServices`` trusts or re-checks
///   a held host's key, the host is polled again.
@MainActor
@Observable
final class MonitorService {
    /// How long updates collect before they are applied.
    static let coalescingDelay: Duration = .milliseconds(120)

    /// First-contact keys of a held host, for ``HostKeyTrustSheet``.
    struct TrustRequest: Identifiable {
        let host: RemoteHost
        let offered: [HostKey]
        var id: RemoteHost.ID { host.id }
    }

    /// Whether monitors are running (between ``start()`` and ``beginShutdown()``).
    private(set) var isRunning = false
    /// The polling mode applied to every monitor.
    private(set) var activity: MonitorActivity = .background
    /// The trust sheet to show; set by ``requestHostKeyTrust(for:)``.
    var trustRequest: TrustRequest?
    /// Hosts whose key is being scanned for the trust sheet.
    private(set) var scanningHostIDs: Set<RemoteHost.ID> = []
    /// Why the last key scan for a host failed, shown on its card.
    private(set) var scanErrors: [RemoteHost.ID: String] = [:]

    /// `false` keeps the service from starting (demo and snapshot launches, which show sample states).
    @ObservationIgnored var isEnabled = true
    /// Replaces the window and app-focus rule (self-test only). Sleep still pauses.
    @ObservationIgnored var activityOverride: MonitorActivity? {
        didSet { updateActivity() }
    }
    /// Called after each coalesced batch is applied (self-test only).
    @ObservationIgnored var didApplyUpdates: (([HostMonitorUpdate]) -> Void)?

    @ObservationIgnored private let ssh: SSHServices
    @ObservationIgnored private let runner: SwitchableRunner
    @ObservationIgnored private var displayState: (RemoteHost.ID) -> HostDisplayState? = { _ in nil }
    @ObservationIgnored private var hosts: [RemoteHost] = []
    @ObservationIgnored private var coordinator: MonitorCoordinator?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [RemoteHost.ID: HostMonitorUpdate] = [:]
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var activityUpdate: Task<Void, Never>?
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var systemAsleep = false
    @ObservationIgnored private var screensAsleep = false

    init(ssh: SSHServices) {
        self.ssh = ssh
        runner = SwitchableRunner(ssh.runner)
    }

    /// Connects the service to the model's per-host state. Called once by ``AppModel``.
    func bind(states: @escaping (RemoteHost.ID) -> HostDisplayState?) {
        displayState = states
    }

    // MARK: - Lifecycle

    /// Starts monitoring the current hosts. Call after ``SSHServices/start()``. Idempotent.
    func start() {
        guard isEnabled, !isShutDown, coordinator == nil else { return }
        runner.update(ssh.runner)
        trackAgentChoice()
        let coordinator = MonitorCoordinator(runner: runner, hostKeys: ssh.hostKeys, activity: currentActivity())
        self.coordinator = coordinator
        activity = coordinator.activity
        let updates = coordinator.updates
        pump = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.receive(update)
            }
        }
        ssh.hostKeysDidChange = { [weak self] host in self?.hostKeysDidChange(for: host) }
        ssh.passwordsDidChange = { [weak self] id in self?.passwordDidChange(for: id) }
        observeActivity()
        isRunning = true
        applyHosts()
    }

    /// Stops the service on the main actor and returns the rest: stopping every monitor, which
    /// kills running polls. The returned work needs no main actor (the app may be quitting from
    /// inside a main-actor job, see ``AppDelegate``). `nil` if the service never started.
    func beginShutdown() -> (@Sendable () async -> Void)? {
        guard !isShutDown else { return nil }
        isShutDown = true
        isRunning = false
        pump?.cancel()
        flushTask?.cancel()
        activityUpdate?.cancel()
        observers.forEach { $0.cancel() }
        observers = []
        pending = [:]
        ssh.hostKeysDidChange = nil
        ssh.passwordsDidChange = nil
        guard let coordinator else { return nil }
        self.coordinator = nil
        let monitors = coordinator.monitoredHostIDs.compactMap(coordinator.monitor(for:))
        return {
            await withTaskGroup(of: Void.self) { group in
                for monitor in monitors {
                    group.addTask { await monitor.stop() }
                }
            }
        }
    }

    // MARK: - Actions

    /// Polls every host now (the dashboard's Refresh, ⌘R).
    func refreshAll() {
        coordinator?.refreshAll()
    }

    /// Polls one host now.
    func refresh(_ id: RemoteHost.ID) {
        coordinator?.refresh(id)
    }

    /// Scans a held host's key and opens the trust sheet. A key that is pinned (or changed) by
    /// now just polls again.
    func requestHostKeyTrust(for host: RemoteHost) async {
        guard !scanningHostIDs.contains(host.id) else { return }
        scanningHostIDs.insert(host.id)
        scanErrors[host.id] = nil
        defer { scanningHostIDs.remove(host.id) }
        do {
            switch try await ssh.hostKeys.verify(host) {
            case .unknown(let offered):
                trustRequest = TrustRequest(host: host, offered: offered)
            case .trusted:
                refresh(host.id)
            case .changed:
                await ssh.refreshHostKeyBlocks()
                refresh(host.id)
            }
        } catch {
            scanErrors[host.id] = error.localizedDescription
        }
    }

    /// Pins the sheet's keys. ``SSHServices`` then reports the change and the host is polled.
    func trust(_ request: TrustRequest) async throws {
        try await ssh.trust(request.offered, for: request.host, replacingPinned: false)
        if trustRequest?.id == request.id { trustRequest = nil }
    }

    // MARK: - Updates

    private func receive(_ update: HostMonitorUpdate) {
        pending[update.hostID] = update
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard !pending.isEmpty else { return }
        let updates = Array(pending.values)
        pending = [:]
        var blocksChanged = false
        // Off screen (minimised, hidden or covered) the cards still re-render; skip the gauge
        // animations there, which would otherwise run at the display rate for no one.
        var transaction = Transaction()
        transaction.disablesAnimations = !Self.mainWindowIsVisible()
        withTransaction(transaction) {
            for update in updates {
                guard let state = displayState(update.hostID) else { continue }
                if Self.isChanged(update.hostKeyIssue) != Self.isChanged(state.hostKeyIssue) {
                    blocksChanged = true
                }
                state.apply(update)
            }
        }
        if blocksChanged {
            // The store blocked the host (or lifted the block); mirror it for the banner.
            Task { await ssh.refreshHostKeyBlocks() }
        }
        didApplyUpdates?(updates)
    }

    private static func isChanged(_ issue: HostKeyIssue?) -> Bool {
        if case .changed = issue { true } else { false }
    }

    /// ``SSHServices`` pinned or re-checked a key: poll the host again if its monitor was
    /// holding it. A host with no issue keeps its schedule.
    private func hostKeysDidChange(for host: RemoteHost) {
        guard let coordinator, coordinator.latestUpdate(for: host.id)?.hostKeyIssue != nil else { return }
        coordinator.refresh(host.id)
    }

    /// A password was saved for the host: poll it again if its last poll failed to log in.
    private func passwordDidChange(for id: RemoteHost.ID) {
        guard let coordinator, coordinator.latestUpdate(for: id)?.lastError == .authFailed else { return }
        coordinator.refresh(id)
    }

    // MARK: - Hosts

    private func applyHosts() {
        // Monitoring off shows on the card whether or not the service runs (demo launches too),
        // without old numbers; turned back on, the host waits for its first poll.
        for host in hosts {
            guard let state = displayState(host.id) else { continue }
            if !host.monitored {
                state.reset(status: .unmonitored)
            } else if state.status == .unmonitored {
                state.reset()
            }
        }
        guard let coordinator else { return }
        let rejected = ssh.configRejections
        for host in hosts where host.monitored {
            guard let reason = rejected[host.id] else { continue }
            displayState(host.id)?.reset(status: .offline, message: "Not monitored: \(reason)")
        }
        // The coordinator skips hosts with monitoring off.
        coordinator.setHosts(hosts.filter { rejected[$0.id] == nil })
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

    // MARK: - Activity

    /// The activity for the current app, window and sleep state.
    private func currentActivity() -> MonitorActivity {
        if systemAsleep || screensAsleep { return .paused }
        if let activityOverride { return activityOverride }
        return NSApp.isActive && Self.mainWindowIsVisible() ? .visible : .background
    }

    private func updateActivity(refreshing: Bool = false) {
        guard let coordinator else { return }
        let next = currentActivity()
        coordinator.setActivity(next)
        if activity != next { activity = next }
        if refreshing, next != .paused {
            coordinator.refreshAll()
        }
    }

    /// Re-evaluates the activity on the next turn, once AppKit has finished showing, hiding or
    /// closing the window that triggered it. Bursts of notifications collapse into one check.
    private func scheduleActivityUpdate() {
        activityUpdate?.cancel()
        activityUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.updateActivity()
        }
    }

    private func observeActivity() {
        let app = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
        ] {
            observe(app, name) { $0.scheduleActivityUpdate() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { service in
            service.systemAsleep = true
            service.updateActivity()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { service in
            service.systemAsleep = false
            service.updateActivity(refreshing: true)
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { service in
            service.screensAsleep = true
            service.updateActivity()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { service in
            service.screensAsleep = false
            service.updateActivity(refreshing: true)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (MonitorService) -> Void) {
        let notifications = center.notifications(named: name)
        observers.append(Task { [weak self] in
            for await _ in notifications {
                guard let self else { return }
                handler(self)
            }
        })
    }

    /// Whether the main window (`Window(id: "main")`) is on screen and not fully covered.
    static func mainWindowIsVisible() -> Bool {
        NSApp.windows.contains { window in
            isMainWindow(window) && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
    }

    /// SwiftUI names a `Window`'s NSWindow after the scene id (`main`, or `main-AppWindow-1`).
    static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue else { return false }
        return identifier == AeroOpsApp.mainWindowID || identifier.hasPrefix("\(AeroOpsApp.mainWindowID)-")
    }
}

extension MonitorService: HostInventoryObserver {
    func hostsDidChange(_ hosts: [RemoteHost]) {
        self.hosts = hosts
        applyHosts()
    }
}

/// The monitors' command runner: the app's current ``SSHRunner``, swapped when the agent choice
/// changes (its environment points ssh at the in-app or the system agent). Reading it takes a
/// lock, not the main actor, so polls never wait for the UI.
final class SwitchableRunner: HostCommandRunning {
    private let current: Mutex<SSHRunner>

    init(_ runner: SSHRunner) {
        current = Mutex(runner)
    }

    func update(_ runner: SSHRunner) {
        current.withLock { $0 = runner }
    }

    func run(_ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration, outputLimit: Int) async throws -> SSHResult {
        let runner = current.withLock { $0 }
        return try await runner.run(command, on: host, stdin: stdin, timeout: timeout, outputLimit: outputLimit)
    }
}
