import AeroCore
import BridgeProtocol
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Answers bridge requests. ``Bridge`` is the production implementation.
public protocol BridgeRequestHandler: Sendable {
    /// Handles one request from an accepted peer. `progress` sends a progress line for it.
    ///
    /// Runs in its own task, which is cancelled when the CLI sends a cancel line for the request
    /// or the connection closes. Return `nil` to send no reply (the agent cancelled it).
    func handle(_ request: BridgeRequest, from peer: BridgePeer,
                progress: @escaping @Sendable (String) -> Void) async -> BridgeReply?
}

/// Why the bridge socket could not be started.
public enum BridgeServerError: Error, Equatable, Sendable, LocalizedError {
    /// `sun_path` holds at most 103 bytes plus the terminating NUL.
    case socketPathTooLong(String)
    /// The socket's directory is not a directory owned by this user.
    case insecureDirectory(String)
    /// Another process is accepting connections on the socket (another AeroOps).
    case alreadyRunning(String)
    /// Something other than a socket is at the socket path; it is left alone.
    case notASocket(String)
    case system(operation: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path): "The bridge socket path is too long: \(path)"
        case .insecureDirectory(let path): "\(path) must be a directory owned by you."
        case .alreadyRunning(let path): "Another AeroOps is already listening on \(path)."
        case .notASocket(let path): "\(path) exists and is not a socket."
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Connection events, for the app's diagnostics and tests. Never contains request contents.
public struct BridgeServerEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case connected(BridgePeer)
        case rejected(reason: String)
        /// A line that could not be handled (malformed, oversized, too many requests).
        case protocolError(String)
        case disconnected
    }

    public var connectionID: UInt64
    public var kind: Kind
}

/// The app side of `~/.aeroops/bridge.sock`.
///
/// - The directory is `0700` and the socket `0600`; a stale socket is replaced, a live one
///   (another AeroOps) is not. ``stop()`` only unlinks the socket it created.
/// - Every connection's peer goes through the ``BridgePeerValidator`` before a single byte is
///   read; a rejected peer gets an id-0 `peer_rejected` reply and is disconnected.
/// - Each request runs in its own task, so one connection can have many calls in flight (up to
///   ``BridgeLimits/maxConcurrentRequestsPerConnection``). A cancel line cancels that task; a
///   closed connection cancels all of its tasks. Cancelled calls get no reply.
public final class BridgeServer: Sendable {
    public let socketURL: URL
    private let core: BridgeServerCore

    public init(socketURL: URL, handler: any BridgeRequestHandler, validator: any BridgePeerValidator,
                maxConnections: Int = 32) {
        self.socketURL = socketURL
        core = BridgeServerCore(socketPath: socketURL.path(percentEncoded: false), handler: handler,
                                validator: validator, maxConnections: maxConnections)
    }

    deinit {
        core.stop()
        core.events.finish()
    }

    public var isRunning: Bool { core.isRunning }

    /// Number of open connections.
    public var connectionCount: Int { core.connectionCount }

    /// Connection events as they happen.
    public func events() -> AsyncStream<BridgeServerEvent> {
        core.events.subscribe()
    }

    /// Creates the socket and starts accepting connections. Does nothing if already running.
    public func start() throws(BridgeServerError) {
        try core.start()
    }

    /// Stops accepting, closes open connections (cancelling their calls) and removes the socket
    /// if it is still ours.
    public func stop() {
        core.stop()
    }
}

/// The socket machinery. Blocking reads run on one thread per connection; writes go through a
/// serial queue per connection; request handling runs in Swift tasks.
final class BridgeServerCore: Sendable {
    private struct State {
        var listenFD: Int32 = -1
        var acceptSource: (any DispatchSourceRead)?
        /// device and inode of the socket file we created, so stop() never unlinks another's.
        var socketNode: (dev: dev_t, ino: ino_t)?
        var connections: [UInt64: BridgeConnection] = [:]
        var nextConnectionID: UInt64 = 1
    }

