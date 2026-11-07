import AeroCore
import Foundation
import Observation
import SSHKit
import UIKit

/// The Files screen of one host: its remote folder (the shared ``FilePaneModel``), the
/// transfer queue, and the downloaded copies waiting to be shared.
///
/// Downloads land in the app's temporary folder (`tmp/Files/<host>/<transfer>/`) and go to the
/// share sheet, which also saves to Files. Uploads come from the document picker as
/// security-scoped URLs: each transfer first copies them into its own staging folder
/// (downloading iCloud items on the way), uploads the copies and removes them.
@MainActor
@Observable
final class MobileFileBrowser<Backend: FileTransferBackend> {
    /// Top-level items that already exist in the folder an upload goes to.
    struct Conflict: Identifiable {
        let id = UUID()
        let names: [String]
        let destination: String
        /// Called with whether to leave the existing items alone (else they are replaced).
        let resolve: @MainActor (_ skipExisting: Bool) -> Void
    }

    let hostID: RemoteHost.ID
    private(set) var hostName: String
    let pane: FilePaneModel<Backend>
    let queue = FileTransferQueue()
    var conflict: Conflict?
    /// The downloaded items of each finished download, for the share sheet.
    private(set) var downloads: [FileTransfer.ID: [URL]] = [:]

    @ObservationIgnored private let scratch: URL
    /// Each download's folder under ``scratch``.
    @ObservationIgnored private var folders: [FileTransfer.ID: URL] = [:]

    init(host: RemoteHost, backend: Backend) {
        hostID = host.id
        hostName = host.name
        pane = FilePaneModel(backend: backend)
        scratch = Self.downloadsRoot.appending(path: host.id.uuidString, directoryHint: .isDirectory)
    }

    private static var downloadsRoot: URL {
        URL.temporaryDirectory.appending(path: "Files", directoryHint: .isDirectory)
    }

    /// Deletes every host's downloads (left from the last run).
    static func removeAllDownloads() {
        try? FileManager.default.removeItem(at: downloadsRoot)
    }

    /// Cancels the transfers, disconnects and deletes the downloads (the host was removed).
    func close() {
        queue.cancelAll()
        pane.backend.disconnect()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Copies remote items of `directory` (the folder shown unless given) to this device, then
    /// offers them in ``downloads``.
    func download(_ items: [FileItem], in directory: Backend.Path? = nil) {
        guard let directory = directory ?? pane.directory, !items.isEmpty else { return }
        let sources = items.map { pane.backend.path(directory, appending: $0.rawName) }
        let folder = scratch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let backend = pane.backend
        let transfer = FileTransfer(
            direction: .download, hostID: hostID,
            title: FileTransfer.title(for: items.map(\.name)), destination: "this \(UIDevice.current.model)"
        ) { transfer, progress in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await backend.download(sources, into: folder.path(percentEncoded: false), for: transfer, progress: progress)
        } completion: { [weak self] in
            self?.downloadDidEnd(into: folder)
        }
        folders[transfer.id] = folder
        queue.add(transfer)
    }

    private func downloadDidEnd(into folder: URL) {
        guard let (id, _) = folders.first(where: { $0.value == folder }),
              queue.transfers.first(where: { $0.id == id })?.phase == .finished else { return }
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        downloads[id] = items.isEmpty ? nil : items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Uploads picked files into `directory` (the folder shown unless given), asking first if
    /// any already exist in the folder shown.
    func upload(_ urls: [URL], into directory: Backend.Path? = nil) {
        guard let directory = directory ?? pane.directory, !urls.isEmpty else { return }
        let present = directory == pane.directory ? Set(pane.items.map(\.name)) : []
        let existing = urls.map(\.lastPathComponent).filter { present.contains($0) }
        guard !existing.isEmpty else { return enqueueUpload(urls, into: directory) }
        conflict = Conflict(names: existing, destination: pane.backend.displayString(directory)) { [weak self] skipExisting in
            let remaining = skipExisting ? urls.filter { !existing.contains($0.lastPathComponent) } : urls
            self?.enqueueUpload(remaining, into: directory)
        }
    }

    private func enqueueUpload(_ urls: [URL], into directory: Backend.Path) {
        guard !urls.isEmpty else { return }
        let staging = scratch.appending(path: "upload-\(UUID().uuidString)", directoryHint: .isDirectory)
        let backend = pane.backend
        let transfer = FileTransfer(
            direction: .upload, hostID: hostID,
            title: FileTransfer.title(for: urls.map(\.lastPathComponent)), destination: "\(hostName):\(backend.displayString(directory))"
        ) { transfer, progress in
            defer { try? FileManager.default.removeItem(at: staging) }
            let copies = try await Self.stage(urls, in: staging)
            try await backend.upload(copies, into: directory, for: transfer, progress: progress)
        } completion: { [weak self] in
            guard let self, pane.directory == directory else { return }
            pane.refresh()
        }
        queue.add(transfer)
    }

    /// Copies picked items into `staging` off the main actor, coordinated so an iCloud item is
    /// downloaded first. Returns the copies' paths.
    @concurrent
    nonisolated private static func stage(_ urls: [URL], in staging: URL) async throws -> [String] {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var copies: [String] = []
        for url in urls {
            try Task.checkCancellation()
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
            let copy = staging.appending(path: url.lastPathComponent)
            var coordinationError: NSError?
            var copyError: (any Error)?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                do {
                    try FileManager.default.copyItem(at: readable, to: copy)
                } catch {
                    copyError = error
                }
            }
            if let error = coordinationError ?? copyError {
                throw SFTPError.local(path: url.lastPathComponent, message: error.localizedDescription)
            }
            copies.append(copy.path(percentEncoded: false))
        }
        return copies
    }

    /// Removes an ended transfer and its downloaded copies.
    func remove(_ transfer: FileTransfer) {
        guard transfer.phase.isOver else { return }
        queue.remove(transfer)
        forgetDownload(transfer.id)
    }

    func clearFinished() {
        let ended = queue.transfers.filter { $0.phase.isOver }.map(\.id)
        queue.clearFinished()
        for id in ended { forgetDownload(id) }
    }

    private func forgetDownload(_ id: FileTransfer.ID) {
        downloads[id] = nil
        if let folder = folders.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

extension MobileFileBrowser where Backend == RemoteFileBackend {
    /// Takes the edited host; a new address or user starts over from its home folder.
    func hostDidChange(_ host: RemoteHost) {
        hostName = host.name
        let session = pane.backend.session
        let moved = host.address != session.host.address || host.port != session.host.port
            || host.user != session.host.user
        session.update(host)
        if moved { pane.reset() }
    }
}
