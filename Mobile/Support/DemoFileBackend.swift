import AeroCore
import Foundation
import SSHKit

/// In-memory files for `-AeroOpsDemo` and previews: the home folder of a typical server, and
/// transfers that take a while (downloads write placeholder files, so the share sheet works).
final class DemoFileBackend: FileTransferBackend {
    private struct Node {
        var kind: FileItem.Kind
        var size: Int64?
        var modified: Date
        var mode: UInt32
        /// A link's target, for links.
        var target: String?
    }

    let deletesToTrash = false
    let homePath: String
    private var nodes: [String: Node] = [:]

    private static let downloadBytesPerSecond: Int64 = 24 << 20
    private static let uploadBytesPerSecond: Int64 = 384 << 10

    init(user: String) {
        homePath = user == "root" ? "/root" : "/home/\(user)"
        seed()
    }

    func home() async throws -> String { homePath }

    func list(_ directory: String) async throws -> [FileItem] {
        try await Task.sleep(for: .milliseconds(120))
        guard nodes[directory]?.kind == .folder || directory == "/" else { throw SFTPError.status(.noSuchFile, message: "") }
        return nodes.compactMap { path, node in
            guard parent(of: path) == directory, path != directory else { return nil }
            let name = (path as NSString).lastPathComponent
            return FileItem(
                rawName: Data(name.utf8), name: name, kind: node.kind,
                size: node.kind == .file ? node.size : nil, modified: node.modified, mode: node.mode
            )
        }
    }

    func path(_ directory: String, appending name: Data) -> String {
        let name = String(decoding: name, as: UTF8.self)
        return directory == "/" ? "/" + name : directory + "/" + name
    }

    func parent(of path: String) -> String? {
        path == "/" ? nil : (path as NSString).deletingLastPathComponent
    }

    func displayString(_ path: String) -> String { path }

    func resolve(_ text: String, from directory: String?) async throws -> String {
        let absolute = if text == "~" {
            homePath
        } else if text.hasPrefix("~/") {
            homePath + text.dropFirst()
        } else if text.hasPrefix("/") {
            text
        } else {
            path(directory ?? homePath, appending: Data(text.utf8))
        }
        let resolved = (absolute as NSString).standardizingPath
        guard try await isFolder(resolved) else { throw FileBrowserError.notAFolder(text) }
        return resolved
    }

    func isFolder(_ path: String) async throws -> Bool {
        let node = nodes[path]
        if let target = node?.target { return nodes[target]?.kind == .folder }
        return path == "/" || node?.kind == .folder
    }

    func createFolder(_ path: String) async throws {
        guard nodes[path] == nil else { throw FileBrowserError.exists((path as NSString).lastPathComponent) }
        nodes[path] = Node(kind: .folder, modified: .now, mode: 0o755)
    }

    func rename(_ source: String, to destination: String) async throws {
        guard nodes[destination] == nil else { throw FileBrowserError.exists((destination as NSString).lastPathComponent) }
        for (path, node) in nodes where path == source || path.hasPrefix(source + "/") {
            nodes[path] = nil
            nodes[destination + path.dropFirst(source.count)] = node
        }
    }

    func delete(_ paths: [String]) async throws {
        for source in paths {
            for path in nodes.keys where path == source || path.hasPrefix(source + "/") {
                nodes[path] = nil
            }
        }
    }

