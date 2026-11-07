import AeroCore
import Collectors
import CryptoKit
import EmbeddedSSH
import EmbeddedTerminal
import Foundation
import KeyAgent
import Observation
import SSHKit

/// An open terminal. It stays open, connected or not, until ``MobileModel/closeTerminal(_:)``.
struct MobileTerminal: Identifiable {
    let id: UUID
    let hostID: RemoteHost.ID
    /// Tells a host's terminals apart: the lowest number not in use when it opened.
    let number: Int
    let session: EmbeddedTerminalSession
}

/// The iOS app's state and services: the Mac app's AeroKit stack, with AeroKit's in-process
/// ``EmbeddedSSHClient`` in place of `/usr/bin/ssh` (iOS cannot spawn processes).
///
/// - Hosts: ``HostStore`` in the Keychain the Mac app shares; each device keeps its own MCP tiers.
/// - Keys: ``KeyStore`` over the Keychain (Ed25519; Secure Enclave P-256 on devices). Private keys
///   never leave the Keychain or the enclave; EmbeddedSSH signs with them in this process.
/// - Passwords: ``HostPasswordVault`` in the Keychain, read only by EmbeddedSSH at login.
/// - Host keys: ``HostKeyStore`` pins in the Keychain, first-contact trust and changed-key blocks
///   exactly as on the Mac.
/// - Monitoring: Collectors' ``MonitorCoordinator`` with the embedded client as its runner; each
///   update goes into the host's ``HostDisplayState``, which the shared ``HostCard`` draws. Hosts
///   with monitoring off (``RemoteHost/monitored``) are not polled and show ``HostStatus/unmonitored``.
///
/// - Terminals and files: any number of ``MobileTerminal``s and a ``MobileFileBrowser`` (SFTP) per
///   host, over the same embedded client and host-key checks.
/// - Containers: the Mac app's ``ContainerService`` with the embedded client as its runner.
///
/// Activity follows the scene: polling every 5 s while the app is active, paused in the
/// background, where only connections that carry a session (a shell, an SFTP browser) stay open.
/// iOS suspends the app after a short grace period and may drop those sockets; on return, open
/// terminals check their connection and reconnect in place (``EmbeddedTerminalSession/resume(probeTimeout:)``).
@MainActor
@Observable
final class MobileModel {
    /// First-contact keys of a held host, for ``HostKeyTrustSheet``.
    struct TrustRequest: Identifiable {
        let host: RemoteHost
        let offered: [HostKey]
        var id: RemoteHost.ID { host.id }
    }

    /// The inventory, oldest first.
    var hosts: [RemoteHost] { hostStore.hosts }
    /// Why the hosts could not be read.
    var hostsError: String? { hostStore.loadError?.localizedDescription }
    /// Why the pinned host keys could not be read from the Keychain or copied to their file.
    private(set) var hostKeyError: String?
    private(set) var keys: [SSHKeyRecord] = []
    /// Why the key store could not be opened.
    private var keySetupError: String?
    /// Why the last reload of the keys failed.
    private var keyReloadError: String?
    var keyStoreError: String? { keySetupError ?? keyReloadError }
    /// Whether keys can be used at all; monitoring needs it.
    var hasKeyStore: Bool { keyStore != nil }
    /// Hosts whose key changed, by known_hosts name; mirrors ``HostKeyStore/blockedHosts``.
    private(set) var hostKeyBlocks: [String: HostKeyBlock] = [:]
    /// The trust sheet to show; set by ``requestHostKeyTrust(for:)``.
    var trustRequest: TrustRequest?
    /// Hosts whose key is being scanned for the trust sheet.
    private(set) var scanningHostIDs: Set<RemoteHost.ID> = []
    /// Why the last key scan for a host failed, shown on its card.
    private(set) var scanErrors: [RemoteHost.ID: String] = [:]
    private(set) var activity: MonitorActivity = .visible
    /// The open terminals, oldest first.
    private(set) var terminals: [MobileTerminal] = []
    /// Why the last folder change or drag and drop could not be saved.
    var layoutError: HostStoreError?

