import Darwin
import Foundation
import GhosttyTerminal
import Synchronization
import Testing
@testable import TerminalKit

@Suite("Terminal process")
struct TerminalProcessTests {
    private final class Events: Sendable {
        private let events = Mutex<[TerminalProcess.Event]>([])

        func append(_ event: TerminalProcess.Event) {
            events.withLock { $0.append(event) }
        }

        var all: [TerminalProcess.Event] {
            events.withLock { $0 }
        }

        /// Waits up to `timeout` for an event `match` accepts.
        func first<T>(within timeout: Duration = .seconds(5), _ match: (TerminalProcess.Event) -> T?) async -> T? {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if let found = all.lazy.compactMap(match).first { return found }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
    }

    /// Starts `spec` the way a surface does: attach, then the first size.
    private func start(_ spec: TerminalLaunchSpec, events: Events) -> TerminalProcess {
        let process = TerminalProcess(spec: spec) { events.append($0) }
        let token = process.makeToken()
        let io = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        process.attach(io, token: token)
        process.resize(InMemoryTerminalViewport(columns: 80, rows: 24), token: token)
        return process
    }

    @Test("runs the program on a terminal and reports its exit status")
    func exitStatus() async throws {
        let events = Events()
        let spec = TerminalLaunchSpec(
            executable: "/bin/sh",
            arguments: ["-c", "test -t 0 && printf 'tty %s %s' \"$TERM\" \"$(stty size)\"; exit 3"],
            title: "test"
        )
        let process = start(spec, events: events)
        let pid = await events.first { if case let .started(pid) = $0 { pid } else { nil } }
        #expect(pid != nil)
        let code = await events.first { if case let .exited(code) = $0 { code } else { nil } }
        #expect(code == 3)
        let output = String(decoding: process.replayData(), as: UTF8.self)
        #expect(output.contains("tty xterm-256color 24 80"))
    }

    @Test("terminate hangs up the program")
    func terminate() async throws {
        let events = Events()
        let spec = TerminalLaunchSpec(executable: "/bin/sleep", arguments: ["30"], title: "test")
        let process = start(spec, events: events)
        let pid = try #require(await events.first { if case let .started(pid) = $0 { pid } else { nil } })
        process.terminate()
        let code = await events.first { if case let .exited(code) = $0 { code } else { nil } }
        #expect(code == 128 + SIGHUP)
        #expect(kill(pid, 0) == -1)
    }

    @Test("a program that cannot run fails")
    func missingExecutable() async {
        let events = Events()
        let spec = TerminalLaunchSpec(executable: "/nonexistent/aeroops-test", title: "test")
        let process = start(spec, events: events)
        let message = await events.first { if case let .failed(message) = $0 { message } else { nil } }
        #expect(message?.contains("/nonexistent/aeroops-test") == true)
        #expect(String(decoding: process.replayData(), as: UTF8.self).contains("cannot run"))
    }

    @Test("waitpid status as a shell reports it")
    func shellStatus() {
        #expect(TerminalProcess.shellStatus(3 << 8) == 3)
        #expect(TerminalProcess.shellStatus(0) == 0)
        #expect(TerminalProcess.shellStatus(SIGKILL) == 128 + SIGKILL)
    }

    @Test("the environment names the terminal and drops the launching one's")
    func environment() {
        let environment = TerminalProcess.environment(adding: ["AERO_TEST": "1", "TERM": "dumb"])
        #expect(environment.contains("AERO_TEST=1"))
        #expect(environment.contains("TERM=dumb"))
        #expect(environment.contains("COLORTERM=truecolor"))
        #expect(!environment.contains { $0.hasPrefix("GHOSTTY_") || $0.hasPrefix("TERM_PROGRAM=") })
        #expect(environment == environment.sorted())
    }

    @Test("only portable locale names are forwarded")
    func locales() {
        #expect(TerminalProcess.isPortableLocale("en_US.UTF-8"))
        #expect(TerminalProcess.isPortableLocale("C.UTF-8"))
        #expect(TerminalProcess.isPortableLocale("POSIX"))
        #expect(!TerminalProcess.isPortableLocale("UTF-8"))
        #expect(!TerminalProcess.isPortableLocale(""))
    }

    @Test("blocked images never reach the history; the bell and OSC 7 become events")
    func outputFiltering() async throws {
        let events = Events()
        let spec = TerminalLaunchSpec(
            executable: "/bin/sh",
            arguments: ["-c", #"printf 'a\033_Ga=T,t=f,i=1;L2V0Yy9wYXNzd2Q=\033\\b\a\033]7;file://h/srv\a'"#],
            title: "test"
        )
        let process = start(spec, events: events)
        let path = await events.first { if case let .workingDirectory(path) = $0 { path } else { nil } }
        #expect(path == "/srv")
        let bell = await events.first { if case .output(.bell) = $0 { true } else { nil } }
        #expect(bell == true)
        _ = await events.first { if case .exited = $0 { true } else { nil } }
        let output = String(decoding: process.replayData(), as: UTF8.self)
        #expect(output.contains("ab"))
        #expect(!output.contains("\u{1B}_G"))
        #expect(!output.contains("L2V0Yy9wYXNzd2Q"))
    }
}
