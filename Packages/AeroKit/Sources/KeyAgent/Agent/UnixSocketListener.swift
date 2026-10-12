import Darwin
import Dispatch
import Foundation
import Synchronization

/// A private Unix socket that serves each connection on its own thread. Shared by the agent
/// (`agent.sock`) and the askpass server (`askpass.sock`).
///
/// - The directory is `0700` and the socket `0600`; a stale socket is replaced, a live one is not.
/// - Accepted sockets are blocking, `SO_NOSIGPIPE`, with read and write timeouts.
/// - ``stop()`` wakes every connection thread and removes the socket only if it is still ours.
final class UnixSocketListener: Sendable {
    /// Runs on the connection's own thread. The listener closes `fd` when it returns.
    typealias Serve = @Sendable (_ fd: Int32, _ connectionID: UInt64) -> Void

    private struct State {
        var listenFD: Int32 = -1
        var acceptSource: (any DispatchSourceRead)?
        /// device and inode of the socket file we created, so stop() never unlinks another's.
        var socketNode: (dev: dev_t, ino: ino_t)?
        var connections: [UInt64: Int32] = [:]
        var nextConnectionID: UInt64 = 1
    }

    let socketPath: String
    let maxConnections: Int
    let readTimeoutSeconds: Int
    let writeTimeoutSeconds: Int
    /// Names the temporary socket file and the connection threads.
    private let name: String
    private let state = Mutex(State())
    private let acceptQueue: DispatchQueue

    init(socketPath: String, name: String, maxConnections: Int, readTimeoutSeconds: Int, writeTimeoutSeconds: Int) {
        self.socketPath = socketPath
        self.name = name
        self.maxConnections = maxConnections
        self.readTimeoutSeconds = readTimeoutSeconds
        self.writeTimeoutSeconds = writeTimeoutSeconds
        acceptQueue = DispatchQueue(label: "app.aeroops.\(name).accept")
    }

    var isRunning: Bool { state.withLock { $0.listenFD >= 0 } }

    // MARK: Start and stop

    /// Creates the socket and starts accepting. Does nothing if already running.
    ///
    /// - Parameters:
    ///   - serve: Handles one connection.
    ///   - onOverflow: Called (on the accept queue) for each connection dropped because
    ///     `maxConnections` are open.
    func start(serve: @escaping Serve, onOverflow: @escaping @Sendable () -> Void) throws(AgentServerError) {
        guard !isRunning else { return }
        let directory = (socketPath as NSString).deletingLastPathComponent
        let tempPath = (directory as NSString).appendingPathComponent(".\(name)-\(String(UInt32.random(in: 0...UInt32.max), radix: 16)).tmp")
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
        source.setEventHandler { [weak self] in self?.acceptPending(fd, serve: serve, onOverflow: onOverflow) }
        source.setCancelHandler { close(fd) }
        state.withLock {
            $0.listenFD = fd
            $0.acceptSource = source
            $0.socketNode = (info.st_dev, info.st_ino)
        }
        source.resume()
    }

    /// Stops accepting, wakes open connections and removes the socket if it is still ours.
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

    private func acceptPending(_ listenFD: Int32, serve: @escaping Serve, onOverflow: @Sendable () -> Void) {
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
            var readTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
            var writeTimeout = timeval(tv_sec: writeTimeoutSeconds, tv_usec: 0)
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
                onOverflow()
                continue
            }
            let thread = Thread { [self] in
                defer {
                    state.withLock { _ = $0.connections.removeValue(forKey: id) }
                    close(fd)
                }
                serve(fd, id)
            }
            thread.name = "AeroOps \(name) connection \(id)"
            thread.start()
        }
    }
}