    /// Whether this device can make Secure Enclave keys (not the Simulator).
    let canUseSecureEnclave = SecureEnclave.isAvailable

    @ObservationIgnored private let hostStore: HostStore
    @ObservationIgnored private let keyStore: KeyStore?
    @ObservationIgnored private let passwords: HostPasswordVault
    @ObservationIgnored private let hostKeys: HostKeyStore
    @ObservationIgnored private let gate: PasswordAttemptGate
    @ObservationIgnored private let authorizer: PolicySigningAuthorizer
    @ObservationIgnored private let client: EmbeddedSSHClient?
    @ObservationIgnored private var coordinator: MonitorCoordinator?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var displayStates: [RemoteHost.ID: HostDisplayState] = [:]
    @ObservationIgnored private var isStarted = false
    /// Sample data (previews, "Try Sample Servers", `-AeroOpsDemo`): terminals and files are canned too.
    @ObservationIgnored private(set) var isPreview = false
    @ObservationIgnored private var fileBrowsers: [RemoteHost.ID: MobileFileBrowser<RemoteFileBackend>] = [:]
    @ObservationIgnored private var demoFileBrowsers: [RemoteHost.ID: MobileFileBrowser<DemoFileBackend>] = [:]
    /// Built on first use, because ``isPreview`` is set after init.
    @ObservationIgnored private lazy var containerService = makeContainerService()

    /// `paths` roots every file; `keychain`, `passwordKeychain` and `hostKeyKeychain` hold the
    /// keys, passwords and pins (the Keychain the Mac app shares in the app, memory in previews).
    /// `unlocked` says the user has just authenticated, which covers "once per session" keys.
    init(
        paths: AeroPaths, hostStore: HostStore, keychain: any KeychainStore,
        passwordKeychain: any KeychainStore, hostKeyKeychain: any KeychainStore, unlocked: Bool = false
    ) {
        self.hostStore = hostStore
        let passwords = HostPasswordVault(keychain: passwordKeychain)
        self.passwords = passwords
        hostKeys = HostKeyStore(keychain: hostKeyKeychain, knownHostsFile: paths.knownHosts, scanner: EmbeddedHostKeyScanner())
        gate = PasswordAttemptGate { passwords.hasPassword(for: $0) }
        authorizer = .localAuthentication(sessionApproved: unlocked)
        do {
            let keyStore = try KeyStore(keychain: keychain, paths: paths)
            self.keyStore = keyStore
            client = EmbeddedSSHClient(
                hostKeys: hostKeys,
                credentials: EmbeddedSSHCredentials(keyStore: keyStore, passwords: passwords, authorizer: authorizer),
                passwordGate: gate
            )
        } catch {
            keyStore = nil
            client = nil
            keySetupError = error.localizedDescription
        }
        passwords.setPasswordHosts(passwordHostIDs)
    }

    /// The app's model: hosts, keys, passwords and pins in the Keychain, files under the app container.
    /// Only built after an unlock.
    static func live() -> MobileModel {
        MobileModel(
            paths: AeroPaths(dotDirectory: .applicationSupportDirectory),
            hostStore: .system(), keychain: KeyStore.systemKeychain(),
            passwordKeychain: HostPasswordVault.systemKeychain(), hostKeyKeychain: HostKeyStore.systemKeychain(),
            unlocked: true
        )
    }

    // MARK: - Lifecycle

