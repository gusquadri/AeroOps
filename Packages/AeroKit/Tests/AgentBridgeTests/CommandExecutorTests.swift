import AeroCore
import BridgeProtocol
import Foundation
import Testing
@testable import AgentBridge

@Suite("Command executor")
struct CommandExecutorTests {
    let host = TestHosts.staging

    @Test func sendsTheWrappedCommandWithClampedTimeoutAndCaps() async throws {
        let runner = FakeRunner()
        let executor = CommandExecutor(runner: runner)
        let command = "df -h / | tail -1; echo \"$HOME\" 'it'\\''s'"
        _ = try await executor.execute(command, on: host, timeoutSeconds: 1000)
        _ = try await executor.execute("true", on: host, timeoutSeconds: 0)
        let calls = runner.calls
        try #require(calls.count == 2)
        #expect(calls[0].remoteCommand == RunCommandScript.remoteCommand(command, timeoutSeconds: 300))
        #expect(calls[0].remoteCommand == CommandExecutor.remoteCommand(for: command, timeoutSeconds: 300))
        #expect(calls[0].timeout == .seconds(300))
        #expect(calls[1].timeout == .seconds(1))
        #expect(calls[0].host == "staging")
        // Room for the heartbeat bytes on top of the 64 KB cap.
        #expect(calls[0].outputLimit > BridgeLimits.maxCommandOutputBytes)
        #expect(calls[0].outputLimit < BridgeLimits.maxCommandOutputBytes + 1024)
    }

