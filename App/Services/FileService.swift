import AeroCore
import Foundation
import Observation
import SSHKit
import Synchronization

/// The Files tab's services: the local pane, one ``RemoteFileSession`` and remote pane per host,
/// and the transfer queue.
///
/// SFTP runs over SSHKit like everything else: `ssh -s … sftp` through `~/.aeroops/ssh_config`
/// and the in-app agent, so it multiplexes over the host's ControlMaster connection. A host
/// with no pinned key gets the same first-contact trust sheet as a terminal tab. Get it with
/// ``AppModel/fileService``.
@MainActor
@Observable
final class FileService: HostInventoryObserver {
    struct TrustRequest: Identifiable {
        let id = UUID()
        let host: RemoteHost
        let offered: [HostKey]
    }

    /// Top-level items that already exist where a transfer would put them.
    struct Conflict: Identifiable {
        enum Resolution {
            /// Replace files; copy into existing folders (files with the same name are replaced).
            case replace
            /// Leave the existing items alone and copy the rest.
            case skip
        }

        let id = UUID()
        let names: [String]
        let destination: String
        let resolve: @MainActor (Resolution) -> Void
    }

    /// Transfers running at once; the rest wait.
    static let concurrentTransfers = 2

    let ssh: SSHServices
    let local = FilePaneModel(backend: LocalFileBackend())
    private(set) var transfers: [FileTransfer] = []
    var trustRequest: TrustRequest?
    var conflict: Conflict?

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var remotes: [RemoteHost.ID: FilePaneModel<RemoteFileBackend>] = [:]

    init(model: AppModel) {
        ssh = model.ssh
        appModel = model
    }

    // MARK: - Hosts

    /// The host's pane (and SFTP session), created on first use. Nothing connects until the
    /// pane lists its first folder.
    func remotePane(for host: RemoteHost) -> FilePaneModel<RemoteFileBackend> {
        if let existing = remotes[host.id] { return existing }
        let session = RemoteFileSession(host: host) { [weak self] host in
            guard let self else { throw CancellationError() }
            return try await self.connect(host)
        }
        let pane = FilePaneModel(backend: RemoteFileBackend(session: session))
        remotes[host.id] = pane
        return pane
    }

    /// Whether the host can be browsed: the same conditions as a terminal tab.
    func canBrowse(_ host: RemoteHost) -> Bool {
        appModel?.terminals.canOpen(host) ?? false
    }

    func unavailableReason(_ host: RemoteHost) -> String? {
        appModel?.terminals.unavailableReason(host)
    }