    /// Loads keys and host-key blocks, then starts monitoring. Idempotent.
    func start() async {
        guard !isStarted else { return }
        isStarted = true
        // Downloads left from the last run.
        MobileFileBrowser<RemoteFileBackend>.removeAllDownloads()
        await reloadKeys()
        await refreshHostKeys()
        guard let client else { return }
        let coordinator = MonitorCoordinator(runner: client, hostKeys: hostKeys, activity: activity)
        self.coordinator = coordinator
        let updates = coordinator.updates
        pump = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.receive(update)
            }
        }
        coordinator.setHosts(hosts)
    }

    /// Follows the scene phase: active polls every 5 s, refreshes at once and resumes the open
    /// terminals; background pauses and closes the connections no session is using.
    func setActive(_ active: Bool) {
        let next: MonitorActivity = active ? .visible : .paused
        guard next != activity else { return }
        activity = next
        coordinator?.setActivity(next)
        if active {
            coordinator?.refreshAll()
            resumeTerminals()
            Task { await keychainMayHaveChanged() }
        } else if let client {
            Task { await client.closeIdleConnections() }
        }
    }

    private func resumeTerminals() {
        for terminal in terminals {
            Task { await terminal.session.resume() }
        }
    }

    // MARK: - Monitoring

    /// The live state of host `id`, created on first use.
    func displayState(for id: RemoteHost.ID) -> HostDisplayState {
        if let state = displayStates[id] { return state }
        let state = HostDisplayState(hostID: id)
        if hostStore.host(id: id)?.monitored == false { state.status = .unmonitored }
        displayStates[id] = state
        return state
    }

    func statusCounts() -> [HostStatus: Int] {
        hosts.reduce(into: [:]) { counts, host in counts[displayState(for: host.id).status, default: 0] += 1 }
    }

    func refreshAll() {
        coordinator?.refreshAll()
    }

    func refresh(_ id: RemoteHost.ID) {
        coordinator?.refresh(id)
    }

    private func receive(_ update: HostMonitorUpdate) {
        let state = displayState(for: update.hostID)
        let blockChanged = Self.isChanged(update.hostKeyIssue) != Self.isChanged(state.hostKeyIssue)
        state.apply(update)
        if blockChanged {
            // The store blocked the host (or lifted the block); mirror it for the card and banner.
            Task { await refreshHostKeyBlocks() }
        }
    }

    private static func isChanged(_ issue: HostKeyIssue?) -> Bool {
        if case .changed = issue { true } else { false }
    }

    // MARK: - Hosts

    func host(id: RemoteHost.ID) -> RemoteHost? {
        hostStore.host(id: id)
    }

    /// Adds or updates `host`. A typed `password` is saved to the Keychain first, so a password
    /// host never exists without it; a new host's password is removed again if saving fails.
    /// A new host goes last into the folder with `folder` (`nil`: the top level).
    func save(_ host: RemoteHost, password: String?, folder: HostFolder.ID? = nil) throws {
        let isNew = hostStore.host(id: host.id) == nil
        if let password, host.auth == .password {
            try passwords.save(password, for: host.id)
        }
        do {
            if isNew { try hostStore.add(host, toFolder: folder) } else { try hostStore.update(host) }
        } catch {
            if password != nil, isNew { try? passwords.delete(for: host.id) }
            throw error
        }
        if host.auth == .key { try? passwords.delete(for: host.id) }
        hostsDidChange()
        let gate = gate
        Task {
            await gate.reset(host.id)
            refresh(host.id)
        }
    }

    func deleteHost(id: RemoteHost.ID) throws {
        try hostStore.delete(id: id)
        try? passwords.delete(for: id)
        forgetHost(id)
        hostsDidChange()
    }

    /// Ends what is still open for a host that is gone, deleted here or on another device.
    private func forgetHost(_ id: RemoteHost.ID) {
        displayStates[id] = nil
        scanErrors[id] = nil
        for terminal in terminals where terminal.hostID == id { closeTerminal(terminal.id) }
        fileBrowsers.removeValue(forKey: id)?.close()
        if let client { Task { await client.disconnect(id) } }
    }

    /// Turns monitoring of host `id` on or off (``RemoteHost/monitored``) and saves. The card stays
    /// either way.
    func setMonitoring(_ isOn: Bool, for id: RemoteHost.ID) throws {
        guard var host = hostStore.host(id: id), host.monitored != isOn else { return }
        host.monitored = isOn
        try hostStore.update(host)
        hostsDidChange()
    }

    /// Whether the Keychain holds a password for host `id` (for the editor).
    func hasSavedPassword(for id: RemoteHost.ID) -> Bool {
        passwords.isSaved(id)
    }

    private var passwordHostIDs: Set<RemoteHost.ID> {
        Set(hosts.lazy.filter { $0.auth == .password }.map(\.id))
    }

    /// A password saved on another device gets a fresh attempt.
    private func refreshPasswordHosts() {
        let gate = gate
        for id in passwords.setPasswordHosts(passwordHostIDs) {
            Task { [weak self] in
                await gate.reset(id)
                self?.coordinator?.refresh(id)
            }
        }
    }

    private func hostsDidChange() {
        refreshPasswordHosts()
        // The coordinator skips hosts with monitoring off.
        coordinator?.setHosts(hosts)
        containerService.hostsDidChange(hosts)
        for host in hosts {
            fileBrowsers[host.id]?.hostDidChange(host)
        }
        updateDisplayStates()
    }

    /// A host that left monitoring keeps no stale numbers; turned back on, it waits for its first poll.
    private func updateDisplayStates() {
        let ids = Set(hosts.map(\.id))
        for id in displayStates.keys where !ids.contains(id) { displayStates[id] = nil }
        for host in hosts {
            guard let state = displayStates[host.id] else { continue }
            if !host.monitored {
                state.reset(status: .unmonitored)
            } else if state.status == .unmonitored {
                state.reset()
            }
        }
    }

    // MARK: - Terminals and files

    /// Whether a terminal or the file browser can try host `host`: its key has not changed and
    /// the keys could be opened.
    func canOpenSession(on host: RemoteHost) -> Bool {
        hostKeyBlock(for: host) == nil && (client != nil || isPreview)
    }

    func terminal(id: MobileTerminal.ID) -> MobileTerminal? {
        terminals.first { $0.id == id }
    }

    /// Host `id`'s newest terminal, or a new one if it has none.
    func currentTerminal(on id: RemoteHost.ID) -> MobileTerminal {
        terminals.last { $0.hostID == id } ?? openTerminal(on: id)
    }

    /// A new terminal on host `id`, not connected yet. Each connect opens a login shell on the
    /// host as it is then.
    @discardableResult
    func openTerminal(on id: RemoteHost.ID) -> MobileTerminal {
        let used = Set(terminals.lazy.filter { $0.hostID == id }.map(\.number))
        let number = (1...).first { !used.contains($0) } ?? 1
        let terminal = MobileTerminal(id: UUID(), hostID: id, number: number, session: makeTerminalSession(on: id))
        terminals.append(terminal)
        return terminal
    }

    private func makeTerminalSession(on id: RemoteHost.ID) -> EmbeddedTerminalSession {
        if isPreview {
            let host = host(id: id)
            return EmbeddedTerminalSession { _ in DemoTerminalChannel(user: host?.user ?? "dev", hostName: host?.name ?? "demo") }
        }
        return EmbeddedTerminalSession { [weak self] size in
            guard let self else { throw CancellationError() }
            let (client, host) = try await self.sessionTarget(id)
            return try await client.openTerminal(on: host, term: EmbeddedTerminalSession.term, size: size)
        }
    }

    /// Ends a terminal's shell and removes it.
    func closeTerminal(_ id: MobileTerminal.ID) {
        terminals.first { $0.id == id }?.session.close()
        terminals.removeAll { $0.id == id }
    }

    /// Host `id`'s Docker and Kubernetes state. Nothing connects until its screen polls it.
    func containers(for id: RemoteHost.ID) -> HostContainersModel {
        containerService.model(for: id)
    }

    private func makeContainerService() -> ContainerService {
        let runner = workloadRunner
        return ContainerService(runner: { runner }, host: { [weak self] in self?.host(id: $0) })
    }

    private var workloadRunner: any RemoteCommandRunning {
        if isPreview { return DemoWorkloadRunner() }
        return client ?? UnavailableWorkloadRunner(reason: keyStoreError)
    }

    /// Host `host`'s file browser, kept while the host exists so its folder and transfers
    /// survive leaving the screen. Nothing connects until it lists its first folder.
    func fileBrowser(for host: RemoteHost) -> MobileFileBrowser<RemoteFileBackend> {
        if let browser = fileBrowsers[host.id] { return browser }
        let session = RemoteFileSession(host: host) { [weak self] requested in
            guard let self else { throw CancellationError() }
            let (client, current) = try sessionTarget(requested.id)
            return try await SFTPClient.connect(using: client, to: current)
        }
        let browser = MobileFileBrowser(host: host, backend: RemoteFileBackend(session: session))
        fileBrowsers[host.id] = browser
        return browser
    }

    /// The sample file browser for `-AeroOpsDemo` and previews.
    func demoFileBrowser(for host: RemoteHost) -> MobileFileBrowser<DemoFileBackend> {
        if let browser = demoFileBrowsers[host.id] { return browser }
        let browser = MobileFileBrowser(host: host, backend: DemoFileBackend(user: host.user))
        browser.seedDemoTransfers()
        demoFileBrowsers[host.id] = browser
        return browser
    }

    /// The client and the host as it is now, for a session opened now.
    private func sessionTarget(_ id: RemoteHost.ID) throws -> (EmbeddedSSHClient, RemoteHost) {
        guard let host = host(id: id) else { throw SSHError.invalidRequest("the server was removed") }
        guard let client else {
            throw SSHError.other(MobileModelError.keyStoreUnavailable(keyStoreError).localizedDescription)
        }
        return (client, host)
    }

    // MARK: - Host keys

    /// Whether `host` has a pinned key, so a session can connect without the trust sheet.
    func isHostKeyPinned(_ host: RemoteHost) async -> Bool {
        (try? await hostKeys.pinnedKeys(for: host).isEmpty) == false
    }

    /// The block for `host`, if its key changed.
    func hostKeyBlock(for host: RemoteHost) -> HostKeyBlock? {
        hostKeyBlocks[host.knownHostsName]
    }

    func refreshHostKeyBlocks() async {
        hostKeyBlocks = await hostKeys.blockedHosts
    }

    /// Scans a held host's key and opens the trust sheet. A key that is pinned (or changed) by
    /// now just polls again.
    func requestHostKeyTrust(for host: RemoteHost) async {
        guard !scanningHostIDs.contains(host.id) else { return }
        scanningHostIDs.insert(host.id)
        scanErrors[host.id] = nil
        defer { scanningHostIDs.remove(host.id) }
        do {
            switch try await hostKeys.verify(host) {
            case .unknown(let offered):
                trustRequest = TrustRequest(host: host, offered: offered)
            case .trusted:
                refresh(host.id)
            case .changed:
                await refreshHostKeyBlocks()
                refresh(host.id)
            }
        } catch {
            scanErrors[host.id] = error.localizedDescription
        }
    }

    /// Pins the sheet's keys and polls the host.
    func trust(_ request: TrustRequest) async throws {
        try await trust(request.offered, for: request.host, replacingPinned: false)
        if trustRequest?.id == request.id { trustRequest = nil }
    }

    /// Pins `keys` for `host`. With `replacingPinned`, the old pins go first (the user accepted a
    /// changed key) and the block is lifted.
    func trust(_ keys: [HostKey], for host: RemoteHost, replacingPinned: Bool) async throws {
        for (index, key) in keys.enumerated() {
            try await hostKeys.trust(key, for: host, replacingPinned: replacingPinned && index == 0)
        }
        await refreshHostKeyBlocks()
        refresh(host.id)
    }

    /// Scans the server again to learn which key it presents now. A pinned key lifts the block.
    func recheckHostKey(_ host: RemoteHost) async throws {
        if case .trusted = try await hostKeys.verify(host) { await hostKeys.unblock(host) }
        await refreshHostKeyBlocks()
        refresh(host.id)
    }

    // MARK: - Keys

    /// Re-reads the keys from the Keychain, including ones synced from the user's other devices.
    func reloadKeys() async {
        guard let keyStore else { return }
        do {
            try await keyStore.reload()
            keyReloadError = nil
        } catch {
            keyReloadError = error.localizedDescription
        }
        keys = await keyStore.keys
    }

    /// Takes in the pins made on the user's other devices, and polls again when that changed anything.
    private func refreshHostKeys() async {
        do {
            let changed = try await hostKeys.refreshKnownHostsFile()
            hostKeyError = nil
            await refreshHostKeyBlocks()
            if changed { coordinator?.refreshAll() }
        } catch {
            hostKeyError = error.localizedDescription
        }
    }

    /// Hosts, keys and passwords synced from the user's other devices show up when the app comes forward.
    private func keychainMayHaveChanged() async {
        let previous = Set(hosts.map(\.id))
        if hostStore.reload() { hostsDidChange() }
        for id in previous.subtracting(hosts.map(\.id)) { forgetHost(id) }
        refreshPasswordHosts()
        await refreshHostKeys()
        await keysDidChange()
    }

    func key(id: String?) -> SSHKeyRecord? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return keys.first { $0.id == uuid }
    }

    @discardableResult
    func generateKey(_ type: KeyGenerationType, name: String, policy: SigningPolicy, syncs: Bool = true) async throws -> SSHKeyRecord {
        let record = try await requireKeyStore().generate(type, name: name, policy: policy, syncs: syncs)
        await keysDidChange()
        return record
    }

    /// Turns iCloud Keychain sync on or off for a key.
    func setSyncs(_ syncs: Bool, for id: UUID) async throws {
        try await requireKeyStore().setSyncs(id: id, syncs)
        await keysDidChange()
    }

    func setPolicy(_ policy: SigningPolicy, for id: UUID) async throws {
        try await requireKeyStore().setPolicy(id: id, policy)
        await authorizer.forgetSessionApproval(for: id)
        await keysDidChange()
    }

    func deleteKey(_ id: UUID) async throws {
        try await requireKeyStore().delete(id: id)
        await authorizer.forgetSessionApproval(for: id)
        await keysDidChange()
    }

    private func requireKeyStore() throws -> KeyStore {
        guard let keyStore else { throw MobileModelError.keyStoreUnavailable(keyStoreError) }
        return keyStore
    }

    /// New keys and policies apply to the next login: hosts that failed to log in try again.
    private func keysDidChange() async {
        await reloadKeys()
        guard let coordinator else { return }
        for host in hosts where coordinator.latestUpdate(for: host.id)?.lastError == .authFailed {
            coordinator.refresh(host.id)
        }
    }
}

