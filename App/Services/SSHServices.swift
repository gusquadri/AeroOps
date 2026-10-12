import AeroCore
import AppKit
import AskpassProtocol
import Foundation
import KeyAgent
import Observation
import SSHKit

/// The app's SSH plumbing (Phase 2): Keychain-backed keys, the in-app ssh-agent, the generated
/// `ssh_config`, trust-on-first-use host keys and Test connection.
///
/// One instance per app, owned by ``AppModel/ssh``. ``start()`` runs at launch and
/// ``shutdown()`` before the app quits (``AppDelegate``). Every path comes from ``paths``, so the
/// DEBUG self-test and previews run against a temporary root instead of `~/.aeroops`.
///
/// - Keys: ``KeyStore`` over a ``SecretStore`` (the Keychain in the app). Private keys never touch
///   the disk; only `keys.json` metadata and `pub/<id>.pub` files are written.
/// - Agent: ``SSHAgentServer`` on `agent.sock` with a ``PolicySigningAuthorizer`` (Touch ID per the
///   key's policy). Peer and signing events are kept in ``agentEvents`` for the Activity tab.
/// - Config: rewritten whenever hosts change (``HostInventoryObserver``), keys change or the
///   agent choice changes.
/// - Host keys: ``HostKeyStore``; ``hostKeyBlocks`` mirrors its blocks for the UI.
/// - Passwords: ``HostPasswordVault`` over a second ``SecretStore``, handed to ssh
///   only through ``AskpassServer`` on `askpass.sock` and the bundled `aeroops-askpass`.
///   ``passwordGate`` keeps background ssh from retrying a rejected password.
@MainActor
@Observable
final class SSHServices {
    /// What signs for ssh, for Settings › Keys.
    enum AgentStatus: Equatable, Sendable {
        case stopped
        case running(socket: String)
        /// "Use system ssh-agent instead" is on; the in-app agent is stopped.
        case usingSystemAgent
        case failed(String)
    }

    /// Agent events kept for the Activity tab (Phase 7), newest last.
    static let eventLimit = 200
    /// `UserDefaults` key of the "Use system ssh-agent instead" toggle.
    static let systemAgentDefaultsKey = "UseSystemSSHAgent"

    /// Runtime paths: `~/.aeroops` and Application Support in the app.
    let paths: AeroPaths

    /// All keys, oldest first.
    private(set) var keys: [SSHKeyRecord] = []
    /// Why the key store could not be opened or refreshed, if it could not.
    private(set) var keyStoreError: String?
    private(set) var agentStatus: AgentStatus = .stopped
    /// Peer and signing events (connected, rejected, signed, sign failed), at most ``eventLimit``.
    private(set) var agentEvents: [AgentEvent] = []
    /// Hosts whose key changed, keyed by known_hosts name. Connections to them are refused.
    private(set) var hostKeyBlocks: [String: HostKeyBlock] = [:]
    /// Hosts left out of `ssh_config`, with the reason.
    private(set) var configRejections: [RemoteHost.ID: String] = [:]
    /// Why `ssh_config` could not be written at all.
    private(set) var configError: String?
    /// In-app agent, or the system one (the fallback toggle).
    private(set) var agentChoice: SSHContext.AgentChoice
    /// How ssh asks for passwords; `nil` until the askpass server runs, or when it cannot.
    private(set) var askpassRoute: AskpassRoute?
    /// Why password hosts cannot log in from the background, if they cannot.
    private(set) var askpassError: String?
    /// Password hosts whose saved password failed. ssh does not try them again until the
    /// password is saved again, a test connection succeeds or the host's settings change.
    private(set) var rejectedPasswords: Set<RemoteHost.ID> = []
    /// Why `aeroops-askpass` last got no password for a host (safe to show).
    private(set) var askpassRefusals: [RemoteHost.ID: String] = [:]

    @ObservationIgnored let keyStore: KeyStore?
    @ObservationIgnored let secretStore: any SecretStore
    @ObservationIgnored let hostKeys: HostKeyStore
    @ObservationIgnored let authorizer: PolicySigningAuthorizer
    @ObservationIgnored let passwords: HostPasswordVault
    @ObservationIgnored let passwordGate: PasswordAttemptGate
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var agent: SSHAgentServer?
    @ObservationIgnored private var eventPump: Task<Void, Never>?
    @ObservationIgnored private var askpassServer: AskpassServer?
    @ObservationIgnored private var askpassObservers: [Task<Void, Never>] = []
    @ObservationIgnored private var sessionObservers: [Task<Void, Never>] = []
    @ObservationIgnored private var hosts: [RemoteHost] = []
    @ObservationIgnored private(set) var isStarted = false
    /// Called after ``trust(_:for:replacingPinned:)`` or ``recheckHostKey(_:)`` changed what is
    /// pinned or blocked for a host, so ``MonitorService`` can resume polling it.
    @ObservationIgnored var hostKeysDidChange: (@MainActor (RemoteHost) -> Void)?
    /// Called after a host's password was saved, so ``MonitorService`` can retry it at once.
    @ObservationIgnored var passwordsDidChange: (@MainActor (RemoteHost.ID) -> Void)?