    let socketPath: String
    let handler: any BridgeRequestHandler
    let validator: any BridgePeerValidator
    let maxConnections: Int
    let events = Broadcaster<BridgeServerEvent>(bufferSize: 256)
    private let state = Mutex(State())
    private let acceptQueue = DispatchQueue(label: "app.aeroops.bridge.accept")

    static let writeTimeoutSeconds = 10

    init(socketPath: String, handler: any BridgeRequestHandler, validator: any BridgePeerValidator, maxConnections: Int) {
        self.socketPath = socketPath
        self.handler = handler
        self.validator = validator
        self.maxConnections = max(1, maxConnections)
    }

    var isRunning: Bool { state.withLock { $0.listenFD >= 0 } }
    var connectionCount: Int { state.withLock { $0.connections.count } }

    func emit(_ connectionID: UInt64, _ kind: BridgeServerEvent.Kind) {
        events.yield(BridgeServerEvent(connectionID: connectionID, kind: kind))
    }

    // MARK: Start and stop

    func start() throws(BridgeServerError) {
        guard !isRunning else { return }
        let directory = (socketPath as NSString).deletingLastPathComponent
        let tempPath = (directory as NSString).appendingPathComponent(".bridge-\(String(UInt32.random(in: 0...UInt32.max), radix: 16)).tmp")
        for path in [socketPath, tempPath] where path.utf8.count > BridgeSocketPath.maxPathBytes {
            throw .socketPathTooLong(path)
        }
        try Self.preparePrivateDirectory(directory)
        try Self.removeStaleSocket(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system(operation: "socket", errno: errno) }
        var keepFD = false
        defer {
            if !keepFD {
                close(fd)
                unlink(tempPath)
            }
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Bind to a temporary name, restrict it, then rename into place: the socket is never
        // reachable with looser permissions, and no process-wide umask change is needed.
        guard Self.withAddress(tempPath, { bind(fd, $0, $1) }) == 0 else { throw .system(operation: "bind", errno: errno) }
        guard chmod(tempPath, 0o600) == 0 else { throw .system(operation: "chmod", errno: errno) }
        // A full accept queue refuses connections like a dead socket does (ECONNREFUSED), which
        // a client would report as "not running", so leave plenty of room.
        guard listen(fd, SOMAXCONN) == 0 else { throw .system(operation: "listen", errno: errno) }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw .system(operation: "fcntl", errno: errno) }
        guard rename(tempPath, socketPath) == 0 else { throw .system(operation: "rename", errno: errno) }
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { throw .system(operation: "stat", errno: errno) }
        keepFD = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        state.withLock {
            $0.listenFD = fd
            $0.acceptSource = source
            $0.socketNode = (info.st_dev, info.st_ino)
        }
        source.resume()
    }

    func stop() {
        let (source, node, open) = state.withLock { state in
            defer {
                state.listenFD = -1
                state.acceptSource = nil
                state.socketNode = nil
            }
            // Wake every connection thread; each cleans up its own connection.
            for connection in state.connections.values { connection.shutdown() }
            return (state.acceptSource, state.socketNode, state.listenFD >= 0)
        }
        guard open else { return }
        source?.cancel()
        var info = stat()
        if let node, lstat(socketPath, &info) == 0, info.st_dev == node.dev, info.st_ino == node.ino {
            unlink(socketPath)
        }
    }

    // MARK: Socket file helpers

