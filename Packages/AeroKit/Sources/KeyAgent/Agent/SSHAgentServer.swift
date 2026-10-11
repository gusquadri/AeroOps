import AeroCore
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Why the agent socket could not be started.
public enum AgentServerError: Error, Equatable, Sendable, LocalizedError {
    /// `sun_path` holds at most 103 bytes plus the terminating NUL.
    case socketPathTooLong(String)
    /// The socket's directory is not a directory owned by this user.
    case insecureDirectory(String)
    /// Another process is accepting connections on the socket.
    case alreadyRunning(String)
    /// Something other than a socket is at the socket path; it is left alone.
    case notASocket(String)
    case system(operation: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path): "The agent socket path is too long: \(path)"
        case .insecureDirectory(let path): "\(path) must be a directory owned by you."
        case .alreadyRunning(let path): "Another agent is already listening on \(path)."
        case .notASocket(let path): "\(path) exists and is not a socket."
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// The in-app ssh-agent on a Unix socket (`~/.aeroops/agent.sock` by default).
///
/// - The directory is `0700` and the socket `0600`; a stale socket is replaced, a live one is not.
/// - Connections from other users are dropped. Every connection's peer is identified
///   (``PeerIdentity``) and reported on ``events``.
/// - Each `SIGN_REQUEST` goes through the ``SigningAuthorizer``.
///
/// ```swift
/// let server = SSHAgentServer(keyStore: store, authorizer: PolicySigningAuthorizer.localAuthentication())
/// try await server.start()
/// for await event in server.events { log(event) }
/// ```
public actor SSHAgentServer {
    public nonisolated let socketURL: URL
    /// Connection, request and signing events. Buffers the newest 256 if nobody listens.
    public nonisolated let events: AsyncStream<AgentEvent>

    private let core: AgentServerCore

    public init(
        socketURL: URL = AeroPaths.standard.agentSocket,
        keyStore: KeyStore,
        authorizer: any SigningAuthorizer,
        appProcessID: pid_t = getpid(),
        maxConnections: Int = 64
    ) {
        self.socketURL = socketURL
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .bufferingNewest(256))
        events = stream
        core = AgentServerCore(
            socketPath: socketURL.path, handler: AgentRequestHandler(keyStore: keyStore, authorizer: authorizer),
            appProcessID: appProcessID, maxConnections: maxConnections, continuation: continuation)
    }

    deinit {
        core.stop()
        core.finishEvents()
    }

    public var isRunning: Bool { core.isRunning }

    /// Creates the socket and starts accepting connections. Does nothing if already running.
    public func start() throws(AgentServerError) {
        try core.start()
    }

    /// Stops accepting, closes open connections and removes the socket if it is still ours.
    public func stop() {
        core.stop()
    }
}

/// The socket machinery. Blocking I/O runs on one thread per connection, never on the Swift
/// concurrency pool; each thread hands requests to the async handler and waits for the reply.
final class AgentServerCore: Sendable {
    private struct State {
        var listenFD: Int32 = -1
        var acceptSource: (any DispatchSourceRead)?
        /// device and inode of the socket file we created, so stop() never unlinks another's.
        var socketNode: (dev: dev_t, ino: ino_t)?
        var connections: [UInt64: Int32] = [:]
        var nextConnectionID: UInt64 = 1
    }

    let socketPath: String
    let handler: AgentRequestHandler
    let appProcessID: pid_t
    let maxConnections: Int
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let state = Mutex(State())
    private let acceptQueue = DispatchQueue(label: "app.aeroops.agent.accept")

    /// Idle connections are closed after this long without a request.
    static let idleTimeoutSeconds = 300
    static let writeTimeoutSeconds = 10

    init(socketPath: String, handler: AgentRequestHandler, appProcessID: pid_t, maxConnections: Int, continuation: AsyncStream<AgentEvent>.Continuation) {
        self.socketPath = socketPath
        self.handler = handler
        self.appProcessID = appProcessID
        self.maxConnections = maxConnections
        self.continuation = continuation
    }

    var isRunning: Bool { state.withLock { $0.listenFD >= 0 } }

    func finishEvents() { continuation.finish() }

