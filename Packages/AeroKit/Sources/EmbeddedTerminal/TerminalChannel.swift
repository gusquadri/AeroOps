import EmbeddedSSH
import Foundation
import SSHKit
import Synchronization

/// The byte channel an ``EmbeddedTerminalSession`` runs over: an ``EmbeddedSSHChannel`` from
/// ``EmbeddedSSHClient/openTerminal(on:term:size:command:timeout:)``, or a stand-in for previews.
public protocol TerminalChannel: RemoteByteChannel {
    /// Tells the remote side the terminal's new size.
    func resize(_ size: PseudoTerminalSize)
    /// The remote program's exit status, once it ended with one.
    var exitStatus: Int32? { get }
}

extension EmbeddedSSHChannel: TerminalChannel {}

/// Where the surface's keys and size go: the channel, once it is open. Keys typed while it
/// opens wait (up to ``pendingLimit``) and the latest size is applied when it opens.
///
/// Called from libghostty's callbacks on the main thread and from the session's task.
final class TerminalLink: Sendable {
    /// Keys typed before the channel opened that are kept; a paste larger than this is cut.
    static let pendingLimit = 64 << 10

    private struct State {
        var channel: (any TerminalChannel)?
        var pending = Data()
        var size: PseudoTerminalSize
        var isClosed = false
    }

    private let state: Mutex<State>

    init(size: PseudoTerminalSize) {
        state = Mutex(State(size: size))
    }

    /// The surface's latest size.
    var size: PseudoTerminalSize {
        state.withLock(\.size)
    }

    func write(_ data: Data) {
        state.withLock { state in
            guard !state.isClosed, !data.isEmpty else { return }
            if let channel = state.channel {
                channel.send(data)
            } else {
                state.pending.append(data.prefix(max(0, Self.pendingLimit - state.pending.count)))
            }
        }
    }

    func resize(_ size: PseudoTerminalSize) {
        state.withLock { state in
            guard size != state.size else { return }
            state.size = size
            state.channel?.resize(size)
        }
    }

    /// Hands over the opened channel: sends the waiting keys, and the size if it changed since
    /// the channel was opened with `size`. A closed link closes the channel instead.
    func attach(_ channel: any TerminalChannel, openedWith size: PseudoTerminalSize) {
        let attached = state.withLock { state in
            guard !state.isClosed else { return false }
            state.channel = channel
            if state.size != size { channel.resize(state.size) }
            if !state.pending.isEmpty {
                channel.send(state.pending)
                state.pending = Data()
            }
            return true
        }
        if !attached { channel.close() }
    }

    /// Closes the channel; later keys are dropped.
    func close() {
        let channel = state.withLock { state in
            state.isClosed = true
            state.pending = Data()
            defer { state.channel = nil }
            return state.channel
        }
        channel?.close()
    }
}