    /// Drops deleted hosts (closing their sessions and transfers) and reconnects hosts whose
    /// address, user or login changed.
    func hostsDidChange(_ hosts: [RemoteHost]) {
        let byID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, pane) in remotes {
            if let host = byID[id] {
                let session = pane.backend.session
                let moved = host.address != session.host.address || host.port != session.host.port
                    || host.user != session.host.user
                session.update(host)
                if moved { pane.reset() }
            } else {
                pane.backend.session.disconnect()
                remotes[id] = nil
                for transfer in transfers where transfer.hostID == id { cancel(transfer) }
            }
        }
    }

    /// Cancels every transfer and closes every SFTP session (at quit).
    func closeAll() {
        for transfer in transfers { cancel(transfer) }
        for pane in remotes.values { pane.backend.session.disconnect() }
        trustRequest = nil
        conflict = nil
    }

    // MARK: - Connecting

    private func connect(_ host: RemoteHost) async throws -> SFTPClient {
        if let reason = unavailableReason(host) { throw FileBrowserError.unavailable(reason) }
        switch await checkHostKey(host) {
        case .known:
            break
        case .unknown(let offered):
            if trustRequest?.host.id != host.id {
                trustRequest = TrustRequest(host: host, offered: offered)
            }
            throw FileBrowserError.untrustedHost
        case .refused(let message):
            throw FileBrowserError.refused(message)
        }
        return try await SFTPClient.connect(using: ssh.runner, to: host)
    }

    /// Pins the offered keys and lists the host's pane again.
    func trust(_ request: TrustRequest) async throws {
        try await ssh.trust(request.offered, for: request.host, replacingPinned: false)
        if trustRequest?.id == request.id {
            trustRequest = nil
        }
        remotes[request.host.id]?.refresh()
    }

    func cancelTrust() {
        trustRequest = nil
    }

    private enum HostKeyCheck {
        case known
        case unknown([HostKey])
        case refused(String)
    }

    /// As for terminal tabs (``TerminalService``): pinned keys go straight to ssh, which
    /// enforces them; a host without any is scanned so the user can compare fingerprints first.
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

    // MARK: - Transfers

    /// Downloads remote items into a local folder, asking first if any already exist there.
    func download(_ sources: [SFTPPath], from host: RemoteHost, into directory: String) {
        guard !sources.isEmpty else { return }
        let existing = sources.filter { source in
            var info = stat()
            return lstat(LocalFileBackend.appending(directory, source.name), &info) == 0
        }
        resolveConflicts(existing.map(\.name), in: directory) { [weak self] skip in
            let remaining = sources.filter { !skip.contains($0.name) }
            self?.enqueueDownload(remaining, from: host, into: directory)
        }
    }

    /// Uploads local items into a remote folder, asking first if any already exist there.
    func upload(_ sources: [String], to host: RemoteHost, into directory: SFTPPath) async {
        guard !sources.isEmpty else { return }
        let session = remotePane(for: host).backend.session
        let names = sources.map { ($0 as NSString).lastPathComponent }
        var existing: [String] = []
        if let listing = try? await session.client().list(directory) {
            let present = Set(listing.map(\.name))
            existing = names.filter { present.contains(Data($0.utf8)) }
        }
        resolveConflicts(existing, in: directory.string) { [weak self] skip in
            let remaining = sources.filter { !skip.contains(($0 as NSString).lastPathComponent) }
            self?.enqueueUpload(remaining, to: host, into: directory)
        }
    }

    /// Runs `enqueue` with the names to skip: none without conflicts, else after the user chose.
    private func resolveConflicts(_ existing: [String], in destination: String, enqueue: @escaping @MainActor (Set<String>) -> Void) {
        guard !existing.isEmpty else { return enqueue([]) }
        conflict = Conflict(names: existing, destination: destination) { resolution in
            enqueue(resolution == .skip ? Set(existing) : [])
        }
    }

    private func enqueueDownload(_ sources: [SFTPPath], from host: RemoteHost, into directory: String) {
        guard !sources.isEmpty else { return }
        let session = remotePane(for: host).backend.session
        let transfer = FileTransfer(
            direction: .download, hostID: host.id,
            title: Self.title(sources.map(\.name)), destination: (directory as NSString).abbreviatingWithTildeInPath
        ) { transfer, progress in
            let client = try await session.client(.transfer)
            let plan = try await client.planDownload(sources, into: directory)
            transfer.begin(totalBytes: plan.totalBytes, files: plan.files.count, skipped: plan.skipped.map { "\($0.path): \($0.reason)" })
            transfer.failures = try await client.download(plan) { progress.record($0) }
        } completion: { [weak self] in
            guard let self, local.directory == directory else { return }
            local.refresh()
        }
        add(transfer)
    }

    private func enqueueUpload(_ sources: [String], to host: RemoteHost, into directory: SFTPPath) {
        guard !sources.isEmpty else { return }
        let pane = remotePane(for: host)
        let session = pane.backend.session
        let transfer = FileTransfer(
            direction: .upload, hostID: host.id,
            title: Self.title(sources.map { ($0 as NSString).lastPathComponent }), destination: "\(host.name):\(directory.string)"
        ) { transfer, progress in
            let client = try await session.client(.transfer)
            let plan = try await client.planUpload(sources, into: directory)
            transfer.begin(totalBytes: plan.totalBytes, files: plan.files.count, skipped: plan.skipped.map { "\($0.path): \($0.reason)" })
            transfer.failures = try await client.upload(plan) { progress.record($0) }
        } completion: { [weak pane] in
            guard let pane, pane.directory == directory else { return }
            pane.refresh()
        }
        add(transfer)
    }

    private func add(_ transfer: FileTransfer) {
        transfers.append(transfer)
        schedule()
    }

    /// Starts waiting transfers while fewer than ``concurrentTransfers`` run.
    private func schedule() {
        var running = transfers.count { $0.phase.isActive }
        for transfer in transfers where transfer.phase == .waiting && running < Self.concurrentTransfers {
            start(transfer)
            running += 1
        }
    }

    private func start(_ transfer: FileTransfer) {
        transfer.phase = .preparing
        transfer.started = .now
        let progress = TransferProgress()
        transfer.task = Task { [weak self] in
            let ticker = Task {
                while !Task.isCancelled {
                    transfer.update(progress)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            do {
                try await transfer.run(transfer, progress)
                transfer.phase = .finished
            } catch {
                transfer.phase = Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed(error.localizedDescription)
            }
            ticker.cancel()
            transfer.update(progress)
            transfer.ended = .now
            transfer.completion()
            self?.schedule()
        }
    }

    func cancel(_ transfer: FileTransfer) {
        switch transfer.phase {
        case .waiting:
            transfer.phase = .cancelled
            transfer.ended = .now
        case .preparing, .copying:
            transfer.task?.cancel()
        case .finished, .failed, .cancelled:
            break
        }
    }

    func remove(_ transfer: FileTransfer) {
        guard !transfer.phase.isActive else { return }
        transfers.removeAll { $0.id == transfer.id }
    }

    func clearFinished() {
        transfers.removeAll { $0.phase.isOver }
    }

    /// "report.pdf", or "report.pdf and 2 more".
    private static func title(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
    }
}

// MARK: - Session

/// A host's SFTP sessions: one for browsing and one for transfers, so a big copy never queues
/// in front of a folder listing. Both connect on first use and reconnect after the connection
/// drops; with ControlMaster, the second rides on the first's connection.
@MainActor
@Observable
final class RemoteFileSession {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed
    }

    enum Role {
        case browse
        case transfer
    }

    private(set) var host: RemoteHost
    /// The browsing session's state, for the pane header.
    private(set) var status: Status = .idle

    @ObservationIgnored private let connector: @MainActor (RemoteHost) async throws -> SFTPClient
    @ObservationIgnored private var clients: [Role: SFTPClient] = [:]
    @ObservationIgnored private var pending: [Role: Task<SFTPClient, any Error>] = [:]
    /// Bumped by ``disconnect()``, so a connection finishing afterwards is dropped.
    @ObservationIgnored private var generation = 0

    init(host: RemoteHost, connector: @escaping @MainActor (RemoteHost) async throws -> SFTPClient) {
        self.host = host
        self.connector = connector
    }

    /// The session for `role`, connecting (or reconnecting) if needed.
    func client(_ role: Role = .browse) async throws -> SFTPClient {
        if let client = clients[role] {
            if await client.isConnected { return client }
            if clients[role] === client { clients[role] = nil }
        }
        if let task = pending[role] {
            return try await task.value
        }
        let token = generation
        let task = Task { [host, connector] in try await connector(host) }
        pending[role] = task
        if role == .browse { status = .connecting }
        do {
            let client = try await task.value
            guard token == generation else {
                client.disconnect()
                throw CancellationError()
            }
            pending[role] = nil
            clients[role] = client
            if role == .browse { status = .connected }
            return client
        } catch {
            if token == generation {
                pending[role] = nil
                if role == .browse { status = .failed }
            }
            throw error
        }
    }

    /// Takes the edited host; a new address, user or login closes the sessions so the next
    /// request connects with it.
    func update(_ host: RemoteHost) {
        let old = self.host
        self.host = host
        if host.address != old.address || host.port != old.port || host.user != old.user
            || host.keyId != old.keyId || host.auth != old.auth {
            disconnect()
        }
    }

    /// Ends both sessions; running requests and transfers fail.
    func disconnect() {
        generation += 1
        for client in clients.values { client.disconnect() }
        for task in pending.values { task.cancel() }
        clients = [:]
        pending = [:]
        status = .idle
    }
}

