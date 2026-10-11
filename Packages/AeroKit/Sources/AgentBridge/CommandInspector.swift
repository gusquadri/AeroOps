import Darwin
import Foundation

/// Why a `run_command` must be approved by the user even inside an "allow host" window.
public enum AlwaysAskReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The command uses `sudo` (or `sudoedit`).
    case sudo
    /// The command switches user another way: `su`, `doas`, `pkexec`, `run0`, …
    case privilegeEscalation
    /// The command decodes or computes what it runs (`eval`, `base64 -d`, a variable as the
    /// command name, piping into a shell, …), so its text does not show what it does.
    case dynamicCode

    /// One line for the approval panel.
    public var explanation: String {
        switch self {
        case .sudo: "Uses sudo."
        case .privilegeEscalation: "Switches user (su, doas, pkexec, run0, …)."
        case .dynamicCode: "Builds, decodes or downloads what it runs, so the text may not show what it does."
        }
    }
}

/// Finds commands that must always be approved, whatever allow windows are open.
///
/// This is a tripwire, not a sandbox. It errs on the side of asking: any `sudo` that a POSIX
/// shell could run — after `;`, `&&`, `||`, `|`, `$(`, backticks, newlines, `env`, `command`,
/// `exec`, `xargs`, as a path like `/usr/bin/sudo`, split by quotes (`s'u'do`), backslashes
/// (`s\udo`), empty expansions (`su${x}do`, `su$@do`) or substitutions (`su$(true)do`) —
/// is reported, and so is anything that hides the command behind decoding or indirection. False
/// positives (`echo sudo`) only mean the user is asked once more.
public enum CommandInspector {
    /// The reasons `command` must always ask, in ``AlwaysAskReason/allCases`` order; empty when none.
    public static func alwaysAskReasons(for command: String) -> [AlwaysAskReason] {
        var reasons = Set<AlwaysAskReason>()
        let base = command.lowercased()
            .replacing("\\\r\n", with: "")
            .replacing("\\\n", with: "")
        let variants = normalizedVariants(base)

        for variant in variants {
            if containsSudo(variant) { reasons.insert(.sudo) }
            if containsWord(variant, escalationCommands) { reasons.insert(.privilegeEscalation) }
            if containsWord(variant, ["eval"]) { reasons.insert(.dynamicCode) }
        }
        if hasEncodedBytes(base) { reasons.insert(.dynamicCode) }
        for variant in variants {
            inspectCommandWords(variant, into: &reasons)
        }
        return AlwaysAskReason.allCases.filter(reasons.contains)
    }

    /// `true` when ``alwaysAskReasons(for:)`` contains ``AlwaysAskReason/sudo``.
    public static func usesSudo(_ command: String) -> Bool {
        alwaysAskReasons(for: command).contains(.sudo)
    }

    // MARK: - Word lists

    static let escalationCommands = ["su", "doas", "pkexec", "run0", "systemd-run", "machinectl", "please", "sudo-rs"]
    static let shells = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish", "csh", "tcsh", "busybox"]
    static let interpreters = ["python", "python2", "python3", "perl", "ruby", "node", "nodejs", "php", "lua", "tclsh", "osascript", "pwsh"]
    /// Words that run the next word as a command.
    static let wrappers: Set<String> = [
        "if", "then", "else", "elif", "do", "while", "until", "!", "time", "exec", "command", "builtin", "nohup",
        "env", "nice", "ionice", "stdbuf", "setsid", "timeout", "xargs", "watch", "caffeinate", "unbuffer",
        "chronic", "flock", "chrt", "taskset", "strace", "ltrace", "busybox", "doas", "sudo", "unshare", "chroot",
    ]

    // MARK: - Normalization

    /// The command as written, and as a shell might reassemble it after quote removal and
    /// empty expansions. A rule matching any variant counts.
    static func normalizedVariants(_ base: String) -> [String] {
        let withoutExpansions = removeEmptyableExpansions(base)
        let dequoted = removeQuoting(withoutExpansions)
        let withoutSubstitutions = removeQuoting(removeSubstitutions(withoutExpansions))
        let withoutDollars = removeQuoting(base).replacing("$", with: "")
        var seen = Set<String>()
        return [base, dequoted, withoutSubstitutions, withoutDollars].filter { seen.insert($0).inserted }
    }

