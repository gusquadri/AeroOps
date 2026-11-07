import AeroCore
import Collectors
import Foundation
import Observation
import SSHKit
import TerminalKit

/// The Terminals tab (Phase 4): one libghostty session per tab, each running the system
/// `/usr/bin/ssh` against the generated `ssh_config` with the in-app agent.
///
/// Owned by ``AppModel/terminals``; views go through ``AppModel/openSSH(_:)`` and
/// ``AppModel/openSSH(_:remoteCommand:title:)`` to open tabs.
///
/// - First contact: a host with no pinned key is scanned first and ``trustRequest`` asks the user
///   (the generated config has `StrictHostKeyChecking yes`, so ssh itself would only fail).
/// - Closing a tab ends its process tree (``TerminalSession/close()``); a running session asks
///   first through ``closeConfirmation``. On quit, ``closeAll()`` runs before the agent stops.
/// - A ControlPersist master started by a tab outlives it by design; ``SSHServices`` closes the
///   masters on quit.
/// - Tabs run with `TERM=xterm-ghostty` on hosts that have Ghostty's terminfo entry, else
///   `xterm-256color`; ``installTerminfo(_:)`` adds the entry when the user asks.
/// - Bells, notification requests and long commands of tabs the user is not looking at go to
///   ``notifier``.
@MainActor
@Observable
final class TerminalService {
    /// What a tab runs.
    enum Kind: Hashable, Sendable {
        /// An interactive login shell.
        case shell
        /// `ssh -t <alias> -- <command>`; `command` is already shell-quoted by the caller.
        case remoteCommand(String, title: String?)
    }

    /// App-side information about one tab.
    struct Tab: Hashable, Sendable {
        let hostID: RemoteHost.ID
        let kind: Kind
        /// Host name and, for a remote command, its title: "web-01" or "web-01 · logs web".
        let baseTitle: String
        /// 1 for the first open tab with this title, 2 for the next ...; shown as " (2)".
        let ordinal: Int
        /// The tab's ssh runs as a session on the host's ControlMaster, not on its own connection.
        let sharesConnection: Bool

        var title: String {
            ordinal > 1 ? "\(baseTitle) (\(ordinal))" : baseTitle
        }
    }

    /// First contact with a host: the keys it offered, waiting for Trust or Cancel.
    struct TrustRequest: Identifiable {
        let id = UUID()
        let host: RemoteHost
        let offered: [HostKey]
        let kind: Kind
        /// The tab to replace (Reconnect), if any.
        let replacing: TerminalSession.ID?
    }

    /// Terminal tabs per host that run on its ControlMaster. sshd allows 10 sessions per
    /// connection (`MaxSessions`); the others stay free for metrics and container polls, SFTP,
    /// log follows and agent commands. Later tabs log in on a connection of their own.
    static let sharedTabLimit = 6

    /// The open sessions. Only the order of one host's sessions matters; ``sessions`` groups
    /// them by host.
    let manager = TerminalSessionManager(defaultAppearance: .aero)
    /// Tab info per open session.
    private(set) var tabs: [TerminalSession.ID: Tab] = [:]
    /// The tab shown in the Terminals view.
    var selectedID: TerminalSession.ID?
    /// Shown as the host-key trust sheet while set.
    var trustRequest: TrustRequest?
    /// A running tab the user asked to close; shown as a confirmation while set.
    var closeConfirmation: TerminalSession.ID?
    /// Why the last open could not start (e.g. the host-key scan found a changed key).
    var openError: String?
    /// Opens still checking the host key, per host; the sidebar shows progress for them.
    private(set) var pendingOpens: [RemoteHost.ID: Int] = [:]
    /// Ghostty terminfo per host, from the last check (see ``terminfo(for:)``).
    private var terminfoChecks: [RemoteHost.ID: TerminfoCheck] = [:]
    /// Hosts whose terminfo entry is being installed.
    private(set) var installingTerminfo: Set<RemoteHost.ID> = []
    /// A host the user asked to install the terminfo entry on; shown as a confirmation while set.
    var terminfoConfirmation: RemoteHost.ID?
    /// The outcome of the last install, shown as an alert while set.
    var terminfoInstallResult: TerminfoInstallResult?