    @Test func resultIsCleanedAndNonZeroExitIsNormal() async throws {
        let stdout = Data([0x06]) + Data("\u{1B}[32mgreen\u{1B}[0m\n".utf8) + Data([0x06, 0x06]) + Data("done\n".utf8)
        let runner = FakeRunner(.outcome(RemoteCommandOutcome(
            exitCode: 3, stdout: stdout, stderr: Data("\u{1B}[1mwarn\u{1B}[0m\n".utf8), duration: .milliseconds(1234))))
        let executor = CommandExecutor(runner: runner)
        let result = try await executor.execute("make", on: host, timeoutSeconds: 30)
        #expect(result == CommandResult(exitCode: 3, stdout: "green\ndone\n", stderr: "warn\n",
                                        stdoutTruncated: false, stderrTruncated: false, durationMs: 1234))
    }

    @Test func outputIsCappedAt64KBWithoutSplittingCharacters() async throws {
        let big = Data(("a" + String(repeating: "é", count: 35_000)).utf8)
        let runner = FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 0, stdout: big, stderr: Data("x".utf8), stderrTruncated: true)))
        let result = try await CommandExecutor(runner: runner).execute("yes", on: host, timeoutSeconds: 5)
        #expect(result.stdout.utf8.count == 65_535)
        #expect(result.stdoutTruncated)
        #expect(!result.stdout.unicodeScalars.contains("\u{FFFD}"))
        #expect(result.stderr == "x" && result.stderrTruncated, "the runner's own truncated flag passes through")
    }

    @Test func cappedHelper() {
        #expect(CommandExecutor.capped(Data("hello".utf8), limit: 5) == ("hello", false))
        #expect(CommandExecutor.capped(Data("hello!".utf8), limit: 5) == ("hello", true))
        #expect(CommandExecutor.capped(Data("aé".utf8), limit: 2) == ("a", true))
        #expect(CommandExecutor.capped(Data("€uro".utf8), limit: 2) == ("", true))
    }

    @Test func timeoutAndSSHFailures() async throws {
        let timedOut = CommandExecutor(runner: FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 143, timedOut: true))))
        await #expect(throws: CommandExecutionError.timedOut(seconds: 7)) {
            try await timedOut.execute("sleep 60", on: host, timeoutSeconds: 7)
        }
        #expect(CommandExecutionError.timedOut(seconds: 7).description == "The command did not finish within 7 seconds and was killed.")

        let refused = CommandExecutor(runner: FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 255, transportFailure: "Connection refused"))))
        await #expect(throws: CommandExecutionError.sshFailed("Connection refused")) {
            try await refused.execute("true", on: host, timeoutSeconds: 7)
        }
        let throwing = CommandExecutor(runner: FakeRunner(.throwing("launch failed")))
        await #expect(throws: CommandExecutionError.sshFailed("launch failed")) {
            try await throwing.execute("true", on: host, timeoutSeconds: 7)
        }
    }

    @Test func agentCancelKillsTheRunner() async throws {
        let runner = FakeRunner(.hang(seconds: 60))
        let executor = CommandExecutor(runner: runner)
        let call = Task { try await executor.execute("sleep 60", on: host, timeoutSeconds: 120) }
        #expect(await eventually { await !executor.running().isEmpty })
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(runner.cancellations == 1)
        #expect(await executor.running().isEmpty)
    }

    @Test func alreadyCancelledCallNeverRuns() async throws {
        let runner = FakeRunner()
        let executor = CommandExecutor(runner: runner)
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.execute("true", on: host, timeoutSeconds: 5)
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(runner.calls.isEmpty)
    }

    @Test func userCancelAndActivityFeed() async throws {
        let runner = FakeRunner(.hang(seconds: 60))
        let executor = CommandExecutor(runner: runner)
        let activity = executor.activity()
        let id = UUID()
        let call = Task { try await executor.execute("sleep 60", on: host, timeoutSeconds: 120, id: id) }
        #expect(await eventually { await executor.running().map(\.id) == [id] })
        let running = try #require(await executor.running().first)
        #expect(running.command == "sleep 60" && running.hostName == "staging")
        #expect(await executor.cancel(id))
        #expect(await executor.cancel(UUID()) == false)
        await #expect(throws: CommandExecutionError.cancelledByUser) { try await call.value }

        var events: [CommandActivity] = []
        for await event in activity {
            events.append(event)
            if events.count == 2 { break }
        }
        #expect(events.first == .started(running))
        #expect(events.last == .cancelled(id: id, byUser: true))
    }

    @Test func activityCarriesOutputWithoutHeartbeats() async throws {
        let runner = FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 0, stdout: Data([0x06]) + Data("hi\n".utf8))))
        let executor = CommandExecutor(runner: runner)
        let activity = executor.activity()
        let id = UUID()
        let result = try await executor.execute("echo hi", on: host, timeoutSeconds: 5, id: id)
        var events: [CommandActivity] = []
        for await event in activity {
            events.append(event)
            if case .finished = event { break }
        }
        #expect(events.count == 3)
        #expect(events[1] == .output(id: id, CommandOutputChunk(stream: .stdout, data: Data("hi\n".utf8))))
        #expect(events[2] == .finished(id: id, result))
    }

    @Test func activityKeepsEveryEventWhenTheReaderFallsBehind() async throws {
        let executor = CommandExecutor(runner: ChattyRunner(chunks: 1000))
        let activity = executor.activity()
        let id = UUID()
        // Nothing reads the feed until the command is over.
        let result = try await executor.execute("seq 1000", on: host, timeoutSeconds: 5, id: id)
        var events: [CommandActivity] = []
        for await event in activity {
            events.append(event)
            if case .finished = event { break }
        }
        #expect(events.count == 1002)
        guard case .started(let command)? = events.first else {
            Issue.record("first event: \(String(describing: events.first))")
            return
        }
        #expect(command.id == id)
        #expect(events.dropFirst().dropLast().allSatisfy { $0 == .output(id: id, CommandOutputChunk(stream: .stdout, data: Data("x".utf8))) })
        #expect(events.last == .finished(id: id, result))
    }
}

/// Sends its output as `chunks` one-byte pieces, then exits 0.
private struct ChattyRunner: RemoteCommandRunner {
    let chunks: Int

    func run(_ remoteCommand: String, on host: RemoteHost, timeout: Duration, outputLimit: Int,
             output: @escaping @Sendable (CommandOutputChunk) -> Void) async throws -> RemoteCommandOutcome {
        for _ in 0..<chunks { output(CommandOutputChunk(stream: .stdout, data: Data("x".utf8))) }
        return RemoteCommandOutcome(exitCode: 0, stdout: Data(repeating: UInt8(ascii: "x"), count: chunks))
    }
}
