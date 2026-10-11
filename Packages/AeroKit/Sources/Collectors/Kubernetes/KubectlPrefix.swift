import AeroCore
import Foundation

/// Validates a host's kubectl prefix (`RemoteHost.kubectlPrefix`), which is inserted unquoted as
/// the head of every kubectl command: `LC_ALL=C <prefix> get pods -A -o json`.
///
/// The prefix is trusted configuration typed by the user (like an ssh command line), so the
/// check is not a sandbox: `sudo -n rm` passes. It only guarantees the prefix is a list of plain
/// words that the remote shell splits exactly as shown, with no expansion, quoting,
/// redirection or command chaining. The rule:
///
/// - `nil`, empty or blank means `kubectl`.
/// - ASCII only, at most ``maxLength`` bytes and ``maxWords`` words, separated by spaces or tabs
///   (normalized to single spaces).
/// - Every word uses only `A-Z a-z 0-9 _ . / : = @ % + , -`. Rejected among others:
///   quotes, `$`, `` ` ``, `;`, `|`, `&`, `<`, `>`, `(`, `)`, `{`, `}`, `[`, `]`, `*`, `?`,
///   `~`, `#`, `!`, `\`, newlines.
/// - Leading words that contain `=` are environment assignments and must look like
///   `NAME=value` with `NAME` matching `[A-Za-z_][A-Za-z0-9_]*`.
/// - At least one command word must follow them, and it must not start with `-`.
///
/// Accepted: `kubectl`, `k3s kubectl`, `sudo -n k3s kubectl`, `microk8s kubectl`,
/// `KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl`, `kubectl --context=prod`.
public enum KubectlPrefix {
    /// Used when the host has no prefix.
    public static let defaultPrefix = "kubectl"
    /// Longest accepted prefix, in bytes.
    public static let maxLength = 256
    /// Most words accepted.
    public static let maxWords = 16

    /// The prefix with words joined by single spaces, or ``defaultPrefix`` when blank.
    ///
    /// - Throws: ``CollectorInputError/invalidKubectlPrefix(_:reason:)`` explaining the first problem.
    public static func normalized(_ prefix: String?) throws(CollectorInputError) -> String {
        guard let prefix else { return defaultPrefix }
        let bytes = Array(prefix.utf8)
        if bytes.allSatisfy(isSeparator) { return defaultPrefix }
        func reject(_ reason: String) -> CollectorInputError { .invalidKubectlPrefix(prefix, reason: reason) }

        guard bytes.count <= maxLength else { throw reject("it is longer than \(maxLength) characters.") }
        if let bad = bytes.first(where: { !isSeparator($0) && !isWordByte($0) }) {
            throw reject("it contains \(describe(bad)), which is not allowed.")
        }
        let words = prefix.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.count <= maxWords else { throw reject("it has more than \(maxWords) words.") }

        var index = 0
        while index < words.count, words[index].contains("=") {
            guard isAssignment(words[index]) else {
                throw reject("\"\(words[index])\" is not a NAME=value environment assignment.")
            }
            index += 1
        }
        guard index < words.count else { throw reject("it has no command after the environment assignments.") }
        guard !words[index].hasPrefix("-") else { throw reject("the command \"\(words[index])\" starts with \"-\".") }
        return words.joined(separator: " ")
    }

    /// `true` when ``normalized(_:)`` accepts `prefix`.
    public static func isValid(_ prefix: String?) -> Bool {
        (try? normalized(prefix)) != nil
    }

    // MARK: - Private

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        case UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: "="),
             UInt8(ascii: "@"), UInt8(ascii: "%"), UInt8(ascii: "+"), UInt8(ascii: ","), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "=") else { return false }
        let name = word[..<equals].utf8
        guard let first = name.first, first == UInt8(ascii: "_") || isLetter(first) else { return false }
        return name.allSatisfy { $0 == UInt8(ascii: "_") || isLetter($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func describe(_ byte: UInt8) -> String {
        switch byte {
        case 0x0A: "a line break"
        case 0x0D: "a carriage return"
        case 0x80...: "a non-ASCII character"
        case 0x00..<0x20, 0x7F: "a control character"
        default: "\"\(Character(Unicode.Scalar(byte)))\""
        }
    }
}