    /// Notifications and Dock bounces for tabs the user is not looking at.
    let notifier = TerminalNotifier()

    @ObservationIgnored private let ssh: SSHServices
    @ObservationIgnored private let hostOrder: @MainActor () -> [RemoteHost.ID]
    @ObservationIgnored private let hostLookup: @MainActor (RemoteHost.ID) -> RemoteHost?

    /// - Parameters:
    ///   - hostOrder: The host IDs in the sidebar's order.
    ///   - hostLookup: The host with an ID, if it still exists.
    init(
        ssh: SSHServices,
        hostOrder: @escaping @MainActor () -> [RemoteHost.ID],
        hostLookup: @escaping @MainActor (RemoteHost.ID) -> RemoteHost?
    ) {
        self.ssh = ssh
        self.hostOrder = hostOrder
        self.hostLookup = hostLookup
        manager.closeRequestHandler = { [weak self] session in
            self?.requestClose(session.id)
        }
        manager.alertHandler = { [weak self] session, alert in
            guard let self else { return }
            notifier.handle(alert, from: session, tabTitle: tabs[session.id]?.title ?? session.title)
        }
    }

    /// The open sessions in the sidebar's order: grouped by host in the host list's order, each
    /// host's in ``manager`` order. ⌃Tab, ⌘⌥1…9 and the selection after a close follow it.
    var sessions: [TerminalSession] {
        var rank: [RemoteHost.ID: Int] = [:]
        for (index, id) in hostOrder().enumerated() where rank[id] == nil {
            rank[id] = index
        }
        func hostRank(_ session: TerminalSession) -> Int {
            tabs[session.id].flatMap { rank[$0.hostID] } ?? .max
        }
        return manager.sessions.enumerated()
            .sorted { (hostRank($0.element), $0.offset) < (hostRank($1.element), $1.offset) }
            .map(\.element)
    }

    var selectedSession: TerminalSession? {
        selectedID.flatMap(manager.session(id:)) ?? sessions.first
    }

    /// Whether an open to `hostID` is still checking the host key.
    func isOpening(_ hostID: RemoteHost.ID) -> Bool {
        pendingOpens[hostID, default: 0] > 0
    }

    func tab(for id: TerminalSession.ID) -> Tab? {
        tabs[id]
    }

    /// The open sessions to `hostID`, in tab order.
    func sessions(on hostID: RemoteHost.ID) -> [TerminalSession] {
        manager.sessions.filter { tabs[$0.id]?.hostID == hostID }
    }

    func session(id: TerminalSession.ID) -> TerminalSession? {
        manager.session(id: id)
    }

    /// Whether a terminal can be opened to `host` now: it renders into `ssh_config`, is not
    /// blocked by a changed host key, and something can sign for it (its key and the running
    /// in-app agent, or the system agent). Password hosts need no agent: the tab gets the saved
    /// password through `aeroops-askpass`, or prompts for it.
    func canOpen(_ host: RemoteHost) -> Bool {
        guard ssh.hostKeyBlock(for: host) == nil,
              ssh.configError == nil,
              ssh.configRejections[host.id] == nil
        else { return false }
        if host.auth == .password { return ssh.agentStatus != .stopped }
        switch ssh.agentChoice {
        case .system:
            return ssh.agentStatus == .usingSystemAgent
        case .inApp:
            guard ssh.key(for: host) != nil else { return false }
            if case .running = ssh.agentStatus { return true }
            return false
        }
    }

