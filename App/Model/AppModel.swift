import AeroCore
import Foundation
import Observation
import SSHKit

/// The app's root state: host inventory, navigation and per-host live state.
///
/// One instance per app, created in `AeroOpsApp` and injected with `.environment(model)` into
/// both the main window and Settings. Views read it with `@Environment(AppModel.self)`.
///
/// Mutate hosts through ``addHost(_:)``, ``updateHost(_:)``, ``deleteHost(id:)`` and
/// ``reloadHosts()`` rather than on ``hostStore`` directly, so per-host state and
/// ``HostInventoryObserver``s stay in sync.
///
/// Phase 2 wiring: ``ssh`` (``SSHServices``) is a ``HostInventoryObserver`` that rewrites
/// `ssh_config`; ``availableKeys`` come from its key store; Test connection goes through
/// ``SSHConnectionTester``.
///
/// Plug-in points for later phases (no view changes needed):
/// - Phase 3: register the Collectors monitor pool as an observer; its `HostMonitor` actors call
///   ``updateState(of:status:metrics:message:)`` on the main actor.
/// - Phase 4: make ``canOpenSSH(_:)`` / ``openSSH(_:)`` open TerminalKit tabs.
@MainActor
@Observable
final class AppModel {
    // MARK: Inventory

    /// The persisted host inventory (`hosts.json`).
    let hostStore: HostStore

    /// All hosts, in inventory order.
    var hosts: [RemoteHost] { hostStore.hosts }

    // MARK: Navigation

    /// The main window's tab.
    var selectedTab: AppTab = .dashboard
    /// The host selected in the sidebar, if any. Cleared when that host is deleted.
    var selection: RemoteHost.ID?
    /// The Settings window's pane, so other views can deep-link (e.g. Activity → MCP).
    var settingsPane: SettingsPane = .hosts
    /// The main window's host editor sheet; `nil` when closed.
    var editorRequest: HostEditorRequest?

    // MARK: Services

    /// Keys, the in-app agent, `ssh_config` and host-key trust (Phase 2).
    let ssh: SSHServices
    /// Runs Settings › Hosts' Test connection: ``SSHConnectionTester`` unless injected.
    let connectionTester: any ConnectionTester

    /// Keys offered by the host editor's key picker.
    var availableKeys: [KeySummary] {
        ssh.keys.map {
            KeySummary(id: $0.id.uuidString, name: $0.name, detail: "\($0.algorithm.displayName) · \($0.fingerprint)")
        }
    }

    // MARK: Per-host state

    /// Live state per host id. Contains exactly the ids in ``hosts``.
    private(set) var displayStates: [RemoteHost.ID: HostDisplayState] = [:]

    @ObservationIgnored private var inventoryObservers: [any HostInventoryObserver] = []

    /// - Parameters:
    ///   - ssh: The SSH services; `nil` gives in-memory preview services that are never started.
    ///   - connectionTester: `nil` tests through `ssh`.
    init(hostStore: HostStore, ssh: SSHServices? = nil, connectionTester: (any ConnectionTester)? = nil) {
        let ssh = ssh ?? SSHServices.preview()
        self.hostStore = hostStore
        self.ssh = ssh
        self.connectionTester = connectionTester ?? SSHConnectionTester(services: ssh)
        hostsDidChange()
        addInventoryObserver(ssh)
    }

    /// Starts the SSH services (agent, key files, `ssh_config`). Called once at launch.
    func startServices() async {
        await ssh.start()
    }

    /// Stops the agent and closes shared SSH connections. Called before the app quits.
    /// Returns how many ControlMaster connections were closed.
    @discardableResult
    func shutdownServices() async -> Int {
        await ssh.shutdown()
    }

    /// The quit-time variant of ``shutdownServices()``: see ``SSHServices/beginShutdown()``.
    func beginShutdown() -> (@Sendable () async -> Void)? {
        guard let work = ssh.beginShutdown() else { return nil }
        return { _ = await work() }
    }

    /// The changed-key block for a host, if connections to it are refused.
    func hostKeyBlock(for id: RemoteHost.ID) -> HostKeyBlock? {
        host(id: id).flatMap(ssh.hostKeyBlock(for:))
    }

