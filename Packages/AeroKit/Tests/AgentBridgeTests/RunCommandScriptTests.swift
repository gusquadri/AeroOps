import AeroCore
import AeroTestSupport
import Darwin
import Foundation
import Testing
@testable import AgentBridge

/// The `run_command` wrapper, run locally with `/bin/sh` in its own session (as sshd would).
@Suite("run_command wrapper")
struct RunCommandScriptTests {
    @Test func embeddedScriptMatchesTheRepoFile() throws {
        let file = try Fixtures.repoRoot().appending(path: "Scripts/remote/run-command.sh")
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(RunCommandScript.source == onDisk, "Scripts/remote/run-command.sh and RunCommandScript.source differ")
    }

    @Test func bodyDropsCommentsOnly() {
        let body = RunCommandScript.body
        #expect(body.hasPrefix("sh -c \"$1\" &\n"))
        #expect(!body.split(separator: "\n").contains { $0.hasPrefix("#") })
        #expect(body.hasSuffix("exit \"$s\"\n"))
    }

    @Test func remoteCommandQuotesEveryWord() {
        let remote = RunCommandScript.remoteCommand("echo 'a b'; uptime", timeoutSeconds: 30, heartbeatSeconds: 3)
        #expect(remote.hasPrefix("sh -c " + ShellQuote.quote(RunCommandScript.body) + " aeroops-run "))
        #expect(remote.hasSuffix(" aeroops-run " + ShellQuote.quote("echo 'a b'; uptime") + " 36 3"))
        #expect(RunCommandScript.remoteCommand("true", timeoutSeconds: 0, heartbeatSeconds: 0).hasSuffix(" 'true' 3 1"))
    }

    @Test func heartbeatsAreRemoved() {
        #expect(RunCommandScript.removingHeartbeats(Data([0x06, 0x68, 0x06, 0x06, 0x69, 0x0A, 0x06])) == Data("hi\n".utf8))
        let plain = Data("no heartbeats\n".utf8)
        #expect(RunCommandScript.removingHeartbeats(plain) == plain)
        #expect(RunCommandScript.removingHeartbeats(Data([0x06, 0x06])).isEmpty)
    }

    @Test func commandReachesTheShellVerbatimAndKeepsItsStatus() async throws {
        let command = #"printf '[%s]' "it's" "a  b" '$(id)' "\`x\`"; echo; exit 7"#
        let session = try LocalProcess.startSession(RunCommandScript.remoteCommand(command, timeoutSeconds: 30, heartbeatSeconds: 1))
        defer { close(session.stdout) }
        let output = await LocalProcess.readToEnd(session.stdout)
        #expect(await LocalProcess.wait(session.pid) == 7)
        #expect(String(decoding: RunCommandScript.removingHeartbeats(output), as: UTF8.self) == "[it's][a  b][$(id)][`x`]\n")
    }

    @Test func heartbeatsFlowWhileTheCommandRuns() async throws {
        let session = try LocalProcess.startSession(
            RunCommandScript.remoteCommand("echo hi; sleep 3; echo bye", timeoutSeconds: 30, heartbeatSeconds: 1))
        defer { close(session.stdout) }
        let output = await LocalProcess.readToEnd(session.stdout)
        #expect(await LocalProcess.wait(session.pid) == 0)
        #expect(output.contains(RunCommandScript.heartbeat))
        #expect(RunCommandScript.removingHeartbeats(output) == Data("hi\nbye\n".utf8))
    }

    @Test("Client gone (stdout closed): the quiet command is killed")
    func closedStdoutKillsTheCommand() async throws {
        let session = try LocalProcess.startSession(
            RunCommandScript.remoteCommand("echo $$; exec sleep 60", timeoutSeconds: 300, heartbeatSeconds: 1))
        let line = await LocalProcess.readLine(session.stdout)
        let pid = try #require(pid_t(line.filter(\.isNumber)), "no pid in \(line.debugDescription)")
        #expect(kill(pid, 0) == 0, "sleep is running")
        close(session.stdout)
        _ = await LocalProcess.wait(session.pid)
        #expect(await LocalProcess.isGone(pid, within: .seconds(10)), "sleep 60 outlived the closed channel")
    }

    @Test("Deadline: TERM, then KILL for a command that ignores TERM")
    func deadlineKillsEvenATermIgnoringCommand() async throws {
        let start = ContinuousClock.now
        let session = try LocalProcess.startSession(
            RunCommandScript.remoteCommand("trap '' TERM; echo $$; while :; do sleep 1; done", timeoutSeconds: 1, heartbeatSeconds: 1))
        defer { close(session.stdout) }
        let line = await LocalProcess.readLine(session.stdout)
        let pid = try #require(pid_t(line.filter(\.isNumber)), "no pid in \(line.debugDescription)")
        _ = await LocalProcess.readToEnd(session.stdout)
        _ = await LocalProcess.wait(session.pid)
        #expect(await LocalProcess.isGone(pid, within: .seconds(10)), "the TERM-ignoring loop survived the deadline")
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .seconds(3) && elapsed < .seconds(15), "took \(elapsed)")
    }
}
