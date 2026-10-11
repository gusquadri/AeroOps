import AeroCore
import Darwin
import Foundation

/// The command line libghostty runs for one session, and the decoder for the reports it
/// sends back.
///
/// On macOS libghostty always starts the command through
/// `login -flp <user> /bin/bash --noprofile --norc -c "exec -l <command>"`. The `login` wrapper
/// is root-owned and always exits 0, so the real exit status is lost. The session therefore
/// wraps the spec in a small POSIX `sh` script that:
///
/// 1. clears the screen and scrollback (`CSI H`, `CSI 2J`, `CSI 3J`), which removes the
///    "Last login: ..." line `login` prints (it only stays quiet with `~/.hushlogin`, which we
///    must not create);
/// 2. reports its own PID, so `close()` can find and reap the tree;
/// 3. runs the program, then reports its exit status.
///
/// Reports travel as OSC 2 title changes. OSC 777 desktop notifications looked like the
/// natural channel, but libghostty drops notifications sent less than a second apart, which
/// loses the exit report of a program that fails at once (ssh to a closed port). Title changes
/// are not rate limited. Both reports carry a per-session random nonce, so output from the
/// remote side cannot forge them, and the session never publishes them as its title.
/// `/usr/bin/env` sits in front of `/bin/sh` because `exec -l` would otherwise start `sh` as a
/// login shell that reads `/etc/profile` and `~/.profile`.
struct TerminalCommandLine: Sendable, Hashable {
    /// A report decoded from a title change.
    enum Report: Sendable, Hashable {
        /// The wrapper shell started; `pid` is its process ID (the root of the program's tree).
        case started(pid: pid_t)
        /// The program finished with `code` (0-255; 128+N when killed by signal N).
        case exited(code: Int32)
    }

    static let startPrefix = "aeroops-start-"
    static let exitPrefix = "aeroops-exit-"

    let nonce: String
    /// The value of libghostty's `command` config key.
    let command: String

    init(spec: TerminalLaunchSpec, nonce: String = TerminalCommandLine.makeNonce()) {
        self.nonce = nonce
        let program = ShellQuote.join([spec.executable] + spec.arguments)
        let script = [
            #"printf '\033[H\033[2J\033[3J\033]2;"# + Self.startPrefix + nonce + #"-%d\007' "$$""#,
            program,
            "rc=$?",
            #"printf '\033]2;"# + Self.exitPrefix + nonce + #"-%d\007' "$rc""#,
            #"exit "$rc""#,
        ].joined(separator: "; ")
        command = "/usr/bin/env /bin/sh -c " + ShellQuote.quote(script)
    }

    /// 32 lower-case hex characters from the system CSPRNG.
    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// Whether `title` carries this session's nonce (a report, valid or not), so it must
    /// never be shown as the session title.
    func isReport(_ title: String) -> Bool {
        title.hasPrefix(Self.startPrefix + nonce + "-") || title.hasPrefix(Self.exitPrefix + nonce + "-")
    }

    /// Decodes a title change; `nil` when it is not a well-formed report of this session.
    func decode(title: String) -> Report? {
        if let value = Self.number(in: title, after: Self.startPrefix + nonce + "-"),
           let pid = pid_t(value), pid > 1 {
            return .started(pid: pid)
        }
        if let value = Self.number(in: title, after: Self.exitPrefix + nonce + "-"),
           let code = Int32(value), (0...255).contains(code) {
            return .exited(code: code)
        }
        return nil
    }

    private static func number(in title: String, after prefix: String) -> Substring? {
        guard title.hasPrefix(prefix) else { return nil }
        let digits = title.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.count <= 10,
              digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return digits
    }
}
