import AeroCore
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization
@testable import EmbeddedSSH
@testable import SSHKit

/// An in-process SSH server on 127.0.0.1 (NIOSSH's server role) that takes `dev` with
/// ``password`` and scripts its session channels, so EmbeddedSSH's sessions can be tested without
/// the dev servers:
///
/// - Subsystem `echo` sends back what it receives and exits 0 at EOF; `silent` never answers;
///   `sftp` runs the Mac's `/usr/libexec/sftp-server` in `sftpRoot`; any other is refused.
/// - `pty-req` and `window-change` are recorded in ``log``. `shell` prints `$ `, echoes what it
///   receives and exits 7 once it saw `exit\r`.
/// - `exec` writes `ran <command>` to stdout and `oops` to stderr, then exits 0.
final class TestSSHServer: Sendable {
    static let password = "correct horse"

    let hostKey: HostKey
    let log: ServerLog
    private let channel: any Channel
    private let accepted: AcceptedChannels

    init(sftpRoot: String? = nil) async throws {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let log = ServerLog()
        let accepted = AcceptedChannels()
        hostKey = try HostKey(nio: key.publicKey)
        self.log = log
        self.accepted = accepted
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                accepted.add(channel)
                return channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHServerConfiguration(hostKeys: [key], userAuthDelegate: PasswordChecker())
                    let handler = NIOSSHHandler(
                        role: .server(configuration), allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, _ in
                            child.eventLoop.makeCompletedFuture {
                                try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                                try child.pipeline.syncOperations.addHandler(ScriptedSession(log: log, sftpRoot: sftpRoot))
                            }
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    var port: Int { channel.localAddress?.port ?? 0 }

    /// A password host for this server, its password saved and host key pinned in `env`.
    func host(in env: TestEnvironment) async throws -> RemoteHost {
        let host = RemoteHost.test(address: "127.0.0.1", port: port, auth: .password)
        env.vault.setPasswordHosts([host.id])
        try env.vault.save(Self.password, for: host.id)
        try await env.hostKeys.trust(hostKey, for: host)
        return host
    }

    func close() async {
        try? await channel.close()
        for child in accepted.all { try? await child.close() }
    }

    /// Stops reading from the connections accepted so far, like a server behind a socket iOS left
    /// half-open: they stay up but nothing they are sent gets an answer. New connections work.
    func stopAnswering() async {
        for child in accepted.all { try? await child.setOption(ChannelOptions.autoRead, value: false) }
    }
}

private final class AcceptedChannels: Sendable {
    private let channels = Mutex<[any Channel]>([])

    var all: [any Channel] { channels.withLock { $0 } }

    func add(_ channel: any Channel) { channels.withLock { $0.append(channel) } }
}

/// What the server's sessions were asked for.
final class ServerLog: Sendable {
    struct Terminal: Equatable, Sendable {
        var term: String
        var size: PseudoTerminalSize
        var modes: [UInt8: UInt32]
    }

    private struct State {
        var terminals: [Terminal] = []
        var windowChanges: [PseudoTerminalSize] = []
        var commands: [String] = []
    }

    private let state = Mutex(State())

    var terminals: [Terminal] { state.withLock(\.terminals) }
    var windowChanges: [PseudoTerminalSize] { state.withLock(\.windowChanges) }
    var commands: [String] { state.withLock(\.commands) }

    fileprivate func record(_ terminal: Terminal) { state.withLock { $0.terminals.append(terminal) } }
    fileprivate func record(windowChange: PseudoTerminalSize) { state.withLock { $0.windowChanges.append(windowChange) } }
    fileprivate func record(command: String) { state.withLock { $0.commands.append(command) } }
}

private final class PasswordChecker: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        if case .password(let password) = request.request, request.username == "dev", password.password == TestSSHServer.password {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

private final class ScriptedSession: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private enum Mode {
        case idle, echo, shell
        case sftp(ChildProcess)
    }

    private let log: ServerLog
    private let sftpRoot: String?
    private var mode = Mode.idle
    private var typed = ""

    init(log: ServerLog, sftpRoot: String?) {
        self.log = log
        self.sftpRoot = sftpRoot
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.SubsystemRequest:
            switch request.subsystem {
            case "echo":
                mode = .echo
                reply(context, success: true)
            case "silent":
                break
            case "sftp" where sftpRoot != nil:
                reply(context, success: startSFTP(context))
            default:
                reply(context, success: false)
            }
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            let modes = Dictionary(uniqueKeysWithValues: request.terminalModes.modeMapping.map { ($0.key.rawValue, $0.value.rawValue) })
            log.record(ServerLog.Terminal(
                term: request.term,
                size: PseudoTerminalSize(
                    columns: request.terminalCharacterWidth, rows: request.terminalRowHeight,
                    pixelWidth: request.terminalPixelWidth, pixelHeight: request.terminalPixelHeight
                ),
                modes: modes
            ))
            reply(context, success: true)
        case is SSHChannelRequestEvent.ShellRequest:
            mode = .shell
            reply(context, success: true)
            write(context, "$ ")
        case let request as SSHChannelRequestEvent.ExecRequest:
            log.record(command: request.command)
            reply(context, success: true)
            write(context, "ran \(request.command)\r\n")
            write(context, "oops\r\n", type: .stdErr)
            exit(context, status: 0)
        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            log.record(windowChange: PseudoTerminalSize(
                columns: request.terminalCharacterWidth, rows: request.terminalRowHeight,
                pixelWidth: request.terminalPixelWidth, pixelHeight: request.terminalPixelHeight
            ))
        case let event as ChannelEvent where event == .inputClosed:
            switch mode {
            case .echo: exit(context, status: 0)
            case .sftp(let child): child.closeStdin()
            case .idle, .shell: break
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let buffer) = message.data else { return }
        switch mode {
        case .echo:
            context.writeAndFlush(wrapOutboundOut(message), promise: nil)
        case .shell:
            context.writeAndFlush(wrapOutboundOut(message), promise: nil)
            typed += String(decoding: buffer.readableBytesView, as: UTF8.self)
            if typed.contains("exit\r") { exit(context, status: 7) }
        case .sftp(let child):
            child.write(Data(buffer.readableBytesView))
        case .idle:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if case .sftp(let child) = mode { child.terminate() }
        context.fireChannelInactive()
    }

    private func startSFTP(_ context: ChannelHandlerContext) -> Bool {
        guard let sftpRoot else { return false }
        let channel = context.channel
        let spec = ChildSpec(
            executable: "/usr/libexec/sftp-server",
            arguments: ["-d", sftpRoot],
            environment: [:],
            stdin: nil,
            interactiveStdin: true,
            timeout: nil,
            outputLimit: 1 << 16
        )
        do {
            let child = try ChildProcess.launch(spec, mode: .stream { data in
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data))), promise: nil)
            }) { _ in
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
                channel.close(promise: nil)
            }
            mode = .sftp(child)
            return true
        } catch {
            return false
        }
    }

    private func reply(_ context: ChannelHandlerContext, success: Bool) {
        if success {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        } else {
            context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
        }
    }

    private func write(_ context: ChannelHandlerContext, _ text: String, type: SSHChannelData.DataType = .channel) {
        let data = SSHChannelData(type: type, data: .byteBuffer(ByteBuffer(string: text)))
        context.writeAndFlush(wrapOutboundOut(data), promise: nil)
    }

    private func exit(_ context: ChannelHandlerContext, status: Int) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: status), promise: nil)
        context.close(promise: nil)
    }
}
