import AeroCore
import Foundation
import Observation
import SSHKit

/// Why a pane could not do what was asked.
enum FileBrowserError: LocalizedError, Equatable {
    /// The host can't be reached right now (no key, agent stopped, blocked).
    case unavailable(String)
    /// The host key was never trusted; the trust sheet is up.
    case untrustedHost
    /// The host key check refused the host.
    case refused(String)
    case notAFolder(String)
    case exists(String)
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .refused(let reason): reason
        case .untrustedHost: "Trust the host key to browse this host's files."
        case .notAFolder(let path): "“\(path)” is not a folder."
        case .exists(let name): "An item named “\(name)” already exists here."
        case .invalidName(let name): "“\(name)” can’t be used as a name."
        }
    }
}

// MARK: - Backends

/// Where a pane's files live: the Mac's own disk (`LocalFileBackend`) or a host over SFTP
/// (``RemoteFileBackend``).
@MainActor
protocol FileBackend: AnyObject {
    associatedtype Path: Hashable & Sendable

    /// Whether Delete moves to the Trash (so it needs no confirmation).
    var deletesToTrash: Bool { get }

    func home() async throws -> Path
    func list(_ directory: Path) async throws -> [FileItem]
    func path(_ directory: Path, appending name: Data) -> Path
    func parent(of path: Path) -> Path?
    func displayString(_ path: Path) -> String
    /// A typed location: absolute, `~`-relative or relative to `directory`; must be a folder.
    func resolve(_ text: String, from directory: Path?) async throws -> Path
    /// Whether `path` is a folder, following a symbolic link.
    func isFolder(_ path: Path) async throws -> Bool
    func createFolder(_ path: Path) async throws
    /// Renames without replacing an existing item.
    func rename(_ source: Path, to destination: Path) async throws
    func delete(_ paths: [Path]) async throws
}

/// A backend that copies items to and from this device's own files, for ``FileTransferQueue``.
@MainActor
protocol FileTransferBackend: FileBackend {
    /// Copies `sources` (folders included) into the local folder `directory`, replacing items
    /// with the same names, and reports through `transfer` and `progress`.
    func download(_ sources: [Path], into directory: String, for transfer: FileTransfer, progress: TransferProgress) async throws
    /// Copies the local items `sources` into `directory`, replacing items with the same names.
    func upload(_ sources: [String], into directory: Path, for transfer: FileTransfer, progress: TransferProgress) async throws
    /// Ends the backend's connections; the next request connects again.
    func disconnect()
}

/// A host's files through its ``RemoteFileSession``.
final class RemoteFileBackend: FileTransferBackend {
    let session: RemoteFileSession
    let deletesToTrash = false

    init(session: RemoteFileSession) {
        self.session = session
    }

    func home() async throws -> SFTPPath {
        try await session.client().homeDirectory()
    }

    func list(_ directory: SFTPPath) async throws -> [FileItem] {
        try await session.client().list(directory).map(FileItem.init)
    }

    func path(_ directory: SFTPPath, appending name: Data) -> SFTPPath {
        directory.appending(component: name)
    }

    func parent(of path: SFTPPath) -> SFTPPath? {
        path.parent
    }

    func displayString(_ path: SFTPPath) -> String {
        path.string
    }

    func resolve(_ text: String, from directory: SFTPPath?) async throws -> SFTPPath {
        let client = try await session.client()
        let target: SFTPPath
        if text == "~" {
            target = try await client.homeDirectory()
        } else if text.hasPrefix("~/") {
            let home = try await client.homeDirectory()
            target = SFTPPath(bytes: home.bytes + Data(text.utf8.dropFirst()))
        } else if text.hasPrefix("/") {
            target = SFTPPath(text)
        } else {
            // Bytes, so a folder whose name is not UTF-8 keeps its exact name.
            let base: SFTPPath
            if let directory {
                base = directory
            } else {
                base = try await client.homeDirectory()
            }
            target = SFTPPath(bytes: base.bytes + Data(("/" + text).utf8))
        }
        let resolved = try await client.realPath(target)
        guard try await isFolder(resolved) else { throw FileBrowserError.notAFolder(text) }
        return resolved
    }

    func isFolder(_ path: SFTPPath) async throws -> Bool {
        try await session.client().attributes(of: path).kind == .directory
    }

    func createFolder(_ path: SFTPPath) async throws {
        try await session.client().createDirectory(path)
    }

    func rename(_ source: SFTPPath, to destination: SFTPPath) async throws {
        let client = try await session.client()
        // posix-rename replaces silently; a Finder-style rename must not.
        if (try? await client.attributes(of: destination, followingSymlinks: false)) != nil {
            throw FileBrowserError.exists(destination.name)
        }
        try await client.rename(source, to: destination)
    }

    func delete(_ paths: [SFTPPath]) async throws {
        let client = try await session.client()
        for path in paths {
            try await client.removeRecursively(path)
        }
    }

    // MARK: Transfers

    func download(_ sources: [SFTPPath], into directory: String, for transfer: FileTransfer, progress: TransferProgress) async throws {
        let client = try await session.client(.transfer)
        let plan = try await client.planDownload(sources, into: directory)
        transfer.begin(totalBytes: plan.totalBytes, files: plan.files.count, skipped: plan.skipped.map { "\($0.path): \($0.reason)" })
        transfer.failures = try await client.download(plan) { progress.record($0) }
    }

