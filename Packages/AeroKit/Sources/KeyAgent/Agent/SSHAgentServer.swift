import AeroCore
import Darwin
import Dispatch
import Foundation
import Synchronization

// The agent socket serves /usr/bin/ssh, which exists only on macOS.
#if os(macOS)

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

/// The agent's connection handling. Blocking I/O runs on one thread per connection
/// (``UnixSocketListener``), never on the Swift concurrency pool; each thread hands requests to
/// the async handler and waits for the reply.
final class AgentServerCore: Sendable {
    let handler: AgentRequestHandler
    let appProcessID: pid_t
    private let listener: UnixSocketListener
    private let continuation: AsyncStream<AgentEvent>.Continuation

    /// Idle connections are closed after this long without a request.
    static let idleTimeoutSeconds = 300
    static let writeTimeoutSeconds = 10

    init(socketPath: String, handler: AgentRequestHandler, appProcessID: pid_t, maxConnections: Int, continuation: AsyncStream<AgentEvent>.Continuation) {
        self.handler = handler
        self.appProcessID = appProcessID
        self.continuation = continuation
        listener = UnixSocketListener(
            socketPath: socketPath, name: "agent", maxConnections: maxConnections,
            readTimeoutSeconds: Self.idleTimeoutSeconds, writeTimeoutSeconds: Self.writeTimeoutSeconds)
    }

    var socketPath: String { listener.socketPath }
    var isRunning: Bool { listener.isRunning }

    func finishEvents() { continuation.finish() }

    private func emit(_ connectionID: UInt64, _ kind: AgentEvent.Kind) {
        continuation.yield(AgentEvent(connectionID: connectionID, kind: kind))
    }

    // MARK: Start and stop

    func start() throws(AgentServerError) {
        try listener.start(
            serve: { [weak self] fd, id in self?.serve(fd, id) },
            onOverflow: { [weak self] in self?.emit(0, .rejected(reason: "too many connections")) })
    }

    func stop() {
        listener.stop()
    }

    // MARK: Connections

    private func serve(_ fd: Int32, _ id: UInt64) {
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
#endif