    // MARK: - Queries

    /// The selected host, if it still exists.
    var selectedHost: RemoteHost? {
        selection.flatMap(hostStore.host(id:))
    }

    /// The host with `id`, if any.
    func host(id: RemoteHost.ID) -> RemoteHost? {
        hostStore.host(id: id)
    }

    /// Live state for `id`. For an id not in the inventory this is a fresh, unregistered
    /// ``HostDisplayState`` in the loading state.
    func displayState(for id: RemoteHost.ID) -> HostDisplayState {
        displayStates[id] ?? HostDisplayState(hostID: id)
    }

    /// Number of hosts in each status, for summaries.
    func statusCounts() -> [HostStatus: Int] {
        hosts.reduce(into: [:]) { counts, host in counts[displayState(for: host.id).status, default: 0] += 1 }
    }

    // MARK: - Inventory mutations

    /// Adds `host`, saves, and selects it.
    func addHost(_ host: RemoteHost) throws(HostStoreError) {
        try hostStore.add(host)
        hostsDidChange()
        selection = host.id
    }

    /// Replaces the stored host with the same id and saves.
    func updateHost(_ host: RemoteHost) throws(HostStoreError) {
        try hostStore.update(host)
        hostsDidChange()
    }

    /// Deletes the host with `id` and saves. Clears the selection if it pointed at that host.
    func deleteHost(id: RemoteHost.ID) throws(HostStoreError) {
        try hostStore.delete(id: id)
        hostsDidChange()
    }

    /// Re-reads `hosts.json` (e.g. after a load error was fixed on disk).
    func reloadHosts() {
        hostStore.reload()
        hostsDidChange()
    }

    /// Registers `observer` and immediately tells it the current hosts.
    func addInventoryObserver(_ observer: any HostInventoryObserver) {
        inventoryObservers.append(observer)
        observer.hostsDidChange(hosts)
    }

    // MARK: - Live state

    /// Records a new status (and optionally metrics) for a host. Called by Phase 3 monitors.
    /// Ignored for hosts no longer in the inventory, so a late poll result can't resurrect one.
    func updateState(of id: RemoteHost.ID, status: HostStatus, metrics: MetricsSnapshot? = nil, message: String? = nil) {
        guard let state = displayStates[id] else { return }
        state.status = status
        if let metrics { state.metrics = metrics }
        state.message = message
        state.lastUpdated = .now
    }

    // MARK: - Editor sheet

    /// Opens the main window's host editor for a new host.
    func requestNewHost() {
        editorRequest = .new
    }

    /// Opens the main window's host editor for the host with `id`.
    func requestEdit(_ id: RemoteHost.ID) {
        editorRequest = .edit(id)
    }

    // MARK: - Terminals

    /// Whether Open SSH is available for the host. Always `false` until Phase 4 (TerminalKit);
    /// never for a host blocked by a changed host key.
    func canOpenSSH(_ id: RemoteHost.ID) -> Bool {
        guard hostKeyBlock(for: id) == nil else { return false }
        return false
    }

    /// Opens a terminal tab for the host. Phase 4 creates a TerminalKit session here and
    /// switches to ``AppTab/terminals``.
    func openSSH(_ id: RemoteHost.ID) {
        guard canOpenSSH(id) else { return }
        selectedTab = .terminals
    }

    // MARK: - Sync

    /// Keeps ``displayStates`` and ``selection`` in step with the inventory and notifies observers.
    private func hostsDidChange() {
        let current = hosts
        let ids = Set(current.map(\.id))
        if Set(displayStates.keys) != ids {
            var next = displayStates.filter { ids.contains($0.key) }
            for id in ids where next[id] == nil {
                next[id] = HostDisplayState(hostID: id)
            }
            displayStates = next
        }
        if let selection, !ids.contains(selection) {
            self.selection = nil
        }
        if case .edit(let id) = editorRequest, !ids.contains(id) {
            editorRequest = nil
        }
        for observer in inventoryObservers {
            observer.hostsDidChange(current)
        }
    }
}
