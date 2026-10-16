import AppKit
import Testing
@testable import TerminalKit

@Suite("Terminal session status")
struct TerminalSessionStatusTests {
    @Test("macOS line-editing keys map to readline keys")
    func lineEditingKeys() {
        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        #expect(LineEditingKeys.action(keyCode: 123, modifiers: arrow.union(.command)) == "text:\\x01")
        #expect(LineEditingKeys.action(keyCode: 124, modifiers: arrow.union(.command)) == "text:\\x05")
        #expect(LineEditingKeys.action(keyCode: 51, modifiers: .command) == "text:\\x15")
        #expect(LineEditingKeys.action(keyCode: 123, modifiers: arrow.union(.option)) == "esc:b")
        #expect(LineEditingKeys.action(keyCode: 124, modifiers: arrow.union(.option)) == "esc:f")
        #expect(LineEditingKeys.action(keyCode: 123, modifiers: arrow) == nil)
        #expect(LineEditingKeys.action(keyCode: 123, modifiers: [.command, .shift]) == nil)
        #expect(LineEditingKeys.action(keyCode: 123, modifiers: .control) == nil)
        #expect(LineEditingKeys.action(keyCode: 0, modifiers: .command) == nil)
    }

    @Test("Cmd-click opens only web links")
    func openableURL() {
        #expect(TerminalSession.openableURL("https://example.com/a?b=c") != nil)
        #expect(TerminalSession.openableURL("HTTP://EXAMPLE.COM") != nil)
        for link in [
            "file:///etc/passwd", "javascript:alert(1)", "https://", "ssh://host", "mailto:a@b.c",
            "x-apple.systempreferences:com.apple.preference.security", "/Applications/Calculator.app",
            "https://example.com/\u{1B}[2J",
        ] {
            #expect(TerminalSession.openableURL(link) == nil, "\(link)")
        }
    }

    @Test("notification texts lose control and bidi characters and are cut")
    func notificationTexts() {
        #expect(TerminalAlert.notification(sanitizingTitle: "\u{1B}build\n", body: "a\n\tb\u{202E}c")
            == .notification(title: "build", body: "a bc"))
        #expect(TerminalAlert.notification(sanitizingTitle: " \n", body: "\u{07}") == nil)
        let long = TerminalAlert.sanitized(String(repeating: "x", count: 1000), limit: TerminalAlert.maxBodyLength)
        #expect(long.count == TerminalAlert.maxBodyLength)
        #expect(long.hasSuffix("…"))
    }

    @Test("the scroll position is nil at the bottom")
    func scrollPosition() {
        #expect(TerminalScrollPosition(total: 100, offset: 76, visibleRows: 24) == nil)
        #expect(TerminalScrollPosition(total: 24, offset: 0, visibleRows: 24) == nil)
        #expect(TerminalScrollPosition(total: 100, offset: 50, visibleRows: 24)
            == TerminalScrollPosition(rowsBelow: 26, totalRows: 100))
        #expect(TerminalScrollPosition(total: 100, offset: .max, visibleRows: 24) == nil)
    }
}
