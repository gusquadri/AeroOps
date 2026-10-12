import Foundation

/// The contract between the app's askpass server and `aeroops-askpass`, the `SSH_ASKPASS` helper
/// ssh runs for password hosts.
///
/// ssh starts the helper with the prompt as its only argument and reads the password from its
/// stdout. The helper connects to ``Environment/socket``, sends one ``AskpassRequest`` line and
/// reads one ``AskpassReply`` line; the app checks who is asking before it answers. Linked by the
/// helper, so this module depends on nothing but Foundation.
public enum Askpass {
    /// The helper's file name in `AeroOps.app/Contents/MacOS/`.
    public static let helperName = "aeroops-askpass"
    /// The helper's code-signing identifier. The server only answers peers signed with it by the
    /// app's own team.
    public static let helperIdentifier = "app.aeroops.askpass"

    /// Variables SSHKit sets for ssh, which passes them on to the helper.
    public enum Environment {
        /// The askpass socket (`~/.aeroops/askpass.sock`).
        public static let socket = "AEROOPS_ASKPASS_SOCKET"
        /// The host id whose password ssh needs.
        public static let host = "AEROOPS_ASKPASS_HOST"
        /// Optional: a one-time token for a password that is not saved yet (Test Connection on an
        /// unsaved draft).
        public static let token = "AEROOPS_ASKPASS_TOKEN"
        /// Set by ssh to `confirm` or `none` for prompts that are not secrets.
        public static let promptKind = "SSH_ASKPASS_PROMPT"
    }

    /// Longest password in bytes. ssh reads at most 1023 bytes of askpass output, newline included.
    public static let maxPasswordBytes = 1000
    /// Longest prompt in bytes; ssh's own are far shorter.
    public static let maxPromptBytes = 1024
    /// Longest request or reply line in bytes, newline excluded.
    public static let maxMessageBytes = 8192
    /// How long the helper waits for the app before giving up.
    public static let timeoutSeconds = 10

    /// Whether `prompt` asks for the login password, so the helper may answer it.
    ///
    /// An allowlist of the prompts a password login shows: ssh's own `user@host's password:`,
    /// and PAM's `Password:` or `Password for user:` through keyboard-interactive, which OpenSSH
    /// prefixes with `(user@host) `. Everything else is refused: confirmations
    /// (`SSH_ASKPASS_PROMPT=confirm`), key passphrases, one-time codes, and an expired password's
    /// `(current) UNIX password:` / `New password:` dialogue.
    ///
    /// - Parameter kind: The `SSH_ASKPASS_PROMPT` value; ssh leaves it unset for secrets.
    public static func isPasswordPrompt(_ prompt: String, kind: String? = nil) -> Bool {
        if let kind, !kind.isEmpty { return false }
        guard prompt.utf8.count <= maxPromptBytes else { return false }
        var text = trimmed(prompt.lowercased())
        if text.hasSuffix(":") { text = trimmed(String(text.dropLast())) }
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            text = trimmed(String(text[text.index(after: close)...]))
        }
        return text == "password" || text.hasPrefix("password for ") || text.hasSuffix("'s password")
    }

    /// Why a password cannot be handed to ssh.
    public enum PasswordProblem: Sendable, Hashable {
        case empty
        /// ssh cuts askpass output at the first CR or LF, and a NUL ends it in C.
        case lineBreak
        /// Longer than ``maxPasswordBytes``.
        case tooLong
    }

    /// The reason `password` cannot be used, or `nil` when it can.
    public static func passwordProblem(_ password: String) -> PasswordProblem? {
        if password.isEmpty { return .empty }
        if password.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) { return .lineBreak }
        if password.utf8.count > maxPasswordBytes { return .tooLong }
        return nil
    }

    /// A new random one-time token: 32 lower-case hex digits.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            let byte = UInt8.random(in: 0...255, using: &generator)
            return String(byte, radix: 16).leftPadded(to: 2)
        }.joined()
    }

    /// 16 to 64 lower-case hex digits.
    public static func isValidToken(_ token: String) -> Bool {
        (16...64).contains(token.utf8.count) && token.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the helper asks: the password of ``host`` (or of the one-time ``token``) for ``prompt``.
public struct AskpassRequest: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var host: UUID
    public var token: String?
    public var prompt: String

    public init(host: UUID, token: String? = nil, prompt: String) {
        version = Self.currentVersion
        self.host = host
        self.token = token
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v", host, token, prompt
    }
}

/// The app's answer: a password, or why it refused.
public struct AskpassReply: Codable, Sendable, Hashable {
    public var password: String?
    /// Safe to show and log: never contains a secret.
    public var refusal: String?

    public static func password(_ password: String) -> AskpassReply {
        AskpassReply(password: password, refusal: nil)
    }

    public static func refused(_ reason: String) -> AskpassReply {
        AskpassReply(password: nil, refusal: reason)
    }
}

/// Line framing on a connected Unix socket, shared by the helper and the server.
public enum AskpassWire {
    /// `value` as one JSON line.
    public static func line(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding these plain structs cannot fail.
        return (try! encoder.encode(value)) + Data("\n".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }

    /// Reads up to the first newline (excluded). `nil` on EOF before a newline, a read error or
    /// timeout, or a line longer than `limit`.
    public static func readLine(_ fd: Int32, limit: Int = Askpass.maxMessageBytes) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            if let newline = buffer[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: buffer[0..<newline])
                return line.count <= limit ? line : nil
            }
            line.append(contentsOf: buffer[0..<count])
            if line.count > limit { return nil }
        }
    }

    /// Writes all of `data`; `false` on error or timeout.
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Sets `SO_NOSIGPIPE` and send/receive timeouts on a connected socket.
    public static func configure(_ fd: Int32, timeoutSeconds: Int) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