    private static func preparePrivateDirectory(_ path: String) throws(BridgeServerError) {
        // Only the last component is created (the parent is the home directory, or a test root).
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw .system(operation: "mkdir \(path)", errno: errno) }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw .system(operation: "stat \(path)", errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw .insecureDirectory(path) }
        if info.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 { throw .system(operation: "chmod \(path)", errno: errno) }
    }

    /// Removes a socket nobody listens on; refuses to touch a live socket or a non-socket.
    private static func removeStaleSocket(_ path: String) throws(BridgeServerError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw .notASocket(path) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw .system(operation: "socket", errno: errno) }
        defer { close(probe) }
        if withAddress(path, { connect(probe, $0, $1) }) == 0 { throw .alreadyRunning(path) }
        guard unlink(path) == 0 || errno == ENOENT else { throw .system(operation: "unlink \(path)", errno: errno) }
    }

    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes.prefix(buffer.count - 1))
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    // MARK: Connections

    private func acceptPending(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return // EAGAIN: drained; other errors: try again on the next event.
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // Accepted sockets inherit O_NONBLOCK on macOS; connection threads want blocking I/O.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var writeTimeout = timeval(tv_sec: Self.writeTimeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))

            let connection: BridgeConnection? = state.withLock { state in
                guard state.listenFD >= 0, state.connections.count < maxConnections else { return nil }
                let id = state.nextConnectionID
                state.nextConnectionID += 1
                let connection = BridgeConnection(id: id, fd: fd)
                state.connections[id] = connection
                return connection
            }
            guard let connection else {
                Self.writeAll(fd, (try? BridgeWire.line(.reply(.failure(
                    id: BridgeReply.connectionErrorID, .busy, "AeroOps has too many agent connections open.")))) ?? Data())
                close(fd)
                emit(0, .rejected(reason: "too many connections"))
                continue
            }
            let thread = Thread { [self] in serve(connection) }
            thread.name = "AeroOps bridge connection \(connection.id)"
            thread.start()
        }
    }

    private func serve(_ connection: BridgeConnection) {
        defer {
            state.withLock { _ = $0.connections.removeValue(forKey: connection.id) }
            connection.close()
            emit(connection.id, .disconnected)
        }
        let peer: BridgePeer
        switch validator.validate(socket: connection.fd) {
        case .accepted(let accepted):
            peer = accepted
        case .rejected(let reason):
            emit(connection.id, .rejected(reason: reason))
            connection.send(.reply(.failure(id: BridgeReply.connectionErrorID, .peerRejected,
                                            "AeroOps refused the connection: \(reason).")))
            return
        }
        emit(connection.id, .connected(peer))

        var framer = LineFramer(maxLineBytes: BridgeLimits.maxRequestLineBytes)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        reading: while true {
            let count = buffer.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            for event in framer.append(Data(buffer[0..<count])) {
                switch event {
                case .line(let line):
                    guard handleLine(line, on: connection, peer: peer) else { break reading }
                case .oversized(let bytes):
                    let message = "A request line exceeded \(BridgeLimits.maxRequestLineBytes) bytes (\(bytes)+ bytes)."
                    emit(connection.id, .protocolError(message))
                    connection.send(.reply(.failure(id: BridgeReply.connectionErrorID, .malformedRequest, message)))
                    break reading
                }
            }
        }
    }

    /// Returns `false` when the connection must be closed.
    private func handleLine(_ line: Data, on connection: BridgeConnection, peer: BridgePeer) -> Bool {
        let message: BridgeClientMessage
        do {
            message = try BridgeWire.decodeClientMessage(line)
        } catch {
            emit(connection.id, .protocolError(error.reason))
            if let id = error.id, id > 0 {
                connection.send(.reply(.failure(id: id, .malformedRequest, "Malformed request: \(error.reason).")))
                return true
            }
            connection.send(.reply(.failure(id: BridgeReply.connectionErrorID, .malformedRequest,
                                            "Malformed line: \(error.reason).")))
            return false
        }
        switch message {
        case .cancel(let id):
            connection.cancel(id)
        case .request(let request):
            guard request.id > 0 else {
                emit(connection.id, .protocolError("request id \(request.id)"))
                connection.send(.reply(.failure(id: BridgeReply.connectionErrorID, .malformedRequest,
                                                "Request ids must be positive (got \(request.id)).")))
                return false
            }
            if let refusal = connection.start(request, peer: peer, handler: handler) {
                emit(connection.id, .protocolError(refusal.error?.message ?? "refused"))
                connection.send(.reply(refusal))
            }
        }
        return true
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// One accepted connection: its descriptor, its in-flight calls and its write queue.
final class BridgeConnection: Sendable {
    private struct State {
        /// In-flight calls by request id; `token` tells a reused id's new task from the old one.
        var tasks: [Int: (token: UInt64, task: Task<Void, Never>)] = [:]
        var nextToken: UInt64 = 1
        var closed = false
    }

    let id: UInt64
    let fd: Int32
    private let state = Mutex(State())
    private let writeQueue: DispatchQueue

    init(id: UInt64, fd: Int32) {
        self.id = id
        self.fd = fd
        writeQueue = DispatchQueue(label: "app.aeroops.bridge.connection-\(id).write")
    }

    var inFlightCount: Int { state.withLock { $0.tasks.count } }

    /// Starts a task for `request`, or returns the reply refusing it.
    func start(_ request: BridgeRequest, peer: BridgePeer, handler: any BridgeRequestHandler) -> BridgeReply? {
        state.withLock { state -> BridgeReply? in
            guard !state.closed else { return nil }
            if state.tasks[request.id] != nil {
                return .failure(id: request.id, .malformedRequest, "Request id \(request.id) is already in flight on this connection.")
            }
            guard state.tasks.count < BridgeLimits.maxConcurrentRequestsPerConnection else {
                return .failure(id: request.id, .busy,
                                "Too many calls in flight (at most \(BridgeLimits.maxConcurrentRequestsPerConnection) per connection).")
            }
            let token = state.nextToken
            state.nextToken += 1
            let requestID = request.id
            // The task cannot finish before it is registered: finishing takes this lock.
            let task = Task { [self] in
                let reply = await handler.handle(request, from: peer) { [weak self] message in
                    self?.progress(requestID, token: token, message)
                }
                finish(requestID, token: token, reply: reply)
            }
            state.tasks[requestID] = (token, task)
            return nil
        }
    }

    /// The agent cancelled `requestID`: cancel its task; it gets no reply.
    func cancel(_ requestID: Int) {
        state.withLock { $0.tasks.removeValue(forKey: requestID) }?.task.cancel()
    }

    private func isCurrent(_ requestID: Int, token: UInt64) -> Bool {
        state.withLock { !$0.closed && $0.tasks[requestID]?.token == token }
    }

    private func progress(_ requestID: Int, token: UInt64, _ message: String) {
        guard isCurrent(requestID, token: token) else { return }
        send(.progress(BridgeProgress(id: requestID, message: message)))
    }

    private func finish(_ requestID: Int, token: UInt64, reply: BridgeReply?) {
        let current = state.withLock { state -> Bool in
            guard state.tasks[requestID]?.token == token else { return false }
            state.tasks[requestID] = nil
            return !state.closed
        }
        guard current, var reply else { return }
        reply.id = requestID
        send(.reply(reply))
    }

    /// Queues a line; dropped once the connection is closed.
    func send(_ message: BridgeServerMessage) {
        var line: Data
        do {
            line = try BridgeWire.line(message)
        } catch {
            line = (try? BridgeWire.line(.reply(.failure(id: message.id, .internalError, "AeroOps could not encode the reply.")))) ?? Data()
        }
        if line.count > BridgeLimits.maxReplyLineBytes {
            line = (try? BridgeWire.line(.reply(.failure(id: message.id, .internalError,
                                                         "The reply exceeded \(BridgeLimits.maxReplyLineBytes) bytes.")))) ?? Data()
        }
        let data = line
        writeQueue.async { [self] in
            guard state.withLock({ !$0.closed }) || message.id == BridgeReply.connectionErrorID else { return }
            if !BridgeServerCore.writeAll(fd, data) { Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    /// Wakes the reader thread (server stop).
    func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    /// Cancels every in-flight call and closes the descriptor after queued writes.
    func close() {
        let tasks = state.withLock { state in
            state.closed = true
            defer { state.tasks.removeAll() }
            return state.tasks.values.map(\.task)
        }
        for task in tasks { task.cancel() }
        let fd = fd
        writeQueue.async { Darwin.close(fd) }
    }
}
