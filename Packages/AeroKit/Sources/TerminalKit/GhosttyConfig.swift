import Foundation
internal import GhosttyTerminal

/// Builds the libghostty configuration for one session's surface.
///
/// Surfaces use the host-managed backend: the program runs on TerminalKit's own
/// pseudo-terminal (``TerminalProcess``), so the config carries no command. One
/// `TerminalController` (one `ghostty_app_t`) per surface, freed with it when the session is
/// suspended.
enum GhosttyConfig {
    /// `key = value` settings, in order, excluding colours (those go into the theme).
    static func settings(appearance: TerminalAppearance) -> [(key: String, value: String)] {
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
            // Report the exit (close callback) as soon as the program ends ...
            ("wait-after-command", "false"),
            // ... even when it fails fast (ssh to a closed port exits 255 within milliseconds).
            ("abnormal-command-exit-runtime", "0"),
            // Remote hosts rarely have xterm-ghostty terminfo. TerminalProcess sets the same
            // TERM; this keeps the terminal's own answers consistent with it.
            ("term", "xterm-256color"),
            ("shell-integration", "none"),
            // Remote OSC 9/777 notifications are not surfaced (yet).
            ("desktop-notifications", "false"),
            // Remote programs may set the clipboard (vim/tmux yank) but never read it.
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
    static let keybindings: [String] = [
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
        // Line editing as in Terminal.app: start / end of line, delete line, word left / right.
        "super+arrow_left=text:\\x01",
        "super+arrow_right=text:\\x05",
        "super+backspace=text:\\x15",
        "alt+arrow_left=esc:b",
        "alt+arrow_right=esc:f",
    ]

    private static var keybindSettings: [(key: String, value: String)] {
        [("keybind", "clear")] + keybindings.map { ("keybind", $0) }
    }

    static func configuration(appearance: TerminalAppearance) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            for (key, value) in settings(appearance: appearance) {
                builder.withCustom(key, value)
            }
        }
    }

    /// Same colours for light and dark so the OS appearance never changes the terminal.
    static func theme(appearance: TerminalAppearance) -> TerminalTheme {
        let colors = TerminalConfiguration { builder in
            for (key, value) in appearance.colorSettings {
                builder.withCustom(key, value)
            }
        }
        return TerminalTheme(light: colors, dark: colors)
    }

    /// ghostty parses floats with `.` only, independent of the user's locale.
    static func fontSizeLiteral(_ size: Float) -> String {
        let rounded = (size * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        // String(format:) without a locale is not localized: always a `.` separator.
        return String(format: "%.2f", Double(rounded))
    }
}
