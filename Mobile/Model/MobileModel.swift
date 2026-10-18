import AeroCore
import Collectors
import CryptoKit
import EmbeddedSSH
import EmbeddedTerminal
import Foundation
import KeyAgent
import Observation
import SSHKit

/// The iOS app's state and services: the Mac app's AeroKit stack, with AeroKit's in-process
/// ``EmbeddedSSHClient`` in place of `/usr/bin/ssh` (iOS cannot spawn processes).
///
/// - Hosts: ``HostStore`` (`hosts.json` in the app container's Application Support).
/// - Keys: ``KeyStore`` over the Keychain (Ed25519; Secure Enclave P-256 on devices). Private keys
///   never leave the Keychain or the enclave; EmbeddedSSH signs with them in this process.
/// - Passwords: ``HostPasswordVault`` in the Keychain, read only by EmbeddedSSH at login.
/// - Host keys: ``HostKeyStore`` (`~/.aeroops/known_hosts` in the container), first-contact trust
///   and changed-key blocks exactly as on the Mac.
/// - Monitoring: Collectors' ``MonitorCoordinator`` with the embedded client as its runner; each
///   update goes into the host's ``HostDisplayState``, which the shared ``HostCard`` draws. Hosts
///   with monitoring off (``RemoteHost/monitored``) are not polled and show ``HostStatus/unmonitored``.
///
/// - Terminals and files: an ``EmbeddedTerminalSession`` and a ``MobileFileBrowser`` (SFTP) per
///   host, over the same embedded client and host-key checks.
///
/// Activity follows the scene: polling every 5 s while the app is active, paused (and every
/// connection closed) in the background, since iOS suspends the app and drops its sockets. An
/// open terminal then shows that it was disconnected and offers to reconnect.
@MainActor
@Observable
final class MobileModel {
    /// First-contact keys of a held host, for ``HostKeyTrustSheet``.
    struct TrustRequest: Identifiable {
        let host: RemoteHost
        let offered: [HostKey]
        var id: RemoteHost.ID { host.id }
    }

    /// The inventory, in `hosts.json` order.
    var hosts: [RemoteHost] { hostStore.hosts }
    /// Why `hosts.json` could not be read.
    var hostsError: String? { hostStore.loadError?.localizedDescription }
    private(set) var keys: [SSHKeyRecord] = []
    /// Why the key store could not be opened; monitoring needs it.
    private(set) var keyStoreError: String?
    /// Hosts whose key changed, by known_hosts name; mirrors ``HostKeyStore/blockedHosts``.
    private(set) var hostKeyBlocks: [String: HostKeyBlock] = [:]
    /// The trust sheet to show; set by ``requestHostKeyTrust(for:)``.
    var trustRequest: TrustRequest?
    /// Hosts whose key is being scanned for the trust sheet.
    private(set) var scanningHostIDs: Set<RemoteHost.ID> = []
    /// Why the last key scan for a host failed, shown on its card.
    private(set) var scanErrors: [RemoteHost.ID: String] = [:]
    private(set) var activity: MonitorActivity = .visible

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
    /// Sample data (previews, `-AeroOpsDemo`): terminals and files are canned too.
    @ObservationIgnored private(set) var isPreview = false
    @ObservationIgnored private var terminals: [RemoteHost.ID: EmbeddedTerminalSession] = [:]
    @ObservationIgnored private var fileBrowsers: [RemoteHost.ID: MobileFileBrowser<RemoteFileBackend>] = [:]
    @ObservationIgnored private var demoFileBrowsers: [RemoteHost.ID: MobileFileBrowser<DemoFileBackend>] = [:]

    /// `paths` roots every file; `secrets` and `passwordSecrets` hold the private keys and
    /// passwords (the Keychain in the app, memory in previews).
    init(paths: AeroPaths = .standard, secrets: any SecretStore, passwordSecrets: any SecretStore) {
        hostStore = HostStore(directory: paths.applicationSupport)
        let passwords = HostPasswordVault(store: passwordSecrets)
        self.passwords = passwords
        hostKeys = HostKeyStore(knownHostsFile: paths.knownHosts, scanner: EmbeddedHostKeyScanner())
        gate = PasswordAttemptGate { passwords.hasPassword(for: $0) }
        authorizer = .localAuthentication()
        do {
            let keyStore = try KeyStore(secretStore: secrets, paths: paths)
            self.keyStore = keyStore
            client = EmbeddedSSHClient(
                hostKeys: hostKeys,
                credentials: EmbeddedSSHCredentials(keyStore: keyStore, passwords: passwords, authorizer: authorizer),
                passwordGate: gate
            )
        } catch {
            keyStore = nil
            client = nil
            keyStoreError = error.localizedDescription
        }
        passwords.setPasswordHosts(passwordHostIDs)
    }

