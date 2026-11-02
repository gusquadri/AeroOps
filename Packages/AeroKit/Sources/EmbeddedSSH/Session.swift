import AeroCore
import Foundation
import NIOCore
import NIOSSH
import SSHKit
import Synchronization

/// A terminal's size, for the server's pseudo-terminal: columns and rows, and the size in pixels
/// when the view knows it (0 otherwise).
public struct PseudoTerminalSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Within what the SSH wire format carries; NIOSSH traps on a negative or oversized value.
    var clamped: PseudoTerminalSize {
        func clamp(_ value: Int) -> Int { min(max(value, 0), Int(UInt16.max)) }
        return PseudoTerminalSize(
            columns: clamp(columns), rows: clamp(rows), pixelWidth: clamp(pixelWidth), pixelHeight: clamp(pixelHeight)
        )
    }
}

/// A long-lived session on one of an ``EmbeddedSSHClient``'s connections: the `sftp` subsystem
/// for ``SSHKit/SFTPClient`` (``EmbeddedSSHClient/openSubsystem(_:on:timeout:)``), or a shell in a
/// pseudo-terminal for a terminal view (``EmbeddedSSHClient/openTerminal(on:term:size:command:timeout:)``).
///
/// Bytes from the remote side arrive on ``incoming`` in order; ``send(_:)`` queues bytes for it.
/// The session ends with ``close()``, when the remote program exits, or when its connection
/// closes (``EmbeddedSSHClient/disconnect(_:)``, ``EmbeddedSSHClient/disconnectAll()``, a failed
/// ``isResponsive(within:)``).
/// Dropping ``incoming`` closes it too.
public final class EmbeddedSSHChannel: RemoteByteChannel {
    private let child: any Channel
    private let state: SessionState

    init(child: any Channel, state: SessionState) {
        self.child = child
        self.state = state
        state.onTermination { child.close(promise: nil) }
    }

    /// Everything the remote side wrote, in order; for a terminal, stdout and stderr both. Unbounded:
    /// the consumer is expected to keep up.
    public var incoming: AsyncStream<Data> { state.incoming }

    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data))), promise: nil)
    }

    public func closeInput() {
        child.close(mode: .output, promise: nil)
    }

    public func close() {
        child.close(promise: nil)
    }

    /// Tells the server the terminal's new size (a terminal session only; the shell gets `SIGWINCH`).
    public func resize(_ size: PseudoTerminalSize) {
        let size = size.clamped
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: size.pixelWidth, terminalPixelHeight: size.pixelHeight
        )
        child.triggerUserOutboundEvent(request, promise: nil)
    }

    /// The remote program's exit status (`128 + signo` when a signal killed it), once it reported one.
    public var exitStatus: Int32? { state.exitStatus }

    public func waitForEnd() async -> SSHError? {
        await state.waitForEnd()
    }

    /// Whether the session's connection still answers within `timeout`. One that does not is
    /// closed, which ends every session on it, so the next one connects afresh.
    public func isResponsive(within timeout: Duration) async -> Bool {
        guard let connection = child.parent else { return false }
        let answered = await connection.answersPing(within: timeout)
        if !answered { connection.close(promise: nil) }
        return answered
    }
}

extension SFTPClient {
    /// Opens the `sftp` subsystem on `host` over the in-process client (iOS) and completes the
    /// version handshake, with the errors of ``SSHKit/SFTPClient/connect(using:to:timeout:)``.
    ///
    /// - Throws: ``SSHKit/SSHError`` before connecting (an invalid or blocked host);
    ///   ``SSHKit/SFTPError/disconnected(_:)`` when the session does not start (unknown host key,
    ///   auth, no `sftp` subsystem) or the handshake does not finish within `timeout`.
    public static func connect(
        using client: EmbeddedSSHClient,
        to host: RemoteHost,
        timeout: Duration = .seconds(30)
    ) async throws -> SFTPClient {
        try EmbeddedSSHClient.validate(host)
        if await client.hostKeys.isBlocked(host) { throw SSHError.hostKeyChanged }
        let channel: EmbeddedSSHChannel
        do {
            channel = try await client.openSubsystem("sftp", on: host, timeout: timeout)
        } catch let error as SSHError {
            throw SFTPError.disconnected(error)
        }
        return try await connect(channel: channel, timeout: timeout)
    }
}

