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
    /// Whether the connection under the channel still answers within `timeout`; when it does not,
    /// the channel ends.
    func isResponsive(within timeout: Duration) async -> Bool
}

extension EmbeddedSSHChannel: TerminalChannel {}

/// Where the surface's keys and size go: the channel, while one is attached. Keys typed while
/// one opens wait (up to ``pendingLimit``) and the latest size is applied when it opens; keys
/// typed between channels (after ``detach()``, before ``expectChannel()``) are dropped. A surface
/// keeps its link across reconnects, so each new shell gets the surface's size.
///
/// Called from libghostty's callbacks on the main thread and from the session's task.
final class TerminalLink: Sendable {
    /// Keys typed before the channel opened that are kept; a paste larger than this is cut.
    static let pendingLimit = 64 << 10

    private struct State {
        var channel: (any TerminalChannel)?
        var pending = Data()
        var size: PseudoTerminalSize
        var isWaiting = true
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
            guard !data.isEmpty else { return }
            if let channel = state.channel {
                channel.send(data)
            } else if state.isWaiting {
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

    /// A channel is opening: keep the keys typed until it is attached.
    func expectChannel() {
        state.withLock { $0.isWaiting = true }
    }

    /// Hands over the opened channel: sends the waiting keys, and the size if it changed since
    /// the channel was opened with `size`.
    func attach(_ channel: any TerminalChannel, openedWith size: PseudoTerminalSize) {
        state.withLock { state in
            state.channel = channel
            state.isWaiting = false
            if state.size != size { channel.resize(state.size) }
            if !state.pending.isEmpty {
                channel.send(state.pending)
                state.pending = Data()
            }
        }
    }

    /// Closes the channel, if any; keys are dropped until the next ``expectChannel()``.
    func detach() {
        let channel = state.withLock { state in
            state.isWaiting = false
            state.pending = Data()
            defer { state.channel = nil }
            return state.channel
        }
        channel?.close()
    }
}