    func upload(_ sources: [String], into directory: SFTPPath, for transfer: FileTransfer, progress: TransferProgress) async throws {
        let client = try await session.client(.transfer)
        let plan = try await client.planUpload(sources, into: directory)
        transfer.begin(totalBytes: plan.totalBytes, files: plan.files.count, skipped: plan.skipped.map { "\($0.path): \($0.reason)" })
        transfer.failures = try await client.upload(plan) { progress.record($0) }
    }

    func disconnect() {
        session.disconnect()
    }
}

// MARK: - Pane

/// One folder view of a ``FileBackend``: the Mac Files tab's two panes, the iOS Files screen.
/// Holds the folder, its listing, selection, sort order and back history. Listing errors stay
/// in ``loadError`` (shown above the last listing); failed actions in ``actionError`` (shown as
/// an alert).
@MainActor
@Observable
final class FilePaneModel<Backend: FileBackend> {
    let backend: Backend

    private(set) var directory: Backend.Path?
    private(set) var items: [FileItem] = []
    var selection: Set<FileItem.ID> = []
    var sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]
    var showsHidden = false
    private(set) var isLoading = false
    private(set) var loadError: (any Error)?
    var actionError: String?
    /// Bumped by ``reset()``, so a visible pane starts over.
    private(set) var epoch = 0
    private var history: [Backend.Path] = []
    @ObservationIgnored private var generation = 0

    init(backend: Backend) {
        self.backend = backend
    }

    var displayPath: String {
        directory.map(backend.displayString) ?? ""
    }

    var canGoBack: Bool { !history.isEmpty }

    var canGoUp: Bool {
        directory.flatMap(backend.parent(of:)) != nil
    }

    /// The listing as shown: hidden items filtered unless shown, sorted, folders first.
    var visibleItems: [FileItem] {
        let shown = showsHidden ? items : items.filter { !$0.isHidden }
        let sorted = shown.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    /// The selected items, in display order.
    var selectedItems: [FileItem] {
        visibleItems.filter { selection.contains($0.id) }
    }

    func items(for ids: Set<FileItem.ID>) -> [FileItem] {
        visibleItems.filter { ids.contains($0.id) }
    }

    func path(of item: FileItem) -> Backend.Path? {
        directory.map { backend.path($0, appending: item.rawName) }
    }

    // MARK: Navigation

    /// Shows the home folder the first time.
    func start() {
        guard directory == nil, !isLoading else { return }
        goHome()
    }

    func goHome() {
        load(pushing: true) { [backend] in try await backend.home() }
    }

    func goUp() {
        guard let parent = directory.flatMap(backend.parent(of:)) else { return }
        show(parent)
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        show(previous, pushing: false)
    }

    /// Lists the folder again, keeping the selection (or selecting `name`).
    func refresh(selecting name: Data? = nil) {
        guard let directory else { return goHome() }
        load(pushing: false, select: name.map { [$0] }) { directory }
    }

    func go(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let from = directory
        load(pushing: true) { [backend] in try await backend.resolve(trimmed, from: from) }
    }

    func show(_ path: Backend.Path, pushing: Bool = true) {
        load(pushing: pushing) { path }
    }

    /// Opens a folder, or a link to one. Returns `false` for anything else.
    @discardableResult
    func open(_ item: FileItem) async -> Bool {
        guard let path = path(of: item) else { return false }
        switch item.kind {
        case .folder:
            show(path)
            return true
        case .symlink:
            guard (try? await backend.isFolder(path)) == true else { return false }
            show(path)
            return true
        case .file, .other:
            return false
        }
    }

    /// Forgets the folder and history (the host's address changed).
    func reset() {
        generation += 1
        directory = nil
        items = []
        selection = []
        history = []
        loadError = nil
        isLoading = false
        epoch += 1
    }

    private func load(
        pushing: Bool,
        select: Set<FileItem.ID>? = nil,
        target: @escaping @MainActor () async throws -> Backend.Path
    ) {
        generation += 1
        let token = generation
        isLoading = true
        Task {
            do {
                let path = try await target()
                let listed = try await backend.list(path)
                guard token == generation else { return }
                let changed = directory != path
                if pushing, changed, let directory { history.append(directory) }
                directory = path
                items = listed
                let ids = Set(listed.map(\.id))
                selection = select ?? (changed ? [] : selection.intersection(ids))
                loadError = nil
            } catch {
                guard token == generation else { return }
                loadError = error
            }
            isLoading = false
        }
    }

    // MARK: Actions

    func createFolder(named name: String) async {
        guard let directory else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        do {
            guard PathComponent.isSafe(name) else { throw FileBrowserError.invalidName(name) }
            guard !items.contains(where: { $0.name == name }) else { throw FileBrowserError.exists(name) }
            try await backend.createFolder(backend.path(directory, appending: Data(name.utf8)))
            refresh(selecting: Data(name.utf8))
        } catch {
            actionError = error.localizedDescription
        }
    }

    func rename(_ item: FileItem, to name: String) async {
        guard let directory, name != item.name else { return }
        do {
            guard PathComponent.isSafe(name) else { throw FileBrowserError.invalidName(name) }
            let destination = backend.path(directory, appending: Data(name.utf8))
            try await backend.rename(backend.path(directory, appending: item.rawName), to: destination)
            refresh(selecting: Data(name.utf8))
        } catch {
            actionError = error.localizedDescription
        }
    }

    func delete(_ items: [FileItem]) async {
        let paths = items.compactMap(path(of:))
        guard !paths.isEmpty else { return }
        do {
            try await backend.delete(paths)
        } catch {
            actionError = error.localizedDescription
        }
        refresh()
    }
}