/// What a session channel asks the server for once it opens, in order. Each wants a reply; the
/// session starts when every one succeeded.
enum SessionRequest: Sendable {
    case subsystem(String)
    case pseudoTerminal(term: String, size: PseudoTerminalSize)
    case shell
    case exec(String)

    /// Erase is DEL (what terminals send for backspace) and input is UTF-8, so line editing
    /// deletes whole characters. The server's defaults stand for everything else.
    static let terminalModes = SSHTerminalModes([.VERASE: 127, SSHTerminalModes.Opcode(rawValue: 42): 1])

    /// Why the session failed when the server refuses this request.
    var refusal: String {
        switch self {
        case .subsystem(let name): "The server has no “\(name)” subsystem."
        case .pseudoTerminal: "The server refused a terminal."
        case .shell: "The server refused to start a shell."
        case .exec: "The server refused to run the command."
        }
    }

    func send(_ context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        switch self {
        case .subsystem(let name):
            return context.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true))
        case .pseudoTerminal(let term, let size):
            let size = size.clamped
            return context.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: term,
                terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
                terminalPixelWidth: size.pixelWidth, terminalPixelHeight: size.pixelHeight,
                terminalModes: Self.terminalModes
            ))
        case .shell:
            return context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
        case .exec(let command):
            return context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
        }
    }
}