// MARK: - Transfer

/// One queued upload or download of one or more items (folders included).
@MainActor
@Observable
final class FileTransfer: Identifiable {
    enum Direction {
        case upload
        case download
    }

    enum Phase: Equatable {
        case waiting
        /// Connecting and walking the folders.
        case preparing
        case copying
        /// Done; some items may have failed (``FileTransfer/failures``).
        case finished
        case failed(String)
        case cancelled

        var isActive: Bool { self == .preparing || self == .copying }
        var isOver: Bool { !isActive && self != .waiting }
    }

    typealias Run = @MainActor (FileTransfer, TransferProgress) async throws -> Void

    let id = UUID()
    let direction: Direction
    let hostID: RemoteHost.ID
    let title: String
    let destination: String
    var phase: Phase = .waiting
    private(set) var totalBytes: Int64 = 0
    private(set) var copiedBytes: Int64 = 0
    private(set) var fileCount = 0
    private(set) var currentFile: String?
    var failures: [SFTPTransferFailure] = []
    /// Items left out (special files, links to folders inside folders), with the reason.
    private(set) var skipped: [String] = []
    var started: Date?
    var ended: Date?

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored let run: Run
    @ObservationIgnored let completion: @MainActor () -> Void

    init(
        direction: Direction,
        hostID: RemoteHost.ID,
        title: String,
        destination: String,
        run: @escaping Run,
        completion: @escaping @MainActor () -> Void
    ) {
        self.direction = direction
        self.hostID = hostID
        self.title = title
        self.destination = destination
        self.run = run
        self.completion = completion
    }

    /// Fraction copied, once the size is known.
    var fraction: Double? {
        guard phase == .copying || phase == .finished, totalBytes > 0 else { return nil }
        return min(1, Double(copiedBytes) / Double(totalBytes))
    }

    /// Bytes per second since the copy started.
    var speed: Double? {
        guard let started, copiedBytes > 0 else { return nil }
        let elapsed = (ended ?? .now).timeIntervalSince(started)
        return elapsed > 0.5 ? Double(copiedBytes) / elapsed : nil
    }

    func begin(totalBytes: Int64, files: Int, skipped: [String]) {
        self.totalBytes = totalBytes
        fileCount = files
        self.skipped = skipped
        // Speed counts from here, not from connecting and walking folders.
        started = .now
        phase = .copying
    }

    func update(_ progress: TransferProgress) {
        let snapshot = progress.snapshot
        if copiedBytes != snapshot.bytes { copiedBytes = snapshot.bytes }
        if currentFile != snapshot.file { currentFile = snapshot.file }
    }
}

/// Progress reported by SSHKit from its own tasks, read by the UI a few times a second.
final class TransferProgress: Sendable {
    private let state = Mutex<(bytes: Int64, file: String?)>((0, nil))

    func record(_ event: SFTPTransferEvent) {
        state.withLock { state in
            switch event {
            case .file(let path): state.file = path
            case .bytes(let count): state.bytes += count
            }
        }
    }

    var snapshot: (bytes: Int64, file: String?) {
        state.withLock { $0 }
    }
}
