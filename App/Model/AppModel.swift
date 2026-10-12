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
/// Phase 3 wiring: ``monitoring`` (``MonitorService``) is the second ``HostInventoryObserver``
/// (after ``ssh``, so `ssh_config` is current); it runs one Collectors `HostMonitor` per host and
/// copies their updates into ``displayStates``. See `AppModel+Monitoring.swift`.
///
/// Plug-in points for later phases (no view changes needed):
/// - Phase 4: ``terminals`` (``TerminalService``) holds the terminal tabs; ``openSSH(_:)`` and
///   ``openSSH(_:remoteCommand:title:)`` open them.
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
    /// Live metrics: one monitor per host, feeding ``displayStates`` (Phase 3).
    let monitoring: MonitorService
    /// Terminal tabs (Phase 4).
    let terminals: TerminalService
    /// The MCP bridge, approvals, audit log and live agent commands (Phases 7 and 8).
    /// See `AppModel+Agents.swift`.
    let agents: BridgeService

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
        monitoring = MonitorService(ssh: ssh)
        terminals = TerminalService(ssh: ssh) { hostStore.host(id: $0) }
        agents = BridgeService(ssh: ssh)
        hostsDidChange()
        addInventoryObserver(ssh)
        bindMonitoring()
        bindAgents()
    }

    /// Starts the SSH services (agent, key files, `ssh_config`), then monitoring, then the MCP
    /// bridge. Called once at launch.
    func startServices() async {
        await ssh.start()
        monitoring.start()
        agents.start()
    }

    /// Closes terminal tabs, stops monitoring, the agent and shared SSH connections. Called before
    /// the app quits.
    /// Returns how many ControlMaster connections were closed.
    @discardableResult
    func shutdownServices() async -> Int {
        terminals.closeAll()
        await agents.beginShutdown()?()
        await monitoring.beginShutdown()?()
        return await ssh.shutdown()
    }

    /// The quit-time variant of ``shutdownServices()``: see ``SSHServices/beginShutdown()``.
    /// Terminal tabs close first, so no ssh session outlives the agent that signs for it; then the
    /// MCP bridge and monitors stop, so no agent call or poll opens a connection while the masters
    /// close.
    func beginShutdown() -> (@Sendable () async -> Void)? {
        terminals.closeAll()
        let bridge = agents.beginShutdown()
        let monitors = monitoring.beginShutdown()
        let ssh = ssh.beginShutdown()
        guard bridge != nil || monitors != nil || ssh != nil else { return nil }
        return {
            await bridge?()
            await monitors?()
            _ = await ssh?()
        }
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

    /// Records a new status (and optionally metrics) for a host: previews and demo launches.
    /// Live polls go through ``MonitorService`` (``HostDisplayState/apply(_:)``).
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

    /// Whether Open SSH is available for the host: it exists, renders into `ssh_config`, is not
    /// blocked by a changed host key, and has its key with the agent running (or the system
    /// agent option is on).
    func canOpenSSH(_ id: RemoteHost.ID) -> Bool {
        guard let host = host(id: id) else { return false }
        return terminals.canOpen(host)
    }

    /// Opens an interactive ssh tab to the host and shows it in ``AppTab/terminals``. A host
    /// with no pinned host key first shows the trust sheet there.
    func openSSH(_ id: RemoteHost.ID) {
        guard let host = host(id: id), terminals.canOpen(host) else { return }
        selectedTab = .terminals
        terminals.open(host, kind: .shell)
    }

    /// Opens a tab running `remoteCommand` on the host (`ssh -t aero-<id> -- <remoteCommand>`),
    /// titled "<host> · <title>". `remoteCommand` must already be quoted with `ShellQuote`; it is
    /// passed to ssh as one argument, unchanged. The tab shows the exit status when it ends.
    func openSSH(_ id: RemoteHost.ID, remoteCommand: String, title: String? = nil) {
        guard let host = host(id: id), terminals.canOpen(host) else { return }
        selectedTab = .terminals
        terminals.open(host, kind: .remoteCommand(remoteCommand, title: title))
    }

    /// ⌘T: a new tab for the sidebar's host, else for the shown tab's host.
    var newTerminalTabHost: RemoteHost.ID? {
        if let selection, canOpenSSH(selection) { return selection }
        if let session = terminals.selectedSession, let tab = terminals.tab(for: session.id), canOpenSSH(tab.hostID) {
            return tab.hostID
        }
        return nil
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
