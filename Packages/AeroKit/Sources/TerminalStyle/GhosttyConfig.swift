import Foundation
package import GhosttyTerminal

/// Builds the libghostty configuration for one surface, the same for both apps' terminals:
/// TerminalKit's tabs on the Mac and EmbeddedTerminal's sessions on iOS.
///
/// Surfaces use the host-managed backend: the program runs on TerminalKit's own
/// pseudo-terminal, or on the other end of an EmbeddedSSH channel, so the config carries no
/// command. One `TerminalController` (one `ghostty_app_t`) per surface, freed with it.
package enum GhosttyConfig {
    /// The terminal type every host has (TerminalKit's `TerminalLaunchSpec.defaultTerm`).
    package static let defaultTerm = "xterm-256color"

    /// Decoded kitty graphics images one surface may hold per screen. libghostty's default
    /// (320 MB) is a standalone terminal's; here several surfaces can be live at once.
    package static let imageStorageLimit = 64 << 20

    /// `key = value` settings, in order, excluding colours (those go into the theme).
    ///
    /// - Parameter term: The program's `TERM`, which the terminal also names in its own answers
    ///   (XTGETTCAP).
    package static func settings(
        appearance: TerminalAppearance, term: String = defaultTerm
    ) -> [(key: String, value: String)] {
        var settings: [(String, String)] = []
        if let family = appearance.sanitizedFontFamily {
            settings.append(("font-family", family))
        }
        settings += [
            ("font-size", fontSizeLiteral(appearance.clampedFontSize)),
            ("cursor-style", "block"),
            ("cursor-style-blink", "true"),
            ("window-padding-x", "4"),
            ("window-padding-y", "4"),
            ("wait-after-command", "false"),
            ("abnormal-command-exit-runtime", "0"),
            ("term", term),
            ("shell-integration", "none"),
            ("desktop-notifications", "false"),
            ("image-storage-limit", String(imageStorageLimit)),
            ("clipboard-read", "deny"),
            ("clipboard-write", "allow"),
            ("clipboard-paste-protection", "true"),
            ("confirm-close-surface", "false"),
        ]
        settings += keybindSettings
        return settings
    }

    /// The surface's key bindings: libghostty's defaults are cleared, then only terminal-local
    /// ones come back.
    ///
    /// The defaults are a standalone terminal app's (Cmd+T new tab, Cmd+W close, Cmd+1...9 go
    /// to tab, Ctrl+Tab next tab, Cmd+Q quit, Cmd+N new window, ...). A focused surface takes
    /// every key that is a binding before the main menu sees it, and the session ignores the
    /// app-level actions, so those keys would either do nothing (Cmd+Q) or bypass the host
    /// app (Cmd+W closing a running tab without asking). Without them the keys reach the
    /// host app's menus.
    ///
    /// The macOS line-editing keys (Cmd+Left/Right, Cmd+Backspace, Option+Left/Right) are not
    /// bindings: a binding would send its bytes to every program, a full-screen one included.
    /// TerminalKit's session view sends them only to programs on the main screen (`LineEditingKeys`).
    package static let keybindings: [String] = [
        "super+c=copy_to_clipboard",
        "super+v=paste_from_clipboard",
        "super+a=select_all",
        "super+k=clear_screen",
        "super+equal=increase_font_size:1",
        "super+minus=decrease_font_size:1",
        "super+digit_0=reset_font_size",
        "super+home=scroll_to_top",
        "super+end=scroll_to_bottom",
        "super+page_up=scroll_page_up",
        "super+page_down=scroll_page_down",
        "super+arrow_up=jump_to_prompt:-1",
        "super+arrow_down=jump_to_prompt:1",
    ]

    private static var keybindSettings: [(key: String, value: String)] {
        [("keybind", "clear")] + keybindings.map { ("keybind", $0) }
    }

    package static func configuration(
        appearance: TerminalAppearance, term: String = defaultTerm
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            for (key, value) in settings(appearance: appearance, term: term) {
                builder.withCustom(key, value)
            }
        }
    }

    /// Same colours for light and dark so the OS appearance never changes the terminal.
    package static func theme(appearance: TerminalAppearance) -> TerminalTheme {
        let colors = TerminalConfiguration { builder in
            for (key, value) in appearance.colorSettings {
                builder.withCustom(key, value)
            }
        }
        return TerminalTheme(light: colors, dark: colors)
    }

    /// ghostty parses floats with `.` only, independent of the user's locale.
    package static func fontSizeLiteral(_ size: Float) -> String {
        let rounded = (size * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", Double(rounded))
    }
}