enum MobileModelError: LocalizedError {
    case keyStoreUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .keyStoreUnavailable(let reason): "The key store is unavailable\(reason.map { ": \($0)" } ?? ".")"
        }
    }
}

extension MobileModel {
    /// A model over throwaway files and in-memory hosts and secrets, with the sample hosts in every card
    /// state. For previews, "Try Sample Servers" and `-AeroOpsDemo`; never monitors.
    static func preview(hosts: [RemoteHost] = SampleData.hosts) -> MobileModel {
        let root = URL.temporaryDirectory.appending(path: "AeroOpsPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AeroPaths(dotDirectory: root.appending(path: "dot", directoryHint: .isDirectory))
        let model = MobileModel(
            paths: paths, hostStore: .inMemory(), keychain: InMemoryKeychain(),
            passwordKeychain: InMemoryKeychain(), hostKeyKeychain: InMemoryKeychain()
        )
        for host in hosts { try? model.hostStore.add(host) }
        // Hosts with monitoring off get no update.
        for update in SampleData.liveUpdates(for: model.hosts) {
            model.displayState(for: update.hostID).apply(update)
        }
        model.isStarted = true
        model.isPreview = true
        return model
    }
}

extension MobileModel: HostLayoutEditing {
    var layoutStore: HostStore { hostStore }

    func layoutDidChange() {
        hostsDidChange()
    }
}