    /// Why ``canOpen(_:)`` is false, for help tags; `nil` when it is true.
    func unavailableReason(_ host: RemoteHost) -> String? {
        if ssh.hostKeyBlock(for: host) != nil { return "The host key changed. Review it in the host editor first." }
        if let error = ssh.configError { return "ssh_config could not be written: \(error)" }
        if let rejection = ssh.configRejections[host.id] { return rejection }
        if host.auth == .password {
            return ssh.agentStatus == .stopped ? "The SSH services have not started yet." : nil
        }
        switch ssh.agentChoice {
        case .system:
            return ssh.agentStatus == .usingSystemAgent ? nil : "The SSH services have not started yet."
        case .inApp:
            guard ssh.key(for: host) != nil else { return "Choose a key for this host in its settings." }
            switch ssh.agentStatus {
            case .running: return nil
            case .failed(let reason): return "The AeroOps agent is not running: \(reason)"
            case .stopped, .usingSystemAgent: return "The AeroOps agent is not running."
            }
        }
    }

    /// Opens a tab to `host` running `kind`, after the first-contact check. The tab appears and is
    /// selected once the host key is known; until the user trusts a new host, ``trustRequest``
    /// is set instead.
    func open(_ host: RemoteHost, kind: Kind, replacing: TerminalSession.ID? = nil) {
        Task { await openChecked(host, kind: kind, replacing: replacing) }
    }

    /// ``open(_:kind:replacing:)``, returning the session once it is open; `nil` when the host
    /// cannot be opened or waits for the trust sheet.
    @discardableResult
    func openChecked(_ host: RemoteHost, kind: Kind, replacing: TerminalSession.ID? = nil) async -> TerminalSession? {
        guard canOpen(host), trustRequest?.host.id != host.id else { return nil }
        openError = nil
        pendingOpens[host.id, default: 0] += 1
        defer {
            let remaining = pendingOpens[host.id, default: 1] - 1
            pendingOpens[host.id] = remaining > 0 ? remaining : nil
        }
        switch await checkHostKey(host) {
        case .known:
            let term = await terminalType(for: host)
            return launch(host, kind: kind, replacing: replacing, term: term)
        case .unknown(let offered):
            if trustRequest?.host.id != host.id {
                trustRequest = TrustRequest(host: host, offered: offered, kind: kind, replacing: replacing)
            }
            return nil
        case .refused(let message):
            openError = message
            return nil
        }
    }

    /// Pins the offered keys of ``trustRequest`` and opens its tab. Errors stay in the sheet.
    @discardableResult
    func trustAndOpen(_ request: TrustRequest) async throws -> TerminalSession {
        try await ssh.trust(request.offered, for: request.host, replacingPinned: false)
        if trustRequest?.id == request.id {
            trustRequest = nil
        }
        let term = await terminalType(for: request.host)
        return launch(request.host, kind: request.kind, replacing: request.replacing, term: term)
    }

    func cancelTrust() {
        trustRequest = nil
    }

    private enum HostKeyCheck {
        case known
        case unknown([HostKey])
        case refused(String)
    }

    /// A host with pinned keys goes straight to ssh, which enforces the pins. A host without
    /// any is scanned (unauthenticated) so the user can compare fingerprints first. If the scan
    /// fails (host down, DNS), ssh runs anyway and shows the real error in the tab.
    private func checkHostKey(_ host: RemoteHost) async -> HostKeyCheck {
        do {
            guard try await ssh.hostKeys.pinnedKeys(for: host).isEmpty else { return .known }
            switch try await ssh.hostKeys.verify(host) {
            case .unknown(let offered):
                return offered.isEmpty ? .known : .unknown(offered)
            case .changed:
                await ssh.refreshHostKeyBlocks()
                return .refused(SSHServices.changedMessage(host))
            case .trusted:
                return .known
            }
        } catch {
            return .known
        }
    }

