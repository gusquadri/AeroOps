import AeroCore
import Foundation

/// An SFTP version 3 session over any ``RemoteByteChannel``. On macOS that is the system ssh
/// (`ssh -s <alias> sftp`), so it shares the host's ControlMaster connection, pinned host key and
/// in-app agent like every other SSHKit call; on iOS, EmbeddedSSH's `sftp` subsystem channel.
///
/// Requests are pipelined: each carries an id, any number may be outstanding, and replies are
/// matched by id. Cancelling the task waiting on a request abandons it (a late reply is
/// dropped). When the channel ends, every outstanding and later request fails with
/// ``SFTPError/disconnected(_:)``.
///
/// ```swift
/// let sftp = try await SFTPClient.connect(using: runner, to: host)
/// let home = try await sftp.homeDirectory()
/// for entry in try await sftp.list(home) { print(entry.displayName) }
/// sftp.disconnect()
/// ```
public actor SFTPClient {
    /// Default read and write size: what every SFTP server must accept (draft 02 asks for
    /// 32 KiB of data). Raised from `limits@openssh.com` when the server offers it.
    static let defaultChunkSize = 32 * 1024
    /// Largest read or write per request, whatever the server allows (OpenSSH's own client
    /// uses up to 255 KiB).
    static let maxChunkSize = 255 * 1024

    private let channel: any RemoteByteChannel
    private var nextID: UInt32 = 0
    private var pending: [UInt32: CheckedContinuation<SFTPWire.Response, any Error>] = [:]
    private var versionWaiter: CheckedContinuation<[(String, Data)], any Error>?
    private var failure: SFTPError?
    private var reader: Task<Void, Never>?

    /// Extensions the server announced (name to data), e.g. `posix-rename@openssh.com`.
    public private(set) var extensions: [String: Data] = [:]
    /// Bytes requested per read.
    public private(set) var readChunkSize = SFTPClient.defaultChunkSize
    /// Bytes sent per write.
    public private(set) var writeChunkSize = SFTPClient.defaultChunkSize

    init(channel: any RemoteByteChannel) {
        self.channel = channel
    }

    deinit {
        reader?.cancel()
        channel.close()
    }

    /// Opens the `sftp` subsystem on `host` and completes the version handshake.
    ///
    /// - Throws: ``SSHError`` before ssh starts (a blocked host, a launch failure);
    ///   ``SFTPError/disconnected(_:)`` when ssh fails (unknown host key, auth, no `sftp`
    ///   subsystem) or the handshake does not finish within `timeout`.
    public static func connect(
        using runner: SSHRunner,
        to host: RemoteHost,
        timeout: Duration = .seconds(30)
    ) async throws -> SFTPClient {
        let channel = try await runner.openSubsystem("sftp", on: host)
        return try await connect(channel: channel, timeout: timeout)
    }

    /// Completes the version handshake over `channel`, an `sftp` subsystem session (EmbeddedSSH's
    /// on iOS).
    ///
    /// - Throws: ``SFTPError/disconnected(_:)`` when the channel ends or the handshake does not
    ///   finish within `timeout`.
    public static func connect(channel: any RemoteByteChannel, timeout: Duration = .seconds(30)) async throws -> SFTPClient {
        let client = SFTPClient(channel: channel)
        do {
            try await withTaskCancellationHandler {
                try await client.handshake(timeout: timeout)
            } onCancel: {
                channel.close()
            }
        } catch {
            channel.close()
            try Task.checkCancellation()
            throw error
        }
        return client
    }

    /// Ends the session: the channel is closed and outstanding requests fail.
    public nonisolated func disconnect() {
        channel.close()
    }

    /// `false` once the session ended.
    public var isConnected: Bool { failure == nil }

    /// Why the session ended, if it did.
    public var disconnectError: SFTPError? { failure }

    // MARK: - Paths and attributes

    /// The canonical absolute form of `path` (`.` is the login directory).
    public func realPath(_ path: SFTPPath) async throws -> SFTPPath {
        let response = try await request(.realpath) { $0.string(path.bytes) }
        guard let first = try Self.names(response).first else {
            throw SFTPError.protocolError("REALPATH returned no name")
        }
        return SFTPPath(bytes: first.filename)
    }

    /// The login (home) directory.
    public func homeDirectory() async throws -> SFTPPath {
        try await realPath(SFTPPath("."))
    }

    /// The attributes of `path`; with `followingSymlinks` (the default) those of a link's target.
    public func attributes(of path: SFTPPath, followingSymlinks: Bool = true) async throws -> SFTPAttributes {
        let response = try await request(followingSymlinks ? .stat : .lstat) { $0.string(path.bytes) }
        return try Self.attributes(response)
    }

    /// The target of the symbolic link at `path`.
    public func readLink(_ path: SFTPPath) async throws -> SFTPPath {
        let response = try await request(.readlink) { $0.string(path.bytes) }
        guard let first = try Self.names(response).first else {
            throw SFTPError.protocolError("READLINK returned no name")
        }
        return SFTPPath(bytes: first.filename)
    }

    /// Sets the permission bits of `path`.
    public func setPermissions(_ path: SFTPPath, _ mode: UInt32) async throws {
        let response = try await request(.setstat) { writer in
            writer.string(path.bytes)
            writer.attributes(SFTPAttributes(permissions: mode & 0o7777))
        }
        try Self.check(response)
    }

    // MARK: - Directories

    /// The entries of `directory`, without `.` and `..`. Entries whose names could not be used
    /// as a path component (with `/` or NUL) are left out.
    public func list(_ directory: SFTPPath) async throws -> [SFTPEntry] {
        let handle = try await openDirectory(directory)
        var entries: [SFTPEntry] = []
        do {
            while true {
                let response = try await request(.readdir) { $0.string(handle.raw) }
                if case .status(.eof, _) = response { break }
                for entry in try Self.names(response) where PathComponent.isSafe(entry.filename) {
                    entries.append(SFTPEntry(
                        name: entry.filename,
                        attributes: entry.attributes,
                        path: directory.appending(component: entry.filename)
                    ))
                }
            }
        } catch {
            discard(handle)
            throw error
        }
        try? await close(handle)
        return entries
    }

    /// Creates a directory; `permissions` (masked by the server's umask) default to the server's.
    public func createDirectory(_ path: SFTPPath, permissions: UInt32? = nil) async throws {
        let response = try await request(.mkdir) { writer in
            writer.string(path.bytes)
            writer.attributes(SFTPAttributes(permissions: permissions.map { $0 & 0o7777 }))
        }
        try Self.check(response)
    }

    /// Removes an empty directory.
    public func removeDirectory(_ path: SFTPPath) async throws {
        try Self.check(try await request(.rmdir) { $0.string(path.bytes) })
    }

    /// Removes a file or symbolic link.
    public func removeFile(_ path: SFTPPath) async throws {
        try Self.check(try await request(.remove) { $0.string(path.bytes) })
    }

    /// Renames `source` to `destination`. With `posix-rename@openssh.com` an existing file at
    /// `destination` is replaced; plain SFTP v3 refuses to.
    public func rename(_ source: SFTPPath, to destination: SFTPPath) async throws {
        let response: SFTPWire.Response
        if extensions["posix-rename@openssh.com"] != nil {
            response = try await request(.extended) { writer in
                writer.string("posix-rename@openssh.com")
                writer.string(source.bytes)
                writer.string(destination.bytes)
            }
        } else {
            response = try await request(.rename) { writer in
                writer.string(source.bytes)
                writer.string(destination.bytes)
                writer.u32(0)
            }
        }
        try Self.check(response)
    }

    /// Deletes `path`; a directory with everything in it. Symbolic links are removed, never
    /// followed.
    public func removeRecursively(_ path: SFTPPath) async throws {
        try await removeRecursively(path, depth: 0)
    }

    private func removeRecursively(_ path: SFTPPath, depth: Int) async throws {
        let attributes = try await attributes(of: path, followingSymlinks: false)
        guard attributes.kind == .directory else {
            try await removeFile(path)
            return
        }
        guard depth < SFTPTransferPlanner.maxDepth else {
            throw SFTPError.local(path: path.string, message: "Folders are nested too deeply.")
        }
        for entry in try await list(path) {
            try Task.checkCancellation()
            if entry.attributes.kind == .directory {
                try await removeRecursively(entry.path, depth: depth + 1)
            } else {
                try await removeFile(entry.path)
            }
        }
        try await removeDirectory(path)
    }

    // MARK: - Files

    func open(_ path: SFTPPath, flags: SFTPWire.OpenFlags, attributes: SFTPAttributes = SFTPAttributes()) async throws -> SFTPFileHandle {
        let response = try await request(.open) { writer in
            writer.string(path.bytes)
            writer.u32(flags.rawValue)
            writer.attributes(attributes)
        }
        return try Self.handle(response)
    }

    func openDirectory(_ path: SFTPPath) async throws -> SFTPFileHandle {
        try Self.handle(try await request(.opendir) { $0.string(path.bytes) })
    }

    /// Up to `length` bytes at `offset`, or `nil` at end of file. May return fewer bytes.
    func read(_ handle: SFTPFileHandle, offset: UInt64, length: Int) async throws -> Data? {
        let response = try await request(.read) { writer in
            writer.string(handle.raw)
            writer.u64(offset)
            writer.u32(UInt32(length))
        }
        switch response {
        case .data(let data):
            guard data.count <= length else { throw SFTPError.protocolError("READ returned more than requested") }
            return data
        case .status(.eof, _):
            return nil
        default:
            try Self.check(response)
            throw SFTPError.protocolError("unexpected reply to READ")
        }
    }

    func write(_ handle: SFTPFileHandle, offset: UInt64, data: Data) async throws {
        let response = try await request(.write) { writer in
            writer.string(handle.raw)
            writer.u64(offset)
            writer.string(data)
        }
        try Self.check(response)
    }

    func attributes(of handle: SFTPFileHandle) async throws -> SFTPAttributes {
        try Self.attributes(try await request(.fstat) { $0.string(handle.raw) })
    }

    func close(_ handle: SFTPFileHandle) async throws {
        try Self.check(try await request(.close) { $0.string(handle.raw) })
    }

    /// Closes `handle` without waiting for the reply; for cleanup after a failure or a
    /// cancellation, where awaiting would itself be cancelled.
    func discard(_ handle: SFTPFileHandle) {
        sendUnanswered(.close) { $0.string(handle.raw) }
    }

    /// Removes `path` without waiting for the reply (cleanup of a partial upload). The server
    /// handles requests in order, so this runs after anything sent before it.
    func discardFile(_ path: SFTPPath) {
        sendUnanswered(.remove) { $0.string(path.bytes) }
    }

    // MARK: - Session

    private func handshake(timeout: Duration) async throws {
        startReader()
        let watchdog = Task { [channel] in
            try await Task.sleep(for: timeout)
            fail(.disconnected(.timeout))
            channel.close()
        }
        defer { watchdog.cancel() }

        let announced = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[(String, Data)], any Error>) in
            if let failure {
                continuation.resume(throwing: failure)
                return
            }
            versionWaiter = continuation
            var writer = SFTPWire.Writer(.initialize)
            writer.u32(SFTPWire.version)
            channel.send(writer.framed)
        }
        for (name, data) in announced { extensions[name] = data }

        if extensions["limits@openssh.com"] != nil,
           case .extendedReply(let data) = try await request(.extended, { $0.string("limits@openssh.com") }) {
            var reader = SFTPWire.Reader(data)
            let maxPacket = try reader.u64()
            let maxRead = try reader.u64()
            let maxWrite = try reader.u64()
            readChunkSize = Self.chunkSize(limit: maxRead, packetLimit: maxPacket)
            writeChunkSize = Self.chunkSize(limit: maxWrite, packetLimit: maxPacket)
        }
    }

    /// A read or write size within the server's limits (0 means "no limit").
    static func chunkSize(limit: UInt64, packetLimit: UInt64) -> Int {
        var size = UInt64(maxChunkSize)
        if limit > 0 { size = min(size, limit) }
        // Room for the packet header, handle and offset.
        if packetLimit > 1024 { size = min(size, packetLimit - 1024) }
        return max(Int(size), 4096)
    }

    private func startReader() {
        let channel = channel
        reader = Task { [weak self] in
            var framer = SFTPWire.Framer()
            do {
                for await chunk in channel.incoming {
                    for body in try framer.append(chunk) {
                        let packet = try SFTPWire.parse(body)
                        guard let self else { return }
                        await self.deliver(packet)
                    }
                }
                let error = await channel.waitForEnd()
                await self?.fail(.disconnected(error ?? .connectionClosed))
            } catch let error as SFTPError {
                channel.close()
                await self?.fail(error)
            } catch {
                channel.close()
                await self?.fail(.protocolError(error.localizedDescription))
            }
        }
    }

    private func deliver(_ packet: SFTPWire.Packet) {
        switch packet {
        case .version(let version, let announced):
            guard let waiter = versionWaiter else { return }
            versionWaiter = nil
            if version < SFTPWire.version {
                waiter.resume(throwing: SFTPError.protocolError("the server speaks SFTP version \(version), not 3"))
            } else {
                waiter.resume(returning: announced)
            }
        case .response(let id, let response):
            pending.removeValue(forKey: id)?.resume(returning: response)
        }
    }

    private func fail(_ error: SFTPError) {
        if failure == nil { failure = error }
        let error = failure ?? error
        versionWaiter?.resume(throwing: error)
        versionWaiter = nil
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func cancel(_ id: UInt32) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func makeID() -> UInt32 {
        defer { nextID &+= 1 }
        return nextID
    }

    private func request(
        _ type: SFTPWire.PacketType,
        _ fill: (inout SFTPWire.Writer) -> Void
    ) async throws -> SFTPWire.Response {
        if let failure { throw failure }
        let id = makeID()
        var writer = SFTPWire.Writer(type)
        writer.u32(id)
        fill(&writer)
        let packet = writer.framed
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    pending[id] = continuation
                    channel.send(packet)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func sendUnanswered(_ type: SFTPWire.PacketType, _ fill: (inout SFTPWire.Writer) -> Void) {
        guard failure == nil else { return }
        var writer = SFTPWire.Writer(type)
        writer.u32(makeID())
        fill(&writer)
        channel.send(writer.framed)
    }

    // MARK: - Replies

    private static func check(_ response: SFTPWire.Response) throws(SFTPError) {
        guard case .status(let code, let message) = response else {
            throw .protocolError("expected a STATUS reply")
        }
        guard code == .ok else { throw .status(code, message: message) }
    }

    private static func handle(_ response: SFTPWire.Response) throws(SFTPError) -> SFTPFileHandle {
        if case .handle(let raw) = response { return SFTPFileHandle(raw: raw) }
        try check(response)
        throw .protocolError("expected a HANDLE reply")
    }

    private static func names(_ response: SFTPWire.Response) throws(SFTPError) -> [SFTPWire.NameEntry] {
        if case .name(let entries) = response { return entries }
        try check(response)
        throw .protocolError("expected a NAME reply")
    }

    private static func attributes(_ response: SFTPWire.Response) throws(SFTPError) -> SFTPAttributes {
        if case .attrs(let attributes) = response { return attributes }
        try check(response)
        throw .protocolError("expected an ATTRS reply")
    }
}