    func download(_ sources: [String], into directory: String, for transfer: FileTransfer, progress: TransferProgress) async throws {
        let files = nodes.filter { path, node in
            node.kind == .file && sources.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        .sorted { $0.key < $1.key }
        transfer.begin(totalBytes: files.reduce(0) { $0 + ($1.value.size ?? 0) }, files: files.count, skipped: [])
        for (path, node) in files {
            progress.record(.file(path))
            try await Self.copy(node.size ?? 0, bytesPerSecond: Self.downloadBytesPerSecond, progress: progress)
            let source = sources.first { path == $0 || path.hasPrefix($0 + "/") } ?? path
            let base = parent(of: source) ?? "/"
            let relative = path.dropFirst(base.count).drop { $0 == "/" }
            let local = URL(filePath: directory, directoryHint: .isDirectory).appending(path: String(relative))
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("A sample file from the AeroOps demo (\(path)).\n".utf8).write(to: local)
        }
    }

    func upload(_ sources: [String], into directory: String, for transfer: FileTransfer, progress: TransferProgress) async throws {
        let sizes = sources.map { source in
            ((try? FileManager.default.attributesOfItem(atPath: source))?[.size] as? Int64) ?? 0
        }
        transfer.begin(totalBytes: sizes.reduce(0, +), files: sources.count, skipped: [])
        for (source, size) in zip(sources, sizes) {
            progress.record(.file(source))
            try await Self.copy(size, bytesPerSecond: Self.uploadBytesPerSecond, progress: progress)
            let name = (source as NSString).lastPathComponent
            nodes[path(directory, appending: Data(name.utf8))] = Node(kind: .file, size: size, modified: .now, mode: 0o644)
        }
    }

    func disconnect() {}

    /// Reports `size` bytes over the time they would take.
    private static func copy(_ size: Int64, bytesPerSecond: Int64, progress: TransferProgress) async throws {
        let tick = Duration.milliseconds(100)
        let perTick = max(1, bytesPerSecond / 10)
        var left = size
        while left > 0 {
            try await Task.sleep(for: tick)
            let chunk = min(left, perTick)
            progress.record(.bytes(chunk))
            left -= chunk
        }
    }

    private func seed() {
        let day: TimeInterval = 86_400
        let now = Date.now
        func add(_ relative: String, _ kind: FileItem.Kind, size: Int64? = nil, age: TimeInterval, mode: UInt32? = nil, target: String? = nil) {
            nodes[homePath + "/" + relative] = Node(
                kind: kind, size: size, modified: now - age,
                mode: mode ?? (kind == .folder ? 0o755 : 0o644), target: target
            )
        }
        nodes[homePath] = Node(kind: .folder, modified: now - 2 * day, mode: 0o750)
        add(".bashrc", .file, size: 3_771, age: 220 * day)
        add(".profile", .file, size: 807, age: 220 * day)
        add(".ssh", .folder, age: 40 * day, mode: 0o700)
        add(".ssh/authorized_keys", .file, size: 742, age: 40 * day, mode: 0o600)
        add("app", .folder, age: 3_600)
        add("app/docker-compose.yml", .file, size: 2_418, age: 3_600)
        add("app/.env", .file, size: 512, age: 5 * day, mode: 0o600)
        add("app/src", .folder, age: 2 * day)
        add("app/src/server.js", .file, size: 18_204, age: 2 * day)
        add("app/src/routes.js", .file, size: 6_880, age: 2 * day)
        add("current", .symlink, age: 3 * day, mode: 0o777, target: homePath + "/app")
        add("backups", .folder, age: 7_200)
        add("backups/db-2026-10-16.sql.gz", .file, size: 48_612_330, age: day + 7_200)
        add("backups/db-2026-10-17.sql.gz", .file, size: 49_015_802, age: 7_200)
        add("logs", .folder, age: 120)
        add("logs/app.log", .file, size: 12_582_912, age: 120)
        add("logs/error.log", .file, size: 81_920, age: 900)
        add("deploy.sh", .file, size: 1_536, age: 12 * day, mode: 0o755)
        add("nginx.conf", .file, size: 4_096, age: 30 * day)
        add("notes.md", .file, size: 2_210, age: 6 * day)
    }
}

extension MobileFileBrowser where Backend == DemoFileBackend {
    /// A finished download (ready to share) and an upload that is still running, for the demo.
    func seedDemoTransfers() {
        let home = pane.backend.homePath
        download(
            [FileItem(rawName: Data("nginx.conf".utf8), name: "nginx.conf", kind: .file, size: 4_096, modified: nil, mode: nil)],
            in: home
        )
        let file = URL.temporaryDirectory.appending(path: "AeroOpsDemo/site-assets.tar.gz")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil),
           let handle = try? FileHandle(forWritingTo: file) {
            try? handle.truncate(atOffset: 36 << 20)
            try? handle.close()
        }
        upload([file], into: home + "/backups")
    }
}