    /// Opens the session now. A Reconnect replaces the old tab in place. `term` is the
    /// terminal type, `nil` for ``TerminalLaunchSpec/defaultTerm``.
    @discardableResult
    func launch(_ host: RemoteHost, kind: Kind, replacing: TerminalSession.ID? = nil, term: String? = nil) -> TerminalSession {
        var index: Int?
        var ordinal: Int?
        if let replacing, let old = tabs[replacing] {
            index = manager.sessions.firstIndex { $0.id == replacing }
            ordinal = old.ordinal
            remove(replacing)
        }
        let base = Self.baseTitle(hostName: host.name, kind: kind)
        let tab = Tab(
            hostID: host.id, kind: kind, baseTitle: base, ordinal: ordinal ?? nextOrdinal(for: base),
            sharesConnection: sharedTabs(on: host.id) < Self.sharedTabLimit
        )
        let spec = Self.launchSpec(
            for: host, kind: kind, context: ssh.terminalContext(for: host), title: tab.title,
            sharesConnection: tab.sharesConnection, term: term
        )
        let session = manager.open(spec)
        tabs[session.id] = tab
        if let index, index < manager.sessions.count - 1 {
            manager.move(fromOffsets: IndexSet(integer: manager.sessions.count - 1), toOffset: index)
        }
        selectedID = session.id
        return session
    }

    /// Open tabs to `hostID` whose ssh still runs on the host's ControlMaster.
    private func sharedTabs(on hostID: RemoteHost.ID) -> Int {
        sessions(on: hostID).count { !$0.state.isFinished && tabs[$0.id]?.sharesConnection == true }
    }

    private func nextOrdinal(for baseTitle: String) -> Int {
        let open = manager.sessions.compactMap { tabs[$0.id] }
        let used = Set(open.filter { $0.baseTitle == baseTitle }.map(\.ordinal))
        var ordinal = 1
        while used.contains(ordinal) { ordinal += 1 }
        return ordinal
    }

    static func baseTitle(hostName: String, kind: Kind) -> String {
        switch kind {
        case .shell:
            return hostName
        case .remoteCommand(let command, let title):
            let label = title ?? String(command.prefix(32))
            return "\(hostName) · \(label)"
        }
    }

    /// `/usr/bin/ssh -F <config> aero-<id>`, or for a remote command
    /// `/usr/bin/ssh -F <config> -t aero-<id> -- <command>` with `command` as one argument
    /// (ssh joins its arguments with spaces and the remote shell parses them, so the caller's
    /// `ShellQuote` quoting survives as written). The environment points `SSH_AUTH_SOCK` at the
    /// in-app agent, or at the system agent when that option is on. Without `sharesConnection`
    /// the tab gets its own connection (`-o ControlPath=none`). `term` sets `TERM`, which ssh
    /// passes to the remote side.
    static func launchSpec(
        for host: RemoteHost, kind: Kind, context: SSHContext, title: String, sharesConnection: Bool = true,
        term: String? = nil
    ) -> TerminalLaunchSpec {
        let command = context.terminalCommand(for: host, sharesConnection: sharesConnection)
        var arguments = command.arguments
        if case .remoteCommand(let remoteCommand, _) = kind {
            if let aliasIndex = arguments.lastIndex(of: host.sshAlias) {
                arguments.insert("-t", at: aliasIndex)
            } else {
                arguments += ["-t", host.sshAlias]
            }
            arguments += ["--", remoteCommand]
        }
        var environment = command.environment
        if environment["SSH_AUTH_SOCK"] == nil, context.agent == .system,
           let systemSocket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !systemSocket.isEmpty {
            environment["SSH_AUTH_SOCK"] = systemSocket
        }
        if let term {
            environment["TERM"] = term
        }
        return TerminalLaunchSpec(
            executable: command.executable.path(percentEncoded: false),
            arguments: arguments,
            environment: environment,
            title: title
        )
    }

    /// The outcome of ``installTerminfo(_:)``.
    struct TerminfoInstallResult: Identifiable {
        let id = UUID()
        let hostName: String
        /// `nil` when the entry was installed.
        let failure: String?
    }

    /// One host's check, valid while its address, port and user stay the same.
    private struct TerminfoCheck {
        let endpoint: String
        let support: TerminfoSupport
    }

    private static func endpoint(_ host: RemoteHost) -> String {
        "\(host.user)@\(host.address):\(host.port)"
    }

    /// What the last check found on `host`; `nil` before a check.
    func terminfo(for host: RemoteHost) -> TerminfoSupport? {
        guard let check = terminfoChecks[host.id], check.endpoint == Self.endpoint(host) else { return nil }
        return check.support
    }

