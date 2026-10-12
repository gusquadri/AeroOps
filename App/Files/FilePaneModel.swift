import AeroCore
import Foundation
import Observation
import SSHKit

/// One row of a file pane.
struct FileItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case file
        case symlink
        case other
    }

    /// The name's raw bytes: unique within a folder, and exact for remote names that are not UTF-8.
    var id: Data { rawName }
    let rawName: Data
    /// The name for display (invalid UTF-8 shows as �).
    let name: String
    let kind: Kind
    /// Size of a regular file; `nil` for everything else.
    let size: Int64?
    let modified: Date?
    /// Permission bits (`0o7777`), when known.
    let mode: UInt32?

    var isHidden: Bool { name.hasPrefix(".") }
    var isFolder: Bool { kind == .folder }

    /// Sort keys for the table: folders have no size, unknown dates sort first.
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
}

extension FileItem {
    /// A remote entry from `readdir`, whose attributes describe the entry itself (a symbolic link
    /// is a link, not its target).
    init(_ entry: SFTPEntry) {
        let kind: Kind = switch entry.attributes.kind {
        case .directory: .folder
        case .regular: .file
        case .symlink: .symlink
        case .other, .unknown: .other
        }
        self.init(
            rawName: entry.name,
            name: entry.displayName,
            kind: kind,
            size: kind == .file ? entry.attributes.size.map { Int64(clamping: $0) } : nil,
            modified: entry.attributes.modificationDate,
            mode: entry.attributes.mode
        )
    }

    /// A local entry, described with `lstat` like a remote one. `nil` if it vanished.
    init?(localName name: String, in directory: String) {
        var info = stat()
        guard lstat(LocalFileBackend.appending(directory, name), &info) == 0 else { return nil }
        let kind: Kind = switch info.st_mode & S_IFMT {
        case S_IFDIR: .folder
        case S_IFREG: .file
        case S_IFLNK: .symlink
        default: .other
        }
        self.init(
            rawName: Data(name.utf8),
            name: name,
            kind: kind,
            size: kind == .file ? Int64(info.st_size) : nil,
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
            mode: UInt32(info.st_mode) & 0o7777
        )
    }
}

/// Why a pane could not do what was asked.
enum FileBrowserError: LocalizedError, Equatable {
    /// The host can't be reached through SSHKit right now (no key, agent stopped, blocked).
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

/// Where a pane's files live: this Mac (``LocalFileBackend``) or a host over SFTP
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

/// This Mac's files. Listing and deleting run off the main actor.
final class LocalFileBackend: FileBackend {
    let deletesToTrash = true

    func home() async throws -> String {
        FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingSlash
    }

    func list(_ directory: String) async throws -> [FileItem] {
        try await Task.detached {
            try FileManager.default.contentsOfDirectory(atPath: directory)
                .compactMap { FileItem(localName: $0, in: directory) }
        }.value
    }

    func path(_ directory: String, appending name: Data) -> String {
        Self.appending(directory, String(decoding: name, as: UTF8.self))
    }

    func parent(of path: String) -> String? {
        path == "/" ? nil : (path as NSString).deletingLastPathComponent
    }

    func displayString(_ path: String) -> String {
        path
    }

    func resolve(_ text: String, from directory: String?) async throws -> String {
        let expanded = (text as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : Self.appending(directory ?? "/", expanded)
        let resolved = (absolute as NSString).standardizingPath
        guard try await isFolder(resolved) else { throw FileBrowserError.notAFolder(text) }
        return resolved
    }

    func isFolder(_ path: String) async throws -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func createFolder(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func rename(_ source: String, to destination: String) async throws {
        try FileManager.default.moveItem(atPath: source, toPath: destination)
    }

    func delete(_ paths: [String]) async throws {
        try await Task.detached {
            for path in paths {
                try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: nil)
            }
        }.value
    }

    nonisolated static func appending(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

/// A host's files through its ``RemoteFileSession``.
final class RemoteFileBackend: FileBackend {
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
}

// MARK: - Pane

/// One side of the Files tab: a folder of ``Backend``, its listing, selection, sort order and
/// back history. Listing errors stay in ``loadError`` (shown above the last listing); failed
/// actions in ``actionError`` (shown as an alert).
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

private extension String {
    /// `/Users/me/` → `/Users/me`; `/` stays.
    var trimmingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
