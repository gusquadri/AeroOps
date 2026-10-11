import Darwin
import Foundation
import Synchronization

/// One client connection to `bridge.sock`: blocking writes from the caller, and a dedicated
/// reader thread that frames and decodes the app's lines.
///
/// The reader owns the file descriptor's lifetime: ``close()`` only shuts the socket down, the
/// reader sees EOF, reports ``Event/closed(_:)`` and closes the descriptor. Writes and the close
/// share a lock, so a write never lands on a recycled descriptor number.
final class BridgeSocketConnection: Sendable {
    /// Something the reader saw.
    enum Event: Sendable {
        case message(BridgeServerMessage)
        /// A line that did not decode; `id` when at least that was readable.
        case malformed(id: Int?, reason: String)
        /// A line longer than ``BridgeLimits/maxReplyLineBytes`` was dropped.
        case oversized(bytes: Int)
        /// The app closed the connection (`nil`) or reading failed.
        case closed(String?)
    }

    /// Why `connect(2)` failed.
    enum ConnectError: Error, Sendable, Hashable {
        /// Nobody listens: the socket file is missing or stale (`ENOENT`, `ECONNREFUSED`), or the
        /// accept queue is full (`ECONNREFUSED` or `EAGAIN`, indistinguishable from stale).
        /// Worth retrying while the app starts.
        case noListener(String)
        /// Anything else (`EACCES`, `ENOTSOCK`, …). Retrying will not help.
        case failed(String)
    }

    /// The message for an id-0 reply without an error message.
    static let defaultRefusal = "AeroOps refused the connection."

    let path: String
    private let fd: Mutex<Int32?>
    /// The app's message when it refused this connection; set by the reader before it reports
    /// the id-0 reply, so it is known before the connection ends.
    private let refusal = Mutex<String?>(nil)
    private let stream: AsyncStream<Event>

    private init(fd: Int32, path: String) {
        self.path = path
        self.fd = Mutex(fd)
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.stream = stream
        let reader = Thread { [self] in
            readLoop(fd: fd, continuation: continuation)
        }
        reader.name = "bridge-reader"
        reader.start()
    }

    /// Connects to the socket at `path` and starts reading.
    static func connect(path: String) throws(ConnectError) -> BridgeSocketConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .failed("socket(): \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(fd)
            throw .failed("socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            let reason = "\(path): \(String(cString: strerror(code)))"
            switch code {
            case ENOENT, ECONNREFUSED, EAGAIN: throw .noListener(reason)
            default: throw .failed(reason)
            }
        }
        return BridgeSocketConnection(fd: fd, path: path)
    }

    /// The reader's events, in order. Call once.
    var events: AsyncStream<Event> { stream }

    /// How calls on this connection end when it closes without their reply: the app's refusal
    /// (an id-0 reply came first), else ``BridgeCallError/appQuit``.
    var endError: BridgeCallError {
        refusal.withLock { $0 }.map(BridgeCallError.refused) ?? .appQuit
    }

    /// Writes `data` completely. Throws when the connection is closed or broken.
    func send(_ data: Data) throws(BridgeCallError) {
        try fd.withLock { fd throws(BridgeCallError) in
            guard let fd else { throw .appQuit }
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) throws(BridgeCallError) in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw .appQuit
                    }
                    offset += written
                }
            }
        }
    }

    /// Shuts the connection down; the reader then reports ``Event/closed(_:)``.
    func close() {
        fd.withLock { fd in
            if let fd { _ = shutdown(fd, SHUT_RDWR) }
        }
    }

    private func readLoop(fd descriptor: Int32, continuation: AsyncStream<Event>.Continuation) {
        var framer = LineFramer(maxLineBytes: BridgeLimits.maxReplyLineBytes)
        let size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        var failure: String?
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, size) }
            if count < 0 {
                if errno == EINTR { continue }
                failure = String(cString: strerror(errno))
                break
            }
            if count == 0 { break }
            for event in framer.append(Data(buffer[0..<count])) {
                switch event {
                case .line(let line):
                    do {
                        report(try BridgeWire.decodeServerMessage(line), to: continuation)
                    } catch {
                        continuation.yield(.malformed(id: error.id, reason: error.reason))
                    }
                case .oversized(let bytes):
                    continuation.yield(.oversized(bytes: bytes))
                }
            }
        }
        if let line = framer.finish(), let message = try? BridgeWire.decodeServerMessage(line) {
            report(message, to: continuation)
        }
        fd.withLock { fd in
            if let open = fd {
                Darwin.close(open)
                fd = nil
            }
        }
        continuation.yield(.closed(failure))
        continuation.finish()
    }

    private func report(_ message: BridgeServerMessage, to continuation: AsyncStream<Event>.Continuation) {
        if case .reply(let reply) = message, reply.id == BridgeReply.connectionErrorID {
            let text = reply.error?.message ?? Self.defaultRefusal
            refusal.withLock { $0 = $0 ?? text }
        }
        continuation.yield(.message(message))
    }
}