    /// The app's model: Keychain-backed secrets under the app container.
    static func live() -> MobileModel {
        MobileModel(secrets: KeychainSecretStore(), passwordSecrets: HostPasswordVault.keychainStore())
    }

    // MARK: - Lifecycle

    /// Loads keys and host-key blocks, then starts monitoring. Idempotent.
    func start() async {
        guard !isStarted else { return }
        isStarted = true
        // Downloads left from the last run.
        MobileFileBrowser<RemoteFileBackend>.removeAllDownloads()
        await reloadKeys()
        await refreshHostKeyBlocks()
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

    /// Follows the scene phase: active polls every 5 s and refreshes at once; background pauses
    /// and closes every connection (iOS would drop them anyway).
    func setActive(_ active: Bool) {
        let next: MonitorActivity = active ? .visible : .paused
        guard next != activity else { return }
        activity = next
        coordinator?.setActivity(next)
        if active {
            coordinator?.refreshAll()
        } else if let client {
            Task { await client.disconnectAll() }
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
    func save(_ host: RemoteHost, password: String?) throws {
        let isNew = hostStore.host(id: host.id) == nil
        if let password, host.auth == .password {
            try passwords.save(password, for: host.id)
        }
        do {
            if isNew { try hostStore.add(host) } else { try hostStore.update(host) }
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
        displayStates[id] = nil
        scanErrors[id] = nil
        closeTerminal(id)
        fileBrowsers.removeValue(forKey: id)?.close()
        hostsDidChange()
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

    private func hostsDidChange() {
        passwords.setPasswordHosts(passwordHostIDs)
        // The coordinator skips hosts with monitoring off.
        coordinator?.setHosts(hosts)
        // A host that left monitoring keeps no stale numbers; turned back on, it waits for its
        // first poll.
        let ids = Set(hosts.map(\.id))
        for id in displayStates.keys where !ids.contains(id) { displayStates[id] = nil }
        for host in hosts {
            fileBrowsers[host.id]?.hostDidChange(host)
        }
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

    /// Host `id`'s terminal, created (not connected) on first use: one per host, until
    /// ``closeTerminal(_:)``. Each connect opens a login shell on the host as it is then.
    func terminal(for id: RemoteHost.ID) -> EmbeddedTerminalSession {
        if let session = terminals[id] { return session }
        let session: EmbeddedTerminalSession
        if isPreview {
            let host = host(id: id)
            session = EmbeddedTerminalSession { _ in DemoTerminalChannel(user: host?.user ?? "dev", hostName: host?.name ?? "demo") }
        } else {
            session = EmbeddedTerminalSession { [weak self] size in
                guard let self else { throw CancellationError() }
                let (client, host) = try await self.sessionTarget(id)
                return try await client.openTerminal(on: host, term: EmbeddedTerminalSession.term, size: size)
            }
        }
        terminals[id] = session
        return session
    }

    /// Ends host `id`'s shell (the terminal screen was closed).
    func closeTerminal(_ id: RemoteHost.ID) {
        terminals.removeValue(forKey: id)?.close()
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

    func reloadKeys() async {
        guard let keyStore else { return }
        keys = await keyStore.keys
    }

    func key(id: String?) -> SSHKeyRecord? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return keys.first { $0.id == uuid }
    }

    @discardableResult
    func generateKey(_ type: KeyGenerationType, name: String, policy: SigningPolicy) async throws -> SSHKeyRecord {
        let record = try await requireKeyStore().generate(type, name: name, policy: policy)
        await keysDidChange()
        return record
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
    /// A model over throwaway files and in-memory secrets, with the sample hosts in every card
    /// state. For previews and the `-AeroOpsDemo` launch argument; never monitors.
    static func preview(hosts: [RemoteHost] = SampleData.hosts) -> MobileModel {
        let root = URL.temporaryDirectory.appending(path: "AeroOpsPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AeroPaths(
            dotDirectory: root.appending(path: "dot", directoryHint: .isDirectory),
            applicationSupport: root.appending(path: "support", directoryHint: .isDirectory)
        )
        let model = MobileModel(paths: paths, secrets: InMemorySecretStore(), passwordSecrets: InMemorySecretStore())
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