    /// - Parameters:
    ///   - defaults: Where the agent toggle is persisted; `nil` keeps it in memory (self-test, previews).
    ///   - passwordStore: Where host passwords are kept; `nil` keeps them in memory (self-test, previews).
    init(
        paths: AeroPaths,
        secretStore: any SecretStore,
        passwordStore: (any SecretStore)? = nil,
        defaults: UserDefaults?,
        authorizer: PolicySigningAuthorizer = .localAuthentication()
    ) {
        self.paths = paths
        self.secretStore = secretStore
        self.defaults = defaults
        self.authorizer = authorizer
        let passwords = HostPasswordVault(store: passwordStore ?? InMemorySecretStore())
        self.passwords = passwords
        passwordGate = PasswordAttemptGate { passwords.hasPassword(for: $0) }
        agentChoice = defaults?.bool(forKey: Self.systemAgentDefaultsKey) == true ? .system : .inApp
        hostKeys = HostKeyStore(context: SSHContext(paths: paths))
        do {
            keyStore = try KeyStore(secretStore: secretStore, paths: paths)
        } catch {
            keyStore = nil
            keyStoreError = error.localizedDescription
        }
    }

    /// The SSHKit context for the current agent choice and askpass route.
    var context: SSHContext {
        var context = SSHContext(paths: paths, agent: agentChoice)
        context.askpass = askpassRoute
        return context
    }

    /// Runs commands on hosts; refuses blocked hosts and password hosts the gate holds back.
    var runner: SSHRunner { SSHRunner(context: context, hostKeys: hostKeys, passwords: passwordGate) }

    // MARK: - Lifecycle

    /// Writes the public key files, starts the agent (unless the system agent is chosen) and the
    /// askpass server, and writes `ssh_config`. Failures are reported in ``agentStatus``,
    /// ``askpassError``, ``keyStoreError`` and ``configError``; nothing here throws.
    ///
    /// Runs before monitoring starts (``AppModel/startServices()``), so the first runner already
    /// has the askpass route.
    func start() async {
        guard !isStarted else { return }
        isStarted = true
        do {
            try SSHConfigWriter(context: context).prepareDirectories()
        } catch {
            configError = error.localizedDescription
        }
        await reloadKeys(rewritingPublicKeyFiles: true)
        await applyAgentChoice()
        startAskpass()
        writeConfig()
        await refreshHostKeyBlocks()
        observeSessionEnd()
    }

    /// Closes every ControlMaster connection and stops the agent (removing its socket). Returns
    /// how many masters acknowledged. Safe to call more than once.
    @discardableResult
    func shutdown() async -> Int {
        guard let work = beginShutdown() else { return 0 }
        return await work()
    }

    /// Marks the services stopped and returns the rest of the shutdown (closing masters,
    /// stopping the agent, ending Touch ID sessions), which runs without the main actor. Used
    /// when quitting, where the main actor may be blocked (see ``AppDelegate``). `nil` if not
    /// started.
    func beginShutdown() -> (@Sendable () async -> Int)? {
        guard isStarted else { return nil }
        isStarted = false
        eventPump?.cancel()
        eventPump = nil
        sessionObservers.forEach { $0.cancel() }
        sessionObservers = []
        askpassObservers.forEach { $0.cancel() }
        askpassObservers = []
        askpassServer?.stop()
        askpassServer = nil
        askpassRoute = nil
        if case .running = agentStatus { agentStatus = .stopped }
        let masters = ControlMaster(context: context)
        let agent = agent
        let authorizer = authorizer
        return {
            let closed = await masters.closeAll()
            await agent?.stop()
            await authorizer.endSession()
            return closed
        }
    }

