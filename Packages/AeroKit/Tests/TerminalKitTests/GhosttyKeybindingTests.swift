import Testing
@testable import TerminalKit

@Suite("Ghostty key bindings")
struct GhosttyKeybindingTests {
    private static let settings = GhosttyConfig.settings(appearance: .aero, command: "/usr/bin/true")

    @Test("defaults are cleared before the curated bindings")
    func clearedFirst() {
        let keybinds = Self.settings.filter { $0.key == "keybind" }.map(\.value)
        #expect(keybinds.first == "clear")
        #expect(Array(keybinds.dropFirst()) == GhosttyConfig.keybindings)
    }

    @Test("app-level shortcuts stay with the host app's menus")
    func noAppShortcuts() {
        let triggers = GhosttyConfig.keybindings.compactMap { $0.split(separator: "=").first.map(String.init) }
        let appShortcuts = ["super+t", "super+w", "super+q", "super+n", "super+1", "ctrl+tab", "ctrl+shift+tab"]
        for shortcut in appShortcuts {
            #expect(!triggers.contains(shortcut), "\(shortcut) must reach the menu")
        }
        #expect(triggers.contains("super+c"))
        #expect(triggers.contains("super+v"))
    }

    @Test("libghostty accepts the whole configuration")
    @MainActor
    func accepted() {
        // A rejected line (e.g. an unknown key name) fails the session instead of starting it.
        let spec = TerminalLaunchSpec(executable: "/usr/bin/true", title: "true")
        let session = TerminalSession(spec: spec, appearance: .aero)
        defer { session.close() }
        if case let .failed(message) = session.state {
            Issue.record("configuration rejected: \(message)")
        }
    }
}
