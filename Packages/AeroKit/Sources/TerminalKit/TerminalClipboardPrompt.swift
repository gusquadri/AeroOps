import Foundation
internal import GhosttyTerminal

/// A clipboard operation that needs the user's decision, typically pasting text that would
/// run commands immediately (multi-line text into a shell without bracketed paste).
///
/// Exactly one of ``allow()`` / ``deny()`` takes effect; dropping the prompt denies it.
@MainActor
public final class TerminalClipboardPrompt: Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Pasting from the clipboard into the terminal.
        case paste
        /// The remote program asks to read the clipboard (OSC 52).
        case remoteRead
        /// The remote program asks to write the clipboard (OSC 52).
        case remoteWrite
    }

    public nonisolated let id = UUID()
    public let kind: Kind
    /// The text that would be pasted or written.
    public let contents: String

    private var request: TerminalClipboardConfirmationRequest?
    private let onFinish: (TerminalClipboardPrompt) -> Void

    init(request: TerminalClipboardConfirmationRequest, onFinish: @escaping (TerminalClipboardPrompt) -> Void) {
        self.request = request
        self.onFinish = onFinish
        contents = request.contents
        kind = switch request.kind {
        case .paste: .paste
        case .osc52Read: .remoteRead
        case .osc52Write: .remoteWrite
        }
    }

    public func allow() {
        respond(true)
    }

    public func deny() {
        respond(false)
    }

    private func respond(_ allow: Bool) {
        guard let request else { return }
        self.request = nil
        request.respond(allow: allow)
        onFinish(self)
    }
}