    /// Removes `${…}`, `$name` and `$1`, `$@`, `$*`, `$#`, `$?`, `$$`, `$!`, `$-`, which may expand to nothing.
    static func removeEmptyableExpansions(_ text: String) -> String {
        text.replacing(/\$\{[^}]*\}/, with: "")
            .replacing(/\$[a-z_][a-z0-9_]*/, with: "")
            .replacing(/\$[0-9@*#?$!\-]/, with: "")
    }

    /// Removes `$(…)` (innermost first, a few levels) and `` `…` ``.
    static func removeSubstitutions(_ text: String) -> String {
        var result = text.replacing(/`[^`]*`/, with: "")
        for _ in 0..<8 {
            let next = result.replacing(/\$\([^()]*\)/, with: "")
            if next == result { break }
            result = next
        }
        return result
    }

    /// Removes `'`, `"` and `\`, so `s'u'do`, `"sudo"` and `s\udo` read as `sudo`.
    static func removeQuoting(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0 != "'" && $0 != "\"" && $0 != "\\" }.map(Character.init))
    }

    // MARK: - Substring rules

    private static func isWordByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"): true
        default: false
        }
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isWordByte(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-") || byte >= 0x80
    }

    /// `sudo` not preceded by a letter, digit or `_`: catches `sudo`, `sudoedit`, `/usr/bin/sudo`,
    /// `;sudo`, `$(sudo`, `` `sudo ``; not `pseudo`.
    static func containsSudo(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let needle = Array("sudo".utf8)
        guard bytes.count >= needle.count else { return false }
        for start in 0...(bytes.count - needle.count) where bytes[start..<(start + needle.count)].elementsEqual(needle) {
            if start == 0 || !isWordByte(bytes[start - 1]) { return true }
        }
        return false
    }

    /// Any of `words` as a whole word (neighbours are not letters, digits, `_`, `.` or `-`).
    static func containsWord(_ text: String, _ words: [String]) -> Bool {
        let bytes = Array(text.utf8)
        for word in words {
            let needle = Array(word.utf8)
            guard bytes.count >= needle.count else { continue }
            for start in 0...(bytes.count - needle.count) where bytes[start..<(start + needle.count)].elementsEqual(needle) {
                let end = start + needle.count
                let leftOK = start == 0 || !isNameByte(bytes[start - 1])
                let rightOK = end == bytes.count || !isNameByte(bytes[end])
                if leftOK && rightOK { return true }
            }
        }
        return false
    }

    /// Byte escapes that `printf`, `echo -e` or `$'…'` turn into arbitrary text: `\x73`, `\163`, `\0163`, `s`.
    static func hasEncodedBytes(_ text: String) -> Bool {
        text.contains(/\\x[0-9a-f]/) || text.contains(/\\0?[0-7]{3}/) || text.contains(/\\u[0-9a-f]{4}/)
    }

    // MARK: - Command-word rules

    /// Splits into simple commands and checks each command word: variables or substitutions as
    /// the command name, globs that can expand to `sudo`, decoders, and shells or interpreters
    /// reading their program from a pipe.
    static func inspectCommandWords(_ text: String, into reasons: inout Set<AlwaysAskReason>) {
        for segment in segments(text) {
            var words = segment.text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Skip assignments, wrappers and their options.
            var afterWrapper = false
            while let first = words.first {
                if first.contains(/^[a-z_][a-z0-9_]*=/) || wrappers.contains(first)
                    || (afterWrapper && (first.hasPrefix("-") || first.contains(/^[0-9.]+[smhd]?$/))) {
                    if wrappers.contains(first) { afterWrapper = true }
                    words.removeFirst()
                } else {
                    break
                }
            }
            guard let commandWord = words.first else { continue }
            let arguments = Array(words.dropFirst())
            let name = basename(removeQuoting(commandWord))

            if commandWord.contains("$") || commandWord.contains("`") {
                reasons.insert(.dynamicCode)
            }
            if commandWord.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
                if globMatches(name, ["sudo", "sudoedit"]) {
                    reasons.insert(.sudo)
                } else if globMatches(name, escalationCommands) {
                    reasons.insert(.privilegeEscalation)
                } else if name.allSatisfy({ "*?[]".contains($0) }) && commandWord.contains("/") {
                    reasons.insert(.dynamicCode)
                }
            }
            if isDecoder(name, arguments) { reasons.insert(.dynamicCode) }
            if shells.contains(name) || interpreters.contains(where: { name == $0 || isVersioned(name, of: $0) }) {
                let (programArguments, redirectsInput) = withoutRedirections(arguments)
                let readsProgramFromStdin = programArguments.allSatisfy { $0.hasPrefix("-") && !inlineCodeFlags.contains($0) }
                    || programArguments.contains("/dev/stdin") || programArguments.contains("-")
                if (segment.afterPipe || redirectsInput) && readsProgramFromStdin {
                    reasons.insert(.dynamicCode)
                }
                if !shells.contains(name), programArguments.contains(where: inlineCodeFlags.contains),
                   hidesWordsInCode(text) {
                    reasons.insert(.dynamicCode)
                }
            }
            if name == "source" || name == "." {
                if arguments.contains(where: { $0.hasPrefix("/dev/") || $0.hasPrefix("/proc/") || $0.hasPrefix("<") }) {
                    reasons.insert(.dynamicCode)
                }
            }
        }
    }

    static let inlineCodeFlags: Set<String> = ["-c", "-e", "-E", "-r", "--eval", "-p", "--print"]

    struct Segment {
        var text: String
        /// The previous separator was a single `|`.
        var afterPipe: Bool
    }

    /// Splits at `;`, `&`, `|`, newlines, parentheses, braces and backticks.
    static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var current = ""
        var afterPipe = false
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case ";", "&", "|", "\n", "(", ")", "{", "}", "`":
                result.append(Segment(text: current, afterPipe: afterPipe))
                current = ""
                let isPipe = scalar == "|" && (index + 1 >= scalars.count || scalars[index + 1] != "|")
                    && (index == 0 || scalars[index - 1] != "|")
                if scalar == "|" && index + 1 < scalars.count && scalars[index + 1] == "&" {
                    afterPipe = true // `|&`
                    index += 1
                } else {
                    afterPipe = isPipe
                }
            default:
                current.unicodeScalars.append(scalar)
            }
            index += 1
        }
        result.append(Segment(text: current, afterPipe: afterPipe))
        return result.filter { !$0.text.allSatisfy(\.isWhitespace) }
    }

    /// Drops redirections (`< file`, `<<eof`, `2>&1`, `>out`) and says whether stdin was redirected.
    private static func withoutRedirections(_ arguments: [String]) -> (arguments: [String], redirectsInput: Bool) {
        var kept: [String] = []
        var redirectsInput = false
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if let match = argument.firstMatch(of: /^[0-9]*([<>]+)/) {
                if match.output.1.contains("<") { redirectsInput = true }
                // A bare operator takes the next word as its target.
                if argument.allSatisfy({ $0.isNumber || $0 == "<" || $0 == ">" }) { skipNext = true }
                continue
            }
            kept.append(argument)
        }
        return (kept, redirectsInput)
    }

    private static func basename(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }

    private static func isVersioned(_ name: String, of interpreter: String) -> Bool {
        name.hasPrefix(interpreter) && name.dropFirst(interpreter.count).allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func globMatches(_ pattern: String, _ names: [String]) -> Bool {
        names.contains { fnmatch(pattern, $0, 0) == 0 }
    }

    /// `base64 -d`, `base64 --decode`, `xxd -r`, `openssl … -d`, `uudecode`.
    private static func isDecoder(_ name: String, _ arguments: [String]) -> Bool {
        func hasShortFlag(_ flag: Character) -> Bool {
            arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains(flag) }
        }
        switch name {
        case "base64", "base32", "basenc": return hasShortFlag("d") || arguments.contains("--decode")
        case "xxd": return hasShortFlag("r") || arguments.contains("-revert")
        case "openssl": return arguments.contains("-d") || arguments.contains("base64") || arguments.contains("enc")
        case "uudecode", "gpg": return true
        default: return false
        }
    }

    /// Inline interpreter code that assembles strings: `'s'+'udo'`, `chr(115)`, `b64decode`, `[::-1]`, `exec(`.
    private static func hidesWordsInCode(_ text: String) -> Bool {
        let lettersOnly = String(text.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            .map(Character.init))
        if lettersOnly.contains("sudo") || lettersOnly.contains("doas") || lettersOnly.contains("pkexec") { return true }
        let markers = ["chr(", "fromhex", "b64decode", "decode(", "[::-1]", "exec(", "eval(", "compile(", "__import__", "fromcharcode", "pack("]
        return markers.contains { text.contains($0) }
    }
}