    /// Switches between the in-app agent and the system one, rewrites `ssh_config` and closes
    /// shared connections (they were authenticated through the other agent).
    func setAgentChoice(_ choice: SSHContext.AgentChoice) async {
        guard choice != agentChoice else { return }
        agentChoice = choice
        defaults?.set(choice == .system, forKey: Self.systemAgentDefaultsKey)
        guard isStarted else { return }
        _ = await ControlMaster(context: context).closeAll()
        await applyAgentChoice()
        writeConfig()
    }

    private func applyAgentChoice() async {
        switch agentChoice {
        case .system:
            await agent?.stop()
            agentStatus = .usingSystemAgent
        case .inApp:
            guard let keyStore else {
                agentStatus = .failed(keyStoreError ?? "The key store is unavailable.")
                return
            }
            let server = agent ?? makeAgent(keyStore)
            if eventPump == nil { pumpEvents(from: server) }
            do {
                try await server.start()
                agentStatus = .running(socket: server.socketURL.path(percentEncoded: false))
            } catch {
                agentStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func makeAgent(_ keyStore: KeyStore) -> SSHAgentServer {
        let server = SSHAgentServer(socketURL: paths.agentSocket, keyStore: keyStore, authorizer: authorizer)
        agent = server
        return server
    }

    private func pumpEvents(from server: SSHAgentServer) {
        let events = server.events
        eventPump = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.record(event)
            }
        }
    }

    private func record(_ event: AgentEvent) {
        switch event.kind {
        case .connected, .rejected, .signed, .signFailed:
            agentEvents.append(event)
            if agentEvents.count > Self.eventLimit {
                agentEvents.removeFirst(agentEvents.count - Self.eventLimit)
            }
        case .identitiesListed, .sessionBound, .refused, .disconnected:
            break
        }
    }

    // MARK: - Askpass

    /// `AeroOps.app/Contents/MacOS/aeroops-askpass`, if the bundle has it.
    nonisolated static var bundledAskpassHelper: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent().appending(path: Askpass.helperName)
        return FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)) ? helper : nil
    }

    /// Starts the askpass server and sets ``askpassRoute``. Without a route, password hosts fail
    /// authentication in the background (ssh keeps `BatchMode=yes`, so no password is tried) and
    /// terminal tabs prompt for the password.
    private func startAskpass() {
        let server = AskpassServer(socketURL: paths.askpassSocket, vault: passwords, validator: SignedAskpassPeerValidator())
        askpassServer = server
        observeAskpass(server)
        guard let helper = Self.bundledAskpassHelper else {
            askpassError = "\(Askpass.helperName) is missing from the app bundle."
            return
        }
        guard SignedAskpassPeerValidator.ownTeamIdentifier() != nil else {
            askpassError = "AeroOps is not signed with a team ID, so it cannot verify \(Askpass.helperName)."
            return
        }
        do {
            try server.start()
            askpassRoute = AskpassRoute(helper: helper, socket: server.socketURL)
            askpassError = nil
        } catch {
            askpassError = error.localizedDescription
        }
    }

    private func observeAskpass(_ server: AskpassServer) {
        let events = server.events
        let gate = passwordGate
        askpassObservers = [
            Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.record(event)
                }
            },
            Task { [weak self] in
                for await rejected in await gate.changes() {
                    guard let self else { return }
                    self.rejectedPasswords = rejected
                }
            },
        ]
    }

    /// Keeps the refusal reason, and closes the gate when askpass refused a saved password:
    /// terminal tabs reach the server without going through the runner.
    private func record(_ event: AskpassEvent) async {
        guard let host = event.host, !event.viaToken else { return }
        switch event.outcome {
        case .answered:
            askpassRefusals[host] = nil
        case .refused(.untrustedPeer), .refused(.malformedRequest):
            // Not from ssh that the app started; the host id is not to be trusted.
            break
        case .refused(let refusal):
            askpassRefusals[host] = refusal.description
            await passwordGate.reject(host)
        }
    }

    /// "Once per session" approvals end when the Mac sleeps or the screen locks.
    private func observeSessionEnd() {
        let authorizer = authorizer
        let sleep = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification)
        let lock = DistributedNotificationCenter.default().notifications(named: Notification.Name("com.apple.screenIsLocked"))
        sessionObservers = [
            Task { for await _ in sleep { await authorizer.endSession() } },
            Task { for await _ in lock { await authorizer.endSession() } },
        ]
    }

    // MARK: - ssh_config

    /// Rewrites `ssh_config` for the current hosts and agent choice.
    @discardableResult
    func writeConfig() -> SSHConfigRendering? {
        do {
            let rendering = try SSHConfigWriter(context: context).write(hosts)
            configRejections = rendering.rejected.mapValues { $0.localizedDescription }
            configError = nil
            return rendering
        } catch {
            configError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Keys

    enum KeyActionError: LocalizedError {
        case storeUnavailable(String?)
        case fileTooLarge
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .storeUnavailable(let why): "The key store is unavailable. \(why ?? "")"
            case .fileTooLarge: "That file is too large to be an SSH private key."
            case .unreadable(let why): "The file could not be read: \(why)"
            }
        }
    }

    /// The key a host uses, if it still exists.
    func key(for host: RemoteHost) -> SSHKeyRecord? {
        guard let keyId = host.keyId else { return nil }
        return keys.first { $0.id.uuidString == keyId }
    }

    /// Re-reads the key list (and optionally rewrites every `.pub` file).
    func reloadKeys(rewritingPublicKeyFiles: Bool = false) async {
        guard let keyStore else { return }
        if rewritingPublicKeyFiles {
            do {
                try await keyStore.writePublicKeyFiles()
            } catch {
                keyStoreError = error.localizedDescription
            }
        }
        keys = await keyStore.keys
    }

    func generateKey(_ type: KeyGenerationType, name: String, policy: SigningPolicy) async throws -> SSHKeyRecord {
        let record = try await requireKeyStore().generate(type, name: name, policy: policy)
        await keysDidChange()
        return record
    }

    /// Imports an unencrypted OpenSSH private key file. The text is read into memory only; the
    /// file is left alone (the UI then offers to move it to the Trash).
    func importKey(contentsOf url: URL, policy: SigningPolicy) async throws -> SSHKeyRecord {
        let store = try requireKeyStore()
        let text = try Self.readPrivateKeyText(url)
        let record = try await store.importOpenSSHPrivateKey(text, policy: policy)
        await keysDidChange()
        return record
    }

    func renameKey(_ id: UUID, to name: String) async throws {
        try await requireKeyStore().rename(id: id, to: name)
        await keysDidChange()
    }

    /// Changes the policy and drops any session approval, so a stricter policy applies at once.
    func setPolicy(_ policy: SigningPolicy, forKey id: UUID) async throws {
        try await requireKeyStore().setPolicy(id: id, policy)
        await authorizer.forgetSessionApproval(for: id)
        await keysDidChange()
    }

    /// Deletes the Keychain item (or Secure Enclave handle), the `.pub` file and the metadata.
    func deleteKey(_ id: UUID) async throws {
        try await requireKeyStore().delete(id: id)
        await authorizer.forgetSessionApproval(for: id)
        await keysDidChange()
    }

    private func requireKeyStore() throws -> KeyStore {
        guard let keyStore else { throw KeyActionError.storeUnavailable(keyStoreError) }
        return keyStore
    }

    private func keysDidChange() async {
        await reloadKeys()
        if isStarted { writeConfig() }
    }

    /// OpenSSH private keys are a few KB; refuse anything big before reading it.
    nonisolated static func readPrivateKeyText(_ url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 64 * 1024 else { throw KeyActionError.fileTooLarge }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw KeyActionError.unreadable(error.localizedDescription)
        }
    }

    // MARK: - Passwords

    /// Whether `host` uses a password and one is saved.
    func hasPassword(for host: RemoteHost) -> Bool {
        host.auth == .password && passwords.hasPassword(for: host.id)
    }

    /// Whether a password is saved for `id`, asking the Keychain (the cache only covers saved
    /// password hosts). For the host editor.
    func hasSavedPassword(for id: RemoteHost.ID) -> Bool {
        passwords.isSaved(id)
    }

    /// Saves `password` for the host `id` in the Keychain, then lets ssh try it again.
    func setPassword(_ password: String, for id: RemoteHost.ID) throws(HostPasswordError) {
        try passwords.save(password, for: id)
        askpassRefusals[id] = nil
        let gate = passwordGate
        Task { [weak self] in
            await gate.reset(id)
            self?.passwordsDidChange?(id)
        }
    }

    /// Deletes the saved password of the host `id`, e.g. when the host is deleted or switched to
    /// key authentication.
    func deletePassword(for id: RemoteHost.ID) throws(SecretStoreError) {
        try passwords.delete(for: id)
        askpassRefusals[id] = nil
        let gate = passwordGate
        Task { await gate.reset(id) }
    }

    /// The context for a terminal tab to `host`. A password host without a usable saved
    /// password prompts in the tab instead of asking `aeroops-askpass`.
    func terminalContext(for host: RemoteHost) -> SSHContext {
        var context = self.context
        if host.auth == .password, !hasPassword(for: host) || rejectedPasswords.contains(host.id) {
            context.askpass = nil
        }
        return context
    }

    // MARK: - Host keys

    /// The block for `host`, if its key changed.
    func hostKeyBlock(for host: RemoteHost) -> HostKeyBlock? {
        hostKeyBlocks[host.knownHostsName]
    }

    func refreshHostKeyBlocks() async {
        hostKeyBlocks = await hostKeys.blockedHosts
    }

    /// Pins `keys` for `host` in known_hosts. With `replacingPinned`, the old pins go first (the
    /// user accepted a changed key) and the block is lifted.
    func trust(_ keys: [HostKey], for host: RemoteHost, replacingPinned: Bool) async throws {
        for (index, key) in keys.enumerated() {
            try await hostKeys.trust(key, for: host, replacingPinned: replacingPinned && index == 0)
        }
        await refreshHostKeyBlocks()
        hostKeysDidChange?(host)
    }

    /// Scans the server again (three unauthenticated connections) to learn which key it presents
    /// now, e.g. after ssh itself reported a change. If it presents a pinned key again the block
    /// is lifted; ssh still enforces the pins on every connection.
    func recheckHostKey(_ host: RemoteHost) async throws -> HostKeyVerification {
        let verification = try await hostKeys.verify(host)
        if case .trusted = verification { await hostKeys.unblock(host) }
        await refreshHostKeyBlocks()
        hostKeysDidChange?(host)
        return verification
    }
}

