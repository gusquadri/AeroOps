import Foundation
import NIOCore
import NIOSSH

/// What one remote command's session channel reports, in order.
enum ExecEvent: Sendable {
    /// The server accepted the exec request.
    case started
    case stdout(ByteBuffer)
    case stderr(ByteBuffer)
    case exitStatus(Int)
    case exitSignal(String)
    /// The server refused the exec request.
    case refused
    case failed(any Error)
    /// The caller's deadline passed (sent by the client, not the channel).
    case timedOut
}

/// Runs one command in an SSH session channel: sends the exec request and stdin once the server
/// opens the channel, then reports output and the exit status to `events`.
///
/// The stream is finished when the channel closes, but only if it ever opened: a channel the
/// server never opens is reported through the `createChannel` promise instead, so the client can
/// retry it on a fresh connection with the same stream.
final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let stdin: Data?
    private let events: AsyncStream<ExecEvent>.Continuation
    private var opened = false

    init(command: String, stdin: Data?, events: AsyncStream<ExecEvent>.Continuation) {
        self.command = command
        self.stdin = stdin
        self.events = events
    }

    func channelActive(context: ChannelHandlerContext) {
        opened = true
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        let events = events
        context.triggerUserOutboundEvent(request).assumeIsolated().whenFailure { error in
            events.yield(.failed(error))
            context.close(promise: nil)
        }
        if let stdin, !stdin.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: stdin.count)
            buffer.writeBytes(stdin)
            context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        }
        context.close(mode: .output, promise: nil)
        context.flush()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        if message.type == .channel {
            events.yield(.stdout(buffer))
        } else if message.type == .stdErr {
            events.yield(.stderr(buffer))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            events.yield(.started)
        case is ChannelFailureEvent:
            events.yield(.refused)
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            events.yield(.exitStatus(status.exitStatus))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            events.yield(.exitSignal(signal.signalName))
        case let event as ChannelEvent where event == .inputClosed:
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if opened { events.yield(.failed(error)) }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if opened { events.finish() }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if opened { events.finish() }
    }
}
