import Testing
@testable import TerminalKit

@Suite("Ghostty key bindings")
struct GhosttyKeybindingTests {
    private static let settings = GhosttyConfig.settings(appearance: .aero)

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

    @Test("line-editing keys are no bindings, prompt jumps are")
    func lineEditing() {
        let triggers = GhosttyConfig.keybindings.compactMap { $0.split(separator: "=").first.map(String.init) }
        for key in ["super+arrow_left", "super+arrow_right", "super+backspace", "alt+arrow_left", "alt+arrow_right"] {
            #expect(!triggers.contains(key), "\(key) must reach the key encoder")
        }
        #expect(GhosttyConfig.keybindings.contains("super+arrow_up=jump_to_prompt:-1"))
        #expect(GhosttyConfig.keybindings.contains("super+arrow_down=jump_to_prompt:1"))
    }

    @Test("the terminal type and the image limit reach libghostty")
    func termAndImages() {
        let settings = GhosttyConfig.settings(appearance: .aero, term: "xterm-ghostty")
        #expect(settings.contains { $0.key == "term" && $0.value == "xterm-ghostty" })
        #expect(settings.contains { $0.key == "image-storage-limit" && $0.value == String(GhosttyConfig.imageStorageLimit) })
        #expect(Self.settings.contains { $0.key == "term" && $0.value == TerminalLaunchSpec.defaultTerm })
    }

    @Test("libghostty accepts the whole configuration")
    @MainActor
    func accepted() {
        // A rejected line (e.g. an unknown key name) fails the session instead of starting it.
        for environment in [[:], ["TERM": "xterm-ghostty"]] {
            let spec = TerminalLaunchSpec(executable: "/usr/bin/true", environment: environment, title: "true")
            let session = TerminalSession(spec: spec, appearance: .aero)
            defer { session.close() }
            if case let .failed(message) = session.state {
                Issue.record("configuration rejected: \(message)")
            }
        }
    }
}
