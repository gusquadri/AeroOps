import Darwin
import Foundation

/// What a transfer will do, worked out before any byte moves so the total size is known.
///
/// Directories are listed parents first; create them all, then copy the files.
public struct SFTPTransferPlan<Source: Hashable & Sendable, Destination: Hashable & Sendable>: Sendable {
    public struct Directory: Sendable, Hashable {
        public let destination: Destination
        /// Permission bits to create it with.
        public let mode: UInt32
    }

    public struct File: Sendable, Hashable {
        public let source: Source
        public let destination: Destination
        /// Size when planned; the copy takes whatever is there when it runs.
        public let size: Int64
        public let mode: UInt32
        /// The source path, for progress and error messages.
        public let displayPath: String
    }

    /// Something left out, and why (a socket, a link to a folder, an unreadable folder).
    public struct Skipped: Sendable, Hashable {
        public let path: String
        public let reason: String
    }

    public var directories: [Directory] = []
    public var files: [File] = []
    public var skipped: [Skipped] = []

    public init() {}

    /// The sum of the planned file sizes.
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Remote paths to a local directory.
public typealias SFTPDownloadPlan = SFTPTransferPlan<SFTPPath, String>
/// Local paths to a remote directory.
public typealias SFTPUploadPlan = SFTPTransferPlan<String, SFTPPath>

/// A file or folder that could not be copied; the rest of the transfer carried on.
public struct SFTPTransferFailure: Sendable, Hashable {
    public let path: String
    public let message: String
}

/// Progress of a running transfer.
public enum SFTPTransferEvent: Sendable, Hashable {
    /// A file started; its source path for display.
    case file(String)
    /// This many more bytes were copied.
    case bytes(Int64)
}

/// Builds transfer plans.
///
/// The selected items themselves are followed if they are symbolic links (as in Finder, a link
/// to a folder copies the folder). Inside folders, links to files are copied as the file and
/// links to folders are skipped, so a link cycle can never recurse.
enum SFTPTransferPlanner {
    /// Deepest folder nesting walked.
    static let maxDepth = 64
    /// Mode for a folder whose permissions are unknown.
    static let defaultDirectoryMode: UInt32 = 0o755
    /// Mode for a file whose permissions are unknown.
    static let defaultFileMode: UInt32 = 0o644
}

extension SFTPClient {
    /// Plans copying each of `sources` (files or folders, by their own name) into the local
    /// directory `directory`.
    public nonisolated func planDownload(_ sources: [SFTPPath], into directory: String) async throws -> SFTPDownloadPlan {
        var plan = SFTPDownloadPlan()
        for source in sources {
            try Task.checkCancellation()
            let name = source.lastComponent
            guard PathComponent.isSafe(name) else { throw SFTPError.invalidName(source.name) }
            let destination = LocalPath.appending(directory, String(decoding: name, as: UTF8.self))
            let attributes = try await attributes(of: source)
            switch attributes.kind {
            case .directory:
                plan.directories.append(.init(destination: destination, mode: Self.directoryMode(attributes.mode)))
                try await walkRemote(source, into: destination, depth: 1, plan: &plan)
            case .regular:
                plan.files.append(Self.downloadFile(source, to: destination, attributes))
            default:
                plan.skipped.append(.init(path: source.string, reason: "Not a file or folder."))
            }
        }
        return plan
    }

    private nonisolated func walkRemote(_ directory: SFTPPath, into local: String, depth: Int, plan: inout SFTPDownloadPlan) async throws {
        guard depth <= SFTPTransferPlanner.maxDepth else {
            plan.skipped.append(.init(path: directory.string, reason: "Folders are nested too deeply."))
            return
        }
        let entries: [SFTPEntry]
        do {
            entries = try await list(directory)
        } catch let error as SFTPError where Self.isPerItem(error) {
            plan.skipped.append(.init(path: directory.string, reason: error.localizedDescription))
            return
        }
        for entry in entries.sorted(by: { $0.name.lexicographicallyPrecedes($1.name) }) {
            try Task.checkCancellation()
            let destination = LocalPath.appending(local, entry.displayName)
            var attributes = entry.attributes
            if attributes.kind == .symlink {
                guard let target = try? await self.attributes(of: entry.path), target.kind == .regular else {
                    plan.skipped.append(.init(path: entry.path.string, reason: "Symbolic link to a folder or to nothing."))
                    continue
                }
                attributes = target
            }
            switch attributes.kind {
            case .directory:
                plan.directories.append(.init(destination: destination, mode: Self.directoryMode(attributes.mode)))
                try await walkRemote(entry.path, into: destination, depth: depth + 1, plan: &plan)
            case .regular:
                plan.files.append(Self.downloadFile(entry.path, to: destination, attributes))
            default:
                plan.skipped.append(.init(path: entry.path.string, reason: "Not a file or folder."))
            }
        }
    }