    /// `xterm-ghostty` when the host has Ghostty's terminfo entry, else `nil` (the default
    /// `xterm-256color`). A host is checked once, and only over a ControlMaster that is already
    /// up: the check must never add a login, since failed logins count towards a ban. Until
    /// then (typically the first tab to a host that is not monitored) tabs use the default.
    private func terminalType(for host: RemoteHost) async -> String? {
        if terminfo(for: host) == nil {
            await checkTerminfo(host)
        }
        return terminfo(for: host)?.hasGhosttyEntry == true ? TerminalLaunchSpec.ghosttyTerm : nil
    }

    private func checkTerminfo(_ host: RemoteHost) async {
        guard case .running? = try? await ControlMaster(context: ssh.context).check(host),
              let support = try? await TerminfoCommands(runner: ssh.runner).check(host) else { return }
        terminfoChecks[host.id] = TerminfoCheck(endpoint: Self.endpoint(host), support: support)
    }

    /// Whether to offer ``installTerminfo(_:)`` for `host`: not while it runs or once the host
    /// is known to have the entry.
    func canInstallTerminfo(_ host: RemoteHost) -> Bool {
        !installingTerminfo.contains(host.id) && terminfo(for: host)?.hasGhosttyEntry != true
    }

    /// Asks before ``installTerminfo(_:)`` (``terminfoConfirmation``).
    func requestTerminfoInstall(_ hostID: RemoteHost.ID) {
        guard let host = hostLookup(hostID), canInstallTerminfo(host) else { return }
        terminfoConfirmation = hostID
    }

    /// Compiles Ghostty's terminfo entry into the login user's `~/.terminfo` on `host`, so new
    /// tabs to it use `TERM=xterm-ghostty`. Open tabs keep the terminal type they started with.
    /// The outcome lands in ``terminfoInstallResult``.
    func installTerminfo(_ hostID: RemoteHost.ID) {
        guard let host = hostLookup(hostID), canInstallTerminfo(host) else { return }
        installingTerminfo.insert(host.id)
        let commands = TerminfoCommands(runner: ssh.runner)
        Task {
            var failure: String?
            do {
                let support = try await commands.install(host)
                terminfoChecks[host.id] = TerminfoCheck(endpoint: Self.endpoint(host), support: support)
                if !support.hasGhosttyEntry {
                    failure = "tic finished, but the host still does not find xterm-ghostty. Its curses may not read ~/.terminfo."
                }
            } catch SSHError.remoteCommandFailed(exitCode: 3, _) {
                failure = "The host has no tic. Install ncurses (the package is often ncurses-bin or ncurses), then try again."
            } catch {
                failure = SSHServices.describe(error, host: host).message
            }
            installingTerminfo.remove(host.id)
            terminfoInstallResult = TerminfoInstallResult(hostName: host.name, failure: failure)
        }
    }

    /// Closes the tab, asking first (``closeConfirmation``) while its program runs, unless
    /// `force`.
    func requestClose(_ id: TerminalSession.ID, force: Bool = false) {
        guard let session = manager.session(id: id) else { return }
        if !force, session.state == .running {
            closeConfirmation = id
            return
        }
        close(id)
    }

    /// Closes the tab now, ending its ssh process.
    func close(_ id: TerminalSession.ID) {
        if closeConfirmation == id { closeConfirmation = nil }
        let neighbour = neighbour(of: id)
        remove(id)
        if selectedID == id || selectedID == nil {
            selectedID = neighbour
        }
    }

    private func remove(_ id: TerminalSession.ID) {
        manager.close(id)
        tabs[id] = nil
        notifier.forget(id)
    }

