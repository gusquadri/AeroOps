import Foundation
internal import GhosttyTerminal

/// Builds the libghostty configuration for one session.
///
/// The command lives in the app-level config, not in `TerminalSurfaceOptions.command`:
/// upstream forces `wait-after-command = true` for a per-surface command, which would keep the
/// surface waiting for a key press instead of reporting the exit. Hence one
/// `TerminalController` (one `ghostty_app_t`) per session.
enum GhosttyConfig {
    /// `key = value` settings, in order, excluding colours (those go into the theme).
    static func settings(appearance: TerminalAppearance, command: String) -> [(key: String, value: String)] {
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
            ("command", command),
            // Report the exit (close callback) as soon as the program ends ...
            ("wait-after-command", "false"),
            // ... even when it fails fast (ssh to a closed port exits 255 within milliseconds).
            ("abnormal-command-exit-runtime", "0"),
            // Remote hosts rarely have xterm-ghostty terminfo.
            ("term", "xterm-256color"),
            // The wrapper is sh; nothing to inject, and no GHOSTTY_* env leaking to ssh.
            ("shell-integration", "none"),
            // Remote OSC 9/777 notifications are not surfaced (yet); the session's own
            // reports use titles (see TerminalCommandLine).
            ("desktop-notifications", "false"),
            // Remote programs may set the clipboard (vim/tmux yank) but never read it.
            ("clipboard-read", "deny"),
            ("clipboard-write", "allow"),
            ("clipboard-paste-protection", "true"),
            ("confirm-close-surface", "false"),
        ]
        return settings
    }

    static func configuration(appearance: TerminalAppearance, command: String) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            for (key, value) in settings(appearance: appearance, command: command) {
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
