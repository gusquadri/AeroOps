import Foundation

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

extension FileItem {
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

private extension String {
    /// `/Users/me/` → `/Users/me`; `/` stays.
    var trimmingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