    /// The tab to select after `id` closes: the next one, else the previous one.
    private func neighbour(of id: TerminalSession.ID) -> TerminalSession.ID? {
        let sessions = self.sessions
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return selectedID }
        if index + 1 < sessions.count { return sessions[index + 1].id }
        if index > 0 { return sessions[index - 1].id }
        return nil
    }

    /// Closes every tab and waits (bounded) for their processes. Runs first on quit, before
    /// the agent stops and the masters close.
    func closeAll() {
        trustRequest = nil
        closeConfirmation = nil
        manager.closeAll()
        tabs = [:]
        selectedID = nil
    }

    /// Opens a fresh session for an ended tab's host and command, in the same place.
    func reconnect(_ id: TerminalSession.ID) {
        guard canReconnect(id), let tab = tabs[id], let host = hostLookup(tab.hostID) else { return }
        open(host, kind: tab.kind, replacing: id)
    }

    /// Whether the tab has ended and its host can be opened again.
    func canReconnect(_ id: TerminalSession.ID) -> Bool {
        guard let session = manager.session(id: id), session.state.isFinished,
              let tab = tabs[id], let host = hostLookup(tab.hostID) else { return false }
        return canOpen(host)
    }

    /// Selects the next (`offset` 1) or previous (-1) tab, wrapping around.
    func cycle(by offset: Int) {
        let sessions = self.sessions
        guard !sessions.isEmpty else { return }
        let current = selectedSession.flatMap { session in sessions.firstIndex { $0.id == session.id } } ?? 0
        let next = ((current + offset) % sessions.count + sessions.count) % sessions.count
        selectedID = sessions[next].id
    }

    /// Selects the tab at `index` (0-based); the last tab for an index past the end, like ⌘9 in
    /// browsers.
    func select(index: Int) {
        let sessions = self.sessions
        guard !sessions.isEmpty else { return }
        selectedID = sessions[min(index, sessions.count - 1)].id
    }

    /// Whether the tab can move up (-1) or down (1) among its host's tabs.
    func canMove(_ id: TerminalSession.ID, by offset: Int) -> Bool {
        moveTarget(of: id, by: offset) != nil
    }

    /// Moves the tab one place up (-1) or down (1) among its host's tabs.
    func move(_ id: TerminalSession.ID, by offset: Int) {
        let sessions = manager.sessions
        guard let target = moveTarget(of: id, by: offset),
              let from = sessions.firstIndex(where: { $0.id == id }),
              let to = sessions.firstIndex(where: { $0.id == target }) else { return }
        manager.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// The tab on the same host that `id` swaps places with.
    private func moveTarget(of id: TerminalSession.ID, by offset: Int) -> TerminalSession.ID? {
        guard let hostID = tabs[id]?.hostID else { return nil }
        let siblings = sessions(on: hostID)
        guard let index = siblings.firstIndex(where: { $0.id == id }),
              siblings.indices.contains(index + offset) else { return nil }
        return siblings[index + offset].id
    }

    /// What the tab's status orb and exit banner say.
    struct Status: Equatable {
        enum Tone { case connecting, running, ended, failed }
        let tone: Tone
        let text: String
        let hint: String?
    }

    static func status(of state: TerminalSession.State) -> Status {
        switch state {
        case .starting:
            return Status(tone: .connecting, text: "Connecting…", hint: nil)
        case .running:
            return Status(tone: .running, text: "Running", hint: nil)
        case .exited(let code?) where code == 255:
            return Status(
                tone: .failed, text: "ssh failed (exit 255)",
                hint: "ssh could not connect or log in. Check that the host is reachable and the key is in authorized_keys. AeroOps does not retry: repeated failed logins can get this Mac briefly banned by the server."
            )
        case .exited(let code?) where code == 0:
            return Status(tone: .ended, text: "Session ended", hint: nil)
        case .exited(let code?) where code > 128:
            return Status(tone: .failed, text: "Ended by signal \(code - 128) (exit \(code))", hint: nil)
        case .exited(let code?):
            return Status(tone: .failed, text: "Exited with code \(code)", hint: nil)
        case .exited(nil):
            return Status(tone: .ended, text: "Session ended", hint: nil)
        case .failed(let message):
            return Status(tone: .failed, text: "Couldn’t start the terminal", hint: message)
        }
    }
}