    /// Plans copying each of the local `sources` (files or folders, by their own name) into the
    /// remote directory `directory`.
    public nonisolated func planUpload(_ sources: [String], into directory: SFTPPath) async throws -> SFTPUploadPlan {
        var plan = SFTPUploadPlan()
        for source in sources {
            try Task.checkCancellation()
            let name = LocalPath.lastComponent(source)
            guard PathComponent.isSafe(name) else { throw SFTPError.invalidName(name) }
            let destination = directory.appending(component: name)
            let info = try LocalFileInfo(path: source, followingSymlinks: true)
            switch info.kind {
            case .directory:
                plan.directories.append(.init(destination: destination, mode: info.mode))
                try walkLocal(source, into: destination, depth: 1, plan: &plan)
            case .regular:
                plan.files.append(.init(source: source, destination: destination, size: info.size, mode: info.mode, displayPath: source))
            default:
                plan.skipped.append(.init(path: source, reason: "Not a file or folder."))
            }
        }
        return plan
    }

    private nonisolated func walkLocal(_ directory: String, into remote: SFTPPath, depth: Int, plan: inout SFTPUploadPlan) throws {
        guard depth <= SFTPTransferPlanner.maxDepth else {
            plan.skipped.append(.init(path: directory, reason: "Folders are nested too deeply."))
            return
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        } catch {
            plan.skipped.append(.init(path: directory, reason: (error as NSError).localizedFailureReason ?? error.localizedDescription))
            return
        }
        for name in names where PathComponent.isSafe(name) {
            try Task.checkCancellation()
            let source = LocalPath.appending(directory, name)
            let destination = remote.appending(component: name)
            guard var info = try? LocalFileInfo(path: source, followingSymlinks: false) else {
                plan.skipped.append(.init(path: source, reason: "Can’t be read."))
                continue
            }
            if info.kind == .symlink {
                guard let target = try? LocalFileInfo(path: source, followingSymlinks: true), target.kind == .regular else {
                    plan.skipped.append(.init(path: source, reason: "Symbolic link to a folder or to nothing."))
                    continue
                }
                info = target
            }
            switch info.kind {
            case .directory:
                plan.directories.append(.init(destination: destination, mode: info.mode))
                try walkLocal(source, into: destination, depth: depth + 1, plan: &plan)
            case .regular:
                plan.files.append(.init(source: source, destination: destination, size: info.size, mode: info.mode, displayPath: source))
            default:
                plan.skipped.append(.init(path: source, reason: "Not a file or folder."))
            }
        }
    }

    /// Creates the plan's folders, then downloads its files one after another. A file or
    /// folder that fails is reported and the rest carry on; a lost session or cancellation
    /// stops the transfer (the file in progress is removed).
    public nonisolated func download(
        _ plan: SFTPDownloadPlan,
        onEvent: @escaping @Sendable (SFTPTransferEvent) -> Void = { _ in }
    ) async throws -> [SFTPTransferFailure] {
        var failures: [SFTPTransferFailure] = []
        var failedDirectories: [String] = []
        for directory in plan.directories {
            try Task.checkCancellation()
            do {
                try LocalPath.makeDirectory(directory.destination, mode: directory.mode)
            } catch {
                failures.append(.init(path: directory.destination, message: error.localizedDescription))
                failedDirectories.append(directory.destination + "/")
            }
        }
        for file in plan.files {
            try Task.checkCancellation()
            if failedDirectories.contains(where: { file.destination.hasPrefix($0) }) { continue }
            onEvent(.file(file.displayPath))
            do {
                try await download(file.source, to: file.destination) { onEvent(.bytes($0)) }
            } catch let error as SFTPError where Self.isPerItem(error) {
                failures.append(.init(path: file.displayPath, message: error.localizedDescription))
            }
        }
        return failures
    }