extension SSHServices: HostInventoryObserver {
    func hostsDidChange(_ hosts: [RemoteHost]) {
        let previous = Dictionary(self.hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.hosts = hosts
        passwords.setPasswordHosts(Set(hosts.lazy.filter { $0.auth == .password }.map(\.id)))
        // New connection settings deserve a fresh attempt with the saved password.
        for host in hosts where host.auth == .password {
            guard let old = previous[host.id],
                  old.address != host.address || old.port != host.port || old.user != host.user || old.auth != host.auth
            else { continue }
            askpassRefusals[host.id] = nil
            let gate = passwordGate
            Task { await gate.reset(host.id) }
        }
        if isStarted { writeConfig() }
    }
}

extension SSHServices {
    /// Services for previews: a temporary root, keys in memory, nothing started.
    static func preview() -> SSHServices {
        let root = URL.temporaryDirectory.appending(path: "AeroOpsPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AeroPaths(
            dotDirectory: root.appending(path: "dot", directoryHint: .isDirectory),
            applicationSupport: root.appending(path: "support", directoryHint: .isDirectory)
        )
        return SSHServices(paths: paths, secretStore: InMemorySecretStore(), defaults: nil)
    }

    /// Adds sample keys and a blocked host, for previews and the DEBUG demo options.
    /// Only for in-memory or temporary stores.
    func loadSampleData(blocking host: RemoteHost? = nil) async {
        if keys.isEmpty {
            _ = try? await generateKey(.ed25519, name: "MacBook Ed25519", policy: .oncePerSession)
            _ = try? await generateKey(.secureEnclaveP256, name: "Secure Enclave", policy: .everySignature)
            _ = try? await generateKey(.ed25519, name: "CI deploy", policy: .always)
        }
        if let host {
            let pinned = SampleHostKeys.ed25519(seed: 1)
            try? await hostKeys.trust(pinned, for: host)
            await hostKeys.block(host, offered: [SampleHostKeys.ed25519(seed: 2), SampleHostKeys.ecdsa(seed: 3)])
            await refreshHostKeyBlocks()
        }
    }
}

/// Well-formed but meaningless host keys for previews and demo snapshots.
enum SampleHostKeys {
    static func ed25519(seed: UInt8) -> HostKey {
        make(type: "ssh-ed25519", body: [Data(repeating: seed, count: 32)])
    }

    static func ecdsa(seed: UInt8) -> HostKey {
        make(type: "ecdsa-sha2-nistp256", body: [Data("nistp256".utf8), Data([0x04]) + Data(repeating: seed, count: 64)])
    }

    private static func make(type: String, body: [Data]) -> HostKey {
        var blob = Data()
        for field in [Data(type.utf8)] + body {
            var length = UInt32(field.count).bigEndian
            blob.append(Data(bytes: &length, count: 4))
            blob.append(field)
        }
        // The blob is built above with a valid type prefix, so parsing cannot fail.
        return try! HostKey(type: type, base64: blob.base64EncodedString())
    }
}
