import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SSHKit
import Synchronization

/// One authenticated SSH connection. Commands run in session channels on it, at most
/// ``maxSessions`` at a time (sshd's `MaxSessions` defaults to 10).
final class SSHConnection: Sendable {
    static let maxSessions = 8
    /// The generated ssh_config's `ConnectTimeout`.
    static let connectTimeout: TimeAmount = .seconds(8)
    /// From TCP connect to a successful login.
    static let handshakeTimeout: TimeAmount = .seconds(30)

    let channel: any Channel
    private let sessions = Mutex(0)

    /// Wraps a channel that already runs a logged-in `NIOSSHHandler` (tests use plain TCP ones).
    init(channel: any Channel) {
        self.channel = channel
    }

    var isActive: Bool { channel.isActive }

    func close() {
        channel.close(promise: nil)
    }

    /// Takes a session slot, if one is free. Give it back with ``release()``.
    func reserve() -> Bool {
        sessions.withLock { count in
            guard count < Self.maxSessions else { return false }
            count += 1
            return true
        }
    }

    func release() {
        sessions.withLock { $0 = max(0, $0 - 1) }
    }

    /// Connects and logs in. Throws NIO's and NIOSSH's errors as they are, and whatever the
    /// delegates fail with (classify them with ``EmbeddedSSHErrors/classify(_:)``).
    ///
    /// - Parameter delegates: Called on the connection's event loop; NIOSSH's delegates are not
    ///   `Sendable`, so they are made there.
    static func connect(
        address: String,
        port: Int,
        group: any EventLoopGroup,
        delegates: @escaping @Sendable () -> (any NIOSSHClientUserAuthenticationDelegate, any NIOSSHClientServerAuthenticationDelegate)
    ) async throws -> SSHConnection {
        let loop = group.next()
        let authenticated = loop.makePromise(of: Void.self)
        let deadline = loop.scheduleTask(in: handshakeTimeout) { authenticated.fail(SSHError.timeout) }
        defer { deadline.cancel() }
        // TCP keepalive stands in for ssh's `ServerAliveInterval 15` / `ServerAliveCountMax 3`:
        // NIOSSH cannot send OpenSSH's keepalive requests.
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPALIVE)), value: 15)
            .channelOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPINTVL)), value: 15)
            .channelOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPCNT)), value: 3)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let (userAuth, hostKey) = delegates()
                    let configuration = SSHClientConfiguration(userAuthDelegate: userAuth, serverAuthDelegate: hostKey)
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil))
                    try pipeline.addHandler(ConnectionHandler(authenticated: authenticated))
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: address, port: port).get()
        } catch {
            authenticated.fail(error)
            throw error
        }
        do {
            try await authenticated.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw error
        }
        return SSHConnection(channel: channel)
    }

    /// Opens a session channel that runs `command` and reports to `events` (see ``ExecHandler``).
    /// Returns once the server opened it; throws if it did not (refused, or the connection is
    /// gone). The session slot taken with ``reserve()`` is given back when the channel closes.
    func exec(_ command: String, stdin: Data?, events: AsyncStream<ExecEvent>.Continuation, control: ExecControl) async throws {
        _ = try await openSession(control: control) {
            ExecHandler(command: command, stdin: stdin, events: events)
        }
    }

    /// Opens a session channel driven by the handler `makeHandler` makes (on the channel's event
    /// loop: handlers are not `Sendable`). Returns once the server opened it; throws if it did not.
    /// The session slot taken with ``reserve()`` is given back when the channel closes.
    func openSession(control: ExecControl, makeHandler: @escaping @Sendable () -> any ChannelHandler) async throws -> any Channel {
        let opened = channel.eventLoop.makePromise(of: (any Channel).self)
        channel.eventLoop.execute { [channel] in
            do {
                let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                handler.createChannel(opened, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        // The exit status often arrives after the server's EOF; without half-closure
                        // NIOSSH would close the channel at the EOF and drop it.
                        try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        try child.pipeline.syncOperations.addHandler(makeHandler())
                        control.attach(child)
                    }
                }
            } catch {
                opened.fail(error)
            }
        }
        let child = try await opened.futureResult.get()
        child.closeFuture.whenComplete { _ in self.release() }
        return child
    }
}

/// Completes `authenticated` when NIOSSH reports a successful login, or fails it with the first
/// error. After login, an error closes the connection (the pool then drops it).
private final class ConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authenticated: EventLoopPromise<Void>

    init(authenticated: EventLoopPromise<Void>) {
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { authenticated.succeed() }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        authenticated.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated.fail(SSHError.connectionClosed)
        context.fireChannelInactive()
    }
}

/// Stops one command or session at whatever stage it is in: before its channel exists (it is
/// closed as soon as it does) or while it runs.
final class ExecControl: Sendable {
    private struct State {
        var child: (any Channel)?
        var connection: SSHConnection?
        var stopped = false
    }

    private let state = Mutex(State())

    var isStopped: Bool { state.withLock(\.stopped) }

    /// The connection the command runs on, once it has one.
    var connection: SSHConnection? {
        get { state.withLock(\.connection) }
        set { state.withLock { $0.connection = newValue } }
    }

    func attach(_ child: any Channel) {
        let stopped = state.withLock { state in
            state.child = child
            return state.stopped
        }
        if stopped { child.close(promise: nil) }
    }

    func stop() {
        let child = state.withLock { state in
            state.stopped = true
            return state.child
        }
        child?.close(promise: nil)
    }
}
