import AppKit
internal import GhosttyTerminal

/// The macOS text-editing keys a shell's line editor does not know by themselves: Cmd+Left and
/// Cmd+Right (start and end of line), Cmd+Backspace (delete to the start of the line) and
/// Option+Left and Option+Right (word left and right).
///
/// They become the readline keys (Ctrl+A, Ctrl+E, Ctrl+U, Esc B, Esc F) only while the program
/// edits a line on the main screen (``TerminalProcess/usesLineEditingKeys``). A full-screen
/// program (vim, htop, tmux) or one that asked for every key as an escape code (kitty keyboard
/// flag 8) gets the keys themselves, as libghostty's key encoder reports them.
enum LineEditingKeys {
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let backspace: UInt16 = 51

    /// The libghostty binding action for a key press, `nil` when it is no line-editing key.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        let pressed = modifiers.intersection([.command, .option, .control, .shift])
        switch (pressed, keyCode) {
        case (.command, leftArrow): return "text:\\x01"
        case (.command, rightArrow): return "text:\\x05"
        case (.command, backspace): return "text:\\x15"
        case (.option, leftArrow): return "esc:b"
        case (.option, rightArrow): return "esc:f"
        default: return nil
        }
    }
}

/// The session's surface view: libghostty's, plus ``LineEditingKeys``.
final class SessionTerminalView: AppTerminalView {
    /// Whether the program edits a line on the main screen now; read on each key.
    var usesLineEditingKeys: () -> Bool = { false }

    override func keyDown(with event: NSEvent) {
        if performLineEditingKey(event) { return }
        super.keyDown(with: event)
    }

    /// Cmd chords come here before the menus and `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, performLineEditingKey(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func performLineEditingKey(_ event: NSEvent) -> Bool {
        guard let action = LineEditingKeys.action(keyCode: event.keyCode, modifiers: event.modifierFlags),
              !hasMarkedText(), usesLineEditingKeys()
        else { return false }
        return performBindingAction(action)
    }
}
