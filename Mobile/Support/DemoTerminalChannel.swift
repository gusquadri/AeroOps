import EmbeddedSSH
import EmbeddedTerminal
import Foundation
import SSHKit
import Synchronization

/// A canned shell for `-AeroOpsDemo` and previews: a login banner and prompt, line editing,
/// and sample answers to a few commands. Nothing runs anywhere; `exit` ends it with status 0.
final class DemoTerminalChannel: TerminalChannel {
    private struct State {
        var line = ""
        var exitStatus: Int32?
        var isClosed = false
    }

    private let stream = AsyncStream<Data>.makeStream()
    private let state = Mutex(State())
    private let prompt: String
    private let user: String
    private let hostName: String

    init(user: String, hostName: String) {
        self.user = user
        self.hostName = hostName
        prompt = "\u{1B}[1;32m\(user)@\(hostName)\u{1B}[0m:\u{1B}[1;34m~\u{1B}[0m$ "
        emit(Self.banner(hostName: hostName) + prompt)
    }

    var incoming: AsyncStream<Data> { stream.stream }
    var exitStatus: Int32? { state.withLock { $0.exitStatus } }

    func send(_ data: Data) {
        for byte in data {
            switch byte {
            case 0x0D, 0x0A:
                let line = state.withLock { state in
                    defer { state.line = "" }
                    return state.line
                }
                answer(line.trimmingCharacters(in: .whitespaces))
            case 0x7F, 0x08:
                let erased = state.withLock { $0.line.popLast() != nil }
                if erased { emit("\u{8} \u{8}") }
            case 0x03:
                state.withLock { $0.line = "" }
                emit("^C\r\n" + prompt)
            case 0x20...0x7E:
                state.withLock { $0.line.append(Character(UnicodeScalar(byte))) }
                emit(String(UnicodeScalar(byte)))
            default:
                // Escape sequences (arrows and the like) do nothing here.
                break
            }
        }
    }

    func resize(_ size: PseudoTerminalSize) {}

    func closeInput() {
        end(status: 0)
    }

    func close() {
        end(status: nil)
    }

    func waitForEnd() async -> SSHError? { nil }

    func isResponsive(within timeout: Duration) async -> Bool { true }

    private func answer(_ command: String) {
        emit("\r\n")
        switch command.split(separator: " ").first.map(String.init) {
        case nil:
            break
        case "exit", "logout":
            emit("logout\r\n")
            return end(status: 0)
        case "ls":
            emit("\u{1B}[1;34mapp\u{1B}[0m  \u{1B}[1;34mbackups\u{1B}[0m  \u{1B}[1;36mcurrent\u{1B}[0m  \u{1B}[1;32mdeploy.sh\u{1B}[0m  \u{1B}[1;34mlogs\u{1B}[0m  nginx.conf  notes.md\r\n")
        case "whoami":
            emit("\(user)\r\n")
        case "hostname":
            emit("\(hostName)\r\n")
        case "uptime":
            emit(" 14:02:11 up 41 days,  3:17,  1 user,  load average: 0.42, 0.37, 0.31\r\n")
        case "uname":
            emit("Linux \(hostName) 6.8.0-45-generic #45-Ubuntu SMP aarch64 GNU/Linux\r\n")
        default:
            emit("\u{1B}[33mThis is the AeroOps demo: “\(command)” did not run anywhere.\u{1B}[0m\r\n")
        }
        emit(prompt)
    }

    private func emit(_ text: String) {
        guard !state.withLock({ $0.isClosed }) else { return }
        stream.continuation.yield(Data(text.utf8))
    }

    private func end(status: Int32?) {
        let ended = state.withLock { state in
            guard !state.isClosed else { return false }
            state.isClosed = true
            state.exitStatus = status
            return true
        }
        if ended { stream.continuation.finish() }
    }

    private static func banner(hostName: String) -> String {
        [
            "Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic aarch64)",
            "",
            "  System load:  0.42               Processes:             128",
            "  Usage of /:   48.3% of 61.84GB   Users logged in:       1",
            "  Memory usage: 62%                IPv4 address for eth0: 10.0.0.12",
            "",
            "\u{1B}[2mThis is a sample session from the AeroOps demo; nothing runs on \(hostName).\u{1B}[0m",
            "",
            "Last login: Fri Oct 16 18:44:02 2026 from 10.0.0.2",
            "",
        ].joined(separator: "\r\n")
    }
}