    private func emit(_ connectionID: UInt64, _ kind: AgentEvent.Kind) {
        continuation.yield(AgentEvent(connectionID: connectionID, kind: kind))
    }

    // MARK: Start and stop

    func start() throws(AgentServerError) {
        guard !isRunning else { return }
        let directory = (socketPath as NSString).deletingLastPathComponent
        let tempPath = (directory as NSString).appendingPathComponent(".agent-\(String(UInt32.random(in: 0...UInt32.max), radix: 16)).tmp")
        for path in [socketPath, tempPath] where path.utf8.count >= MemoryLayout.size(ofValue: sockaddr_un().sun_path) {
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
        guard listen(fd, 16) == 0 else { throw .system(operation: "listen", errno: errno) }
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
            // Wake every connection thread; each closes its own descriptor.
            for fd in state.connections.values { shutdown(fd, SHUT_RDWR) }
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

    private static func preparePrivateDirectory(_ path: String) throws(AgentServerError) {
        // Only the last component is created (the parent is the home directory, or a test root).
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw .system(operation: "mkdir \(path)", errno: errno) }
        var info = stat()
        guard stat(path, &info) == 0 else { throw .system(operation: "stat \(path)", errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw .insecureDirectory(path) }
        if info.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 { throw .system(operation: "chmod \(path)", errno: errno) }
    }

    /// Removes a socket nobody listens on; refuses to touch a live socket or a non-socket.
    private static func removeStaleSocket(_ path: String) throws(AgentServerError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw .notASocket(path) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw .system(operation: "socket", errno: errno) }
        defer { close(probe) }
        if withAddress(path, { connect(probe, $0, $1) }) == 0 { throw .alreadyRunning(path) }
        guard unlink(path) == 0 || errno == ENOENT else { throw .system(operation: "unlink \(path)", errno: errno) }
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
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
            var readTimeout = timeval(tv_sec: Self.idleTimeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
            var writeTimeout = timeval(tv_sec: Self.writeTimeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))

            let id: UInt64? = state.withLock { state in
                guard state.listenFD >= 0, state.connections.count < maxConnections else { return nil }
                let id = state.nextConnectionID
                state.nextConnectionID += 1
                state.connections[id] = fd
                return id
            }
            guard let id else {
                close(fd)
                emit(0, .rejected(reason: "too many connections"))
                continue
            }
            let thread = Thread { [self] in serve(fd, id) }
            thread.name = "AeroOps agent connection \(id)"
            thread.start()
        }
    }

    private func serve(_ fd: Int32, _ id: UInt64) {
        defer {
            state.withLock { _ = $0.connections.removeValue(forKey: id) }
            close(fd)
        }
        guard let uid = PeerInspector.peerUID(fd), uid == getuid() else {
            emit(id, .rejected(reason: "peer belongs to another user"))
            return
        }
        guard let peer = PeerInspector.inspect(fd, appProcessID: appProcessID) else {
            emit(id, .rejected(reason: "peer could not be identified"))
            return
        }
        emit(id, .connected(peer))
        var connection = AgentConnectionState(connectionID: id, peer: peer)
        while let message = Self.readFrame(fd) {
            let handler = handler
            let current = connection
            let (reply, events, updated) = Self.runBlocking {
                var state = current
                let (reply, events) = await handler.handle(message, state: &state)
                return (reply, events, state)
            }
            connection = updated
            for event in events { emit(id, event) }
            guard Self.writeAll(fd, SSHWriter.frame(reply)) else { break }
        }
        emit(id, .disconnected)
    }

    /// One frame's payload; `nil` on EOF, timeout, error or an oversized length.
    static func readFrame(_ fd: Int32) -> [UInt8]? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= AgentMessage.maxLength else { return nil }
        return readExactly(fd, length)
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n > 0 {
                offset += n
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return buffer
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 {
                offset += n
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Runs async work from a connection thread and waits for it. Never call on the concurrency pool.
    private static func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox<T>()
        Task {
            result.set(await operation())
            done.signal()
        }
        done.wait()
        return result.take()
    }

    private final class ResultBox<T: Sendable>: Sendable {
        private let value = Mutex<T?>(nil)
        func set(_ newValue: T) { value.withLock { $0 = newValue } }
        func take() -> T { value.withLock { $0! } }
    }
}
