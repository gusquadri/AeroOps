import AeroCore
import Foundation
import Observation
import SSHKit

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
    let queue = FileTransferQueue(concurrentTransfers: FileService.concurrentTransfers)
    var trustRequest: TrustRequest?
    var conflict: Conflict?

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var remotes: [RemoteHost.ID: FilePaneModel<RemoteFileBackend>] = [:]

    init(model: AppModel) {
        ssh = model.ssh
        appModel = model
    }

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
                for transfer in queue.transfers where transfer.hostID == id { queue.cancel(transfer) }
            }
        }
    }

    /// Cancels every transfer and closes every SFTP session (at quit).
    func closeAll() {
        queue.cancelAll()
        for pane in remotes.values { pane.backend.session.disconnect() }
        trustRequest = nil
        conflict = nil
    }

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
        let backend = remotePane(for: host).backend
        let transfer = FileTransfer(
            direction: .download, hostID: host.id,
            title: FileTransfer.title(for: sources.map(\.name)), destination: (directory as NSString).abbreviatingWithTildeInPath
        ) { transfer, progress in
            try await backend.download(sources, into: directory, for: transfer, progress: progress)
        } completion: { [weak self] in
            guard let self, local.directory == directory else { return }
            local.refresh()
        }
        queue.add(transfer)
    }

    private func enqueueUpload(_ sources: [String], to host: RemoteHost, into directory: SFTPPath) {
        guard !sources.isEmpty else { return }
        let pane = remotePane(for: host)
        let backend = pane.backend
        let transfer = FileTransfer(
            direction: .upload, hostID: host.id,
            title: FileTransfer.title(for: sources.map { ($0 as NSString).lastPathComponent }), destination: "\(host.name):\(directory.string)"
        ) { transfer, progress in
            try await backend.upload(sources, into: directory, for: transfer, progress: progress)
        } completion: { [weak pane] in
            guard let pane, pane.directory == directory else { return }
            pane.refresh()
        }
        queue.add(transfer)
    }

    var transfers: [FileTransfer] { queue.transfers }

    func cancel(_ transfer: FileTransfer) {
        queue.cancel(transfer)
    }

    func remove(_ transfer: FileTransfer) {
        queue.remove(transfer)
    }

    func clearFinished() {
        queue.clearFinished()
    }
}