    /// Creates the plan's folders, then uploads its files one after another; failures are
    /// handled as in ``download(_:onEvent:)``.
    public nonisolated func upload(
        _ plan: SFTPUploadPlan,
        onEvent: @escaping @Sendable (SFTPTransferEvent) -> Void = { _ in }
    ) async throws -> [SFTPTransferFailure] {
        var failures: [SFTPTransferFailure] = []
        var failedDirectories: [Data] = []
        for directory in plan.directories {
            try Task.checkCancellation()
            do {
                try await createDirectoryIfMissing(directory.destination, mode: directory.mode)
            } catch let error as SFTPError where Self.isPerItem(error) {
                failures.append(.init(path: directory.destination.string, message: error.localizedDescription))
                failedDirectories.append(directory.destination.bytes + Data("/".utf8))
            }
        }
        for file in plan.files {
            try Task.checkCancellation()
            if failedDirectories.contains(where: { file.destination.bytes.starts(with: $0) }) { continue }
            onEvent(.file(file.displayPath))
            do {
                try await upload(file.source, to: file.destination) { onEvent(.bytes($0)) }
            } catch let error as SFTPError where Self.isPerItem(error) {
                failures.append(.init(path: file.displayPath, message: error.localizedDescription))
            }
        }
        return failures
    }

    private func createDirectoryIfMissing(_ path: SFTPPath, mode: UInt32) async throws {
        do {
            try await createDirectory(path, permissions: mode & 0o777)
        } catch let error as SFTPError {
            guard let existing = try? await attributes(of: path), existing.kind == .directory else { throw error }
        }
    }

    /// Number of reads or writes kept in flight, about 8 MiB of data.
    nonisolated static func window(chunkSize: Int) -> Int {
        max(4, min(64, (8 * 1024 * 1024) / max(1, chunkSize)))
    }