/// Drives a long-lived session channel: sends its ``SessionRequest``s once the server opens it,
/// starts the session when they all succeeded, then passes the output and exit status to `state`.
///
/// Like ``ExecHandler``, it reports nothing for a channel the server never opens: that failure
/// reaches the `createChannel` promise, so the client can retry on a fresh connection.
final class SessionHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let requests: [SessionRequest]
    private let mergesStandardError: Bool
    private let state: SessionState
    private var awaitingReplies: ArraySlice<SessionRequest> = []
    private var opened = false

    /// - Parameter mergesStandardError: Whether stderr goes to ``SessionState/incoming`` too (a
    ///   terminal shows both); otherwise it is dropped.
    init(requests: [SessionRequest], mergesStandardError: Bool, state: SessionState) {
        self.requests = requests
        self.mergesStandardError = mergesStandardError
        self.state = state
    }

    func channelActive(context: ChannelHandlerContext) {
        opened = true
        awaitingReplies = requests[...]
        let state = state
        for request in requests {
            request.send(context).assumeIsolated().whenFailure { error in
                state.fail(error)
                context.close(promise: nil)
            }
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        if message.type == .channel || (mergesStandardError && message.type == .stdErr) {
            state.receive(buffer)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            guard !awaitingReplies.isEmpty else { return }
            awaitingReplies.removeFirst()
            if awaitingReplies.isEmpty { state.started(context.channel) }
        case is ChannelFailureEvent:
            guard let request = awaitingReplies.first else { return }
            state.fail(SSHError.other(request.refusal))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            state.exited(Int32(truncatingIfNeeded: status.exitStatus))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            state.exited(EmbeddedSSHErrors.exitCode(forSignal: signal.signalName))
        case let event as ChannelEvent where event == .inputClosed:
            // The server's EOF. The exit status usually follows it.
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if opened { state.fail(error) }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if opened { state.end() }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if opened { state.end() }
    }
}

/// One session's progress, reported by its ``SessionHandler`` on the event loop and read by the
/// client and the ``EmbeddedSSHChannel`` from any thread.
final class SessionState: Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    private struct State {
        var start: Result<any Channel, any Error>?
        var startWaiters: [CheckedContinuation<any Channel, any Error>] = []
        var failure: SSHError?
        var exitStatus: Int32?
        var ended = false
        var endWaiters: [CheckedContinuation<SSHError?, Never>] = []

        /// Why the session ended: its first failure, else a closed connection unless the remote
        /// program reported how it exited.
        var endReason: SSHError? {
            failure ?? (exitStatus == nil ? .connectionClosed : nil)
        }
    }

    private let state = Mutex(State())

    init() {
        (incoming, continuation) = AsyncStream<Data>.makeStream()
    }

    var exitStatus: Int32? {
        state.withLock(\.exitStatus)
    }

    func onTermination(_ action: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in action() }
    }

    func receive(_ buffer: ByteBuffer) {
        continuation.yield(Data(buffer.readableBytesView))
    }

    /// The server granted every request: ``waitForStart()`` returns `channel`.
    func started(_ channel: any Channel) {
        let waiters = state.withLock { state -> [CheckedContinuation<any Channel, any Error>] in
            guard state.start == nil else { return [] }
            state.start = .success(channel)
            defer { state.startWaiters = [] }
            return state.startWaiters
        }
        for waiter in waiters { waiter.resume(returning: channel) }
    }

    /// Records the first failure (classified like a command's), and fails a session that has not
    /// started yet with it.
    func fail(_ error: any Error) {
        let error = EmbeddedSSHErrors.classify(error)
        let waiters = state.withLock { state -> [CheckedContinuation<any Channel, any Error>] in
            if state.failure == nil, !state.ended { state.failure = error as? SSHError }
            guard state.start == nil else { return [] }
            state.start = .failure(error)
            defer { state.startWaiters = [] }
            return state.startWaiters
        }
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    /// Fails the session with `error` if it has not started yet (a timeout, a cancelled caller);
    /// returns whether it did, in which case the caller closes the channel.
    func abandonStart(_ error: any Error) -> Bool {
        let (abandoned, waiters) = state.withLock { state -> (Bool, [CheckedContinuation<any Channel, any Error>]) in
            guard state.start == nil else { return (false, []) }
            state.start = .failure(error)
            if state.failure == nil { state.failure = error as? SSHError }
            defer { state.startWaiters = [] }
            return (true, state.startWaiters)
        }
        for waiter in waiters { waiter.resume(throwing: error) }
        return abandoned
    }

    func exited(_ status: Int32) {
        state.withLock { $0.exitStatus = $0.exitStatus ?? status }
    }

    /// The channel closed: ``incoming`` finishes and ``waitForEnd()`` returns.
    func end() {
        continuation.finish()
        let (startWaiters, endWaiters, reason) = state.withLock { state in
            guard !state.ended else { return ([CheckedContinuation<any Channel, any Error>](), [CheckedContinuation<SSHError?, Never>](), SSHError?.none) }
            state.ended = true
            let reason = state.endReason
            var startWaiters: [CheckedContinuation<any Channel, any Error>] = []
            if state.start == nil {
                state.start = .failure(reason ?? .connectionClosed)
                startWaiters = state.startWaiters
                state.startWaiters = []
            }
            defer { state.endWaiters = [] }
            return (startWaiters, state.endWaiters, reason)
        }
        for waiter in startWaiters { waiter.resume(throwing: reason ?? .connectionClosed) }
        for waiter in endWaiters { waiter.resume(returning: reason) }
    }

    /// The session's channel once the server granted every request; throws what kept it from starting.
    func waitForStart() async throws -> any Channel {
        try await withCheckedThrowingContinuation { continuation in
            let start = state.withLock { state in
                if state.start == nil { state.startWaiters.append(continuation) }
                return state.start
            }
            if let start { continuation.resume(with: start) }
        }
    }

    func waitForEnd() async -> SSHError? {
        await withCheckedContinuation { continuation in
            let reason = state.withLock { state -> SSHError?? in
                guard state.ended else {
                    state.endWaiters.append(continuation)
                    return .none
                }
                return .some(state.endReason)
            }
            if let reason { continuation.resume(returning: reason) }
        }
    }
}