    /// Downloads the remote file `source` to the local path `destination`, replacing a file
    /// there. Data goes to a temporary file next to `destination` that is renamed into place
    /// when complete, so an interrupted download never leaves a truncated file. The copy keeps
    /// the remote permission bits (owner read/write always added, set-id bits dropped).
    public nonisolated func download(
        _ source: SFTPPath,
        to destination: String,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws {
        let handle = try await open(source, flags: .read)
        var temporary: (fd: Int32, path: String)?
        do {
            let attributes = try await self.attributes(of: handle)
            let created = try LocalPath.makeTemporaryFile(beside: destination)
            temporary = created
            let chunk = await readChunkSize
            try await withThrowingTaskGroup(of: (UInt64, Int, Data?).self) { group in
                var next: UInt64 = 0
                var reachedEnd = false
                var limit = attributes.size
                var retries: [(UInt64, Int)] = []
                var running = 0
                let window = Self.window(chunkSize: chunk)
                while true {
                    while running < window {
                        let request: (offset: UInt64, length: Int)
                        if let retry = retries.popLast() {
                            request = retry
                        } else if !reachedEnd, limit.map({ next <= $0 }) ?? true {
                            request = (next, chunk)
                            next += UInt64(chunk)
                        } else {
                            break
                        }
                        group.addTask {
                            (request.offset, request.length, try await self.read(handle, offset: request.offset, length: request.length))
                        }
                        running += 1
                    }
                    guard let (offset, length, data) = try await group.next() else { break }
                    running -= 1
                    guard let data, !data.isEmpty else {
                        reachedEnd = true
                        continue
                    }
                    try LocalPath.write(data, to: created.fd, at: offset, path: created.path)
                    progress(Int64(data.count))
                    let end = offset + UInt64(data.count)
                    if let known = limit, end > known { limit = nil }
                    if data.count < length { retries.append((end, length - data.count)) }
                }
            }
            let mode = (attributes.mode ?? SFTPTransferPlanner.defaultFileMode) & 0o777 | 0o600
            fchmod(created.fd, mode_t(mode))
            guard Darwin.close(created.fd) == 0 else { throw SFTPError.local(created.path, errno: errno) }
            temporary = (-1, created.path)
            guard Darwin.rename(created.path, destination) == 0 else { throw SFTPError.local(destination, errno: errno) }
            temporary = nil
        } catch {
            await discard(handle)
            if let temporary {
                if temporary.fd >= 0 { Darwin.close(temporary.fd) }
                unlink(temporary.path)
            }
            throw error
        }
        try? await close(handle)
    }

    /// Uploads the local file `source` to the remote path `destination`, replacing (and
    /// writing through a symbolic link at) `destination`, as OpenSSH's `sftp put` does. A new
    /// file gets the local permission bits; if the upload fails, a file it created is removed.
    public nonisolated func upload(
        _ source: String,
        to destination: SFTPPath,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws {
        let fd = Darwin.open(source, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw SFTPError.local(source, errno: errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SFTPError.local(source, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw SFTPError.local(path: source, message: "Not a regular file.") }

        let existed: Bool
        do {
            _ = try await attributes(of: destination, followingSymlinks: false)
            existed = true
        } catch let error as SFTPError where error.isNoSuchFile {
            existed = false
        }
        let handle = try await open(
            destination,
            flags: [.write, .create, .truncate],
            attributes: SFTPAttributes(permissions: UInt32(info.st_mode) & 0o777)
        )
        do {
            let chunk = await writeChunkSize
            try await withThrowingTaskGroup(of: Int.self) { group in
                var offset: UInt64 = 0
                var running = 0
                var reachedEnd = false
                let window = Self.window(chunkSize: chunk)
                while true {
                    while running < window, !reachedEnd {
                        let data = try LocalPath.read(fd, at: offset, length: chunk, path: source)
                        if data.isEmpty {
                            reachedEnd = true
                            break
                        }
                        let at = offset
                        offset += UInt64(data.count)
                        group.addTask {
                            try await self.write(handle, offset: at, data: data)
                            return data.count
                        }
                        running += 1
                    }
                    guard let written = try await group.next() else { break }
                    running -= 1
                    progress(Int64(written))
                }
            }
            try await close(handle)
        } catch {
            await discard(handle)
            if !existed { await discardFile(destination) }
            throw error
        }
    }

    /// Errors that concern one file or folder; anything else ends the transfer.
    nonisolated static func isPerItem(_ error: SFTPError) -> Bool {
        switch error {
        case .status(let code, _):
            code != .noConnection && code != .connectionLost
        case .local, .invalidName:
            true
        case .disconnected, .protocolError:
            false
        }
    }

    private nonisolated static func directoryMode(_ mode: UInt32?) -> UInt32 {
        (mode ?? SFTPTransferPlanner.defaultDirectoryMode) & 0o777 | 0o700
    }

    private nonisolated static func downloadFile(_ source: SFTPPath, to destination: String, _ attributes: SFTPAttributes) -> SFTPDownloadPlan.File {
        .init(
            source: source,
            destination: destination,
            size: Int64(clamping: attributes.size ?? 0),
            mode: attributes.mode ?? SFTPTransferPlanner.defaultFileMode,
            displayPath: source.string
        )
    }
}

/// `lstat`/`stat` of a local path.
struct LocalFileInfo {
    var kind: SFTPFileKind
    var size: Int64
    var mode: UInt32

    init(path: String, followingSymlinks: Bool) throws(SFTPError) {
        var info = stat()
        let status = followingSymlinks ? stat(path, &info) : lstat(path, &info)
        guard status == 0 else { throw .local(path, errno: errno) }
        kind = SFTPAttributes(permissions: UInt32(info.st_mode)).kind
        size = Int64(info.st_size)
        mode = UInt32(info.st_mode) & 0o7777
    }
}

/// Local file helpers for transfers (plain POSIX, no Foundation file coordination).
enum LocalPath {
    static func appending(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func lastComponent(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? String(trimmed)
    }

    /// Creates `path`; an existing folder is fine.
    static func makeDirectory(_ path: String, mode: UInt32) throws(SFTPError) {
        if mkdir(path, mode_t(mode & 0o777)) == 0 { return }
        let code = errno
        var info = stat()
        if code == EEXIST, stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return }
        throw .local(path, errno: code)
    }

    /// Creates an empty, owner-only file next to `destination` with a name nothing else uses.
    static func makeTemporaryFile(beside destination: String) throws(SFTPError) -> (fd: Int32, path: String) {
        let directory = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        for _ in 0..<16 {
            let suffix = String(UInt32.random(in: .min ... .max), radix: 36)
            let path = appending(directory.isEmpty ? "." : directory, ".\(name).aeroops-\(suffix).part")
            let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if fd >= 0 { return (fd, path) }
            if errno != EEXIST { throw .local(directory, errno: errno) }
        }
        throw .local(path: directory, message: "Could not create a temporary file.")
    }

    static func write(_ data: Data, to fd: Int32, at offset: UInt64, path: String) throws(SFTPError) {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { raw in
                pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(offset) + off_t(written))
            }
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw .local(path, errno: count < 0 ? errno : EIO)
            }
        }
    }

    /// Up to `length` bytes at `offset`; empty at end of file.
    static func read(_ fd: Int32, at offset: UInt64, length: Int, path: String) throws(SFTPError) -> Data {
        var data = Data(count: length)
        var total = 0
        while total < length {
            let count = data.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + total, length - total, off_t(offset) + off_t(total))
            }
            if count > 0 {
                total += count
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw .local(path, errno: errno)
            }
        }
        data.count = total
        return data
    }
}
