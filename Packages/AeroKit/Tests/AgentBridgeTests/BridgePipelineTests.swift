import AeroCore
import BridgeProtocol
import Foundation
import Synchronization
import Testing
@testable import AgentBridge

/// The whole pipeline (tool → arguments → host → policy → approval → handler/executor → audit)
/// through `Bridge.process`, with fakes for the host data, ssh and time.
@Suite("Bridge pipeline")
struct BridgePipelineTests {
    final class Fixture: Sendable {
        let dir: TempDirectory
        let clock = FakeClock()
        let handler: FakeToolHandler
        let runner: FakeRunner
        let approvals: ApprovalCenter
        let audit: AuditLog
        let bridge: Bridge

        init(handler: FakeToolHandler = FakeToolHandler(),
             runner: FakeRunner = FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 0, stdout: Data("OUTPUT-7f3a\n".utf8), duration: .milliseconds(15))))) throws {
            dir = try TempDirectory()
            self.handler = handler
            self.runner = runner
            approvals = ApprovalCenter(clock: clock)
            audit = AuditLog(fileURL: dir.appending("audit.jsonl"))
            bridge = Bridge(socketURL: dir.appending("bridge.sock"), handler: handler,
                            executor: CommandExecutor(runner: runner, clock: clock), approvals: approvals, audit: audit,
                            peerValidator: AcceptAllPeers(), clock: clock, progressInterval: .milliseconds(50))
        }

        deinit { dir.remove() }

        func call(_ tool: String, _ arguments: [String: JSONValue] = [:], progress: Progress? = nil) async -> BridgeReply? {
            let request = BridgeRequest(id: 1, tool: tool, arguments: arguments,
                                        client: BridgeClientInfo(name: "claude-code", version: "2.1.296"), toolUseId: "toolu_x")
            return await bridge.process(request, peer: testPeer) { progress?.append($0) }
        }

        /// Starts a call in the background and waits until its approval is pending.
        func pendingCall(_ arguments: [String: JSONValue], progress: Progress? = nil) async throws -> (Task<BridgeReply?, Never>, PendingApproval) {
            let before = Set(await approvals.snapshot().pending.map(\.id))
            let task = Task { await self.call("run_command", arguments, progress: progress) }
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let pending = await approvals.snapshot().pending.first(where: { !before.contains($0.id) }) {
                    return (task, pending)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            task.cancel()
            throw TestFailure("no approval became pending")
        }

        func auditEntries() async -> [AuditEntry] { await audit.recent() }

        var auditFile: String { (try? String(contentsOf: dir.appending("audit.jsonl"), encoding: .utf8)) ?? "" }
    }

    final class Progress: Sendable {
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    static func run(_ command: String, on host: String = "staging", timeout: Int? = nil) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["host": .string(host), "command": .string(command), "reason": "Check the disk."]
        if let timeout { arguments["timeoutSec"] = .int(timeout) }
        return arguments
    }

    // MARK: Read tools

    @Test func listHostsHidesHostsSetToOff() async throws {
        let fixture = try Fixture()
        let reply = try #require(await fixture.call("list_hosts"))
        #expect(reply.ok)
        let hosts = reply.structuredContent?["hosts"]?.arrayValue ?? []
        #expect(hosts.compactMap { $0["name"]?.stringValue } == ["prod", "staging"])
        #expect(hosts.compactMap { $0["tier"]?.stringValue } == ["read", "readExec"])
        #expect(reply.text.contains("\"staging\"") && !reply.text.contains("vault"))
        let tagged = try #require(await fixture.call("list_hosts", ["tag": "PROD"]))
        #expect(tagged.structuredContent?["hosts"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["prod"])
        #expect(tagged.structuredContent?["count"]?.intValue == 1)
    }

    @Test func offHostsAreNotShared() async throws {
        let fixture = try Fixture()
        for tool in ["get_host_metrics", "list_containers", "list_pods"] {
            let reply = try #require(await fixture.call(tool, ["host": "vault"]))
            #expect(reply.error == BridgeError(code: .hostNotShared, message: "Host \"vault\" is not shared with agents."))
        }
        let run = try #require(await fixture.call("run_command", Self.run("id", on: "vault")))
        #expect(run.error?.code == .hostNotShared)
        #expect(fixture.handler.calls.isEmpty && fixture.runner.calls.isEmpty)
        #expect(await fixture.approvals.snapshot().pending.isEmpty)
        let entries = await fixture.auditEntries()
        #expect(entries.count == 4)
        #expect(entries.allSatisfy { $0.decision == .rejected && $0.outcome == .notRun && $0.error == "host_not_shared" })
    }

    @Test func readToolsReturnHandlerData() async throws {
        let fixture = try Fixture()
        let metrics = try #require(await fixture.call("get_host_metrics", ["host": "staging"]))
        #expect(metrics.structuredContent?["cpuPercent"] == .double(12.3))
        #expect(metrics.structuredContent?["host"]?.stringValue == "staging")
        let containers = try #require(await fixture.call("list_containers", ["host": "prod", "all": true]))
        #expect(containers.structuredContent?["containers"]?.arrayValue?.first?["name"]?.stringValue == "api")
        #expect(fixture.handler.calls == ["metrics staging", "containers prod true"])
        let entries = await fixture.auditEntries()
        #expect(entries.map(\.decision) == [.allowed, .allowed] && entries.map(\.outcome) == [.succeeded, .succeeded])
        #expect(entries.first?.host == "staging" && entries.first?.hostId == TestHosts.staging.id)
    }

    @Test func logsAreFencedAndStripped() async throws {
        let fixture = try Fixture()
        let reply = try #require(await fixture.call("get_logs", ["host": "staging", "kind": "container", "name": "api", "tail": 2]))
        #expect(reply.ok && reply.structuredContent == nil)
        let text = reply.text
        #expect(text.hasPrefix("Logs of container \"api\" on host \"staging\": 2 lines, truncated"))
        #expect(text.contains("----- BEGIN UNTRUSTED LOG OUTPUT "))
        #expect(text.contains("line 2\nline 3\n----- END UNTRUSTED LOG OUTPUT "))
        #expect(!text.contains("\u{1B}"))
        #expect(fixture.handler.calls == ["logs staging container api tail=2"])
    }

    @Test func refusalsBeforeAnythingRuns() async throws {
        let fixture = try Fixture()
        let unknown = try #require(await fixture.call("rm_rf", ["host": "staging"]))
        #expect(unknown.error?.code == .unknownTool)
        #expect(unknown.error?.message == "Unknown tool \"rm_rf\".")
        let tooMany = try #require(await fixture.call("get_logs", ["host": "staging", "kind": "pod", "name": "api", "tail": 5000]))
        #expect(tooMany.error?.code == .invalidArguments)
        #expect(tooMany.error?.message.contains("2000") == true)
        let badName = try #require(await fixture.call("get_logs", ["host": "staging", "kind": "pod", "name": "api; reboot"]))
        #expect(badName.error?.code == .invalidArguments)
        let longTimeout = try #require(await fixture.call("run_command", Self.run("uptime", timeout: 301)))
        #expect(longTimeout.error?.code == .invalidArguments)
        let nowhere = try #require(await fixture.call("get_host_metrics", ["host": "db-9"]))
        #expect(nowhere.error?.code == .hostNotFound)
        #expect(fixture.handler.calls.isEmpty && fixture.runner.calls.isEmpty)
        #expect(await fixture.approvals.snapshot().pending.isEmpty)
        #expect(await fixture.auditEntries().map(\.decision) == [.invalid, .invalid, .invalid, .invalid, .rejected])
    }

    @Test func handlerFailuresBecomeToolErrors() async throws {
        let fixture = try Fixture(handler: FakeToolHandler(failure: .unavailable("Docker is not installed on staging.")))
        let reply = try #require(await fixture.call("list_containers", ["host": "staging"]))
        #expect(reply.error == BridgeError(code: .unavailable, message: "Docker is not installed on staging."))
        #expect(await fixture.auditEntries().last?.outcome == .failed)
    }

    // MARK: run_command

    @Test func readTierRejectsRunCommandWithoutAsking() async throws {
        let fixture = try Fixture()
        let reply = try #require(await fixture.call("run_command", Self.run("uptime", on: "prod")))
        #expect(reply.error?.code == .execNotAllowed)
        #expect(fixture.runner.calls.isEmpty)
        #expect(await fixture.approvals.snapshot().pending.isEmpty)
    }

    @Test func approvedOnceRunsAndIsAuditedWithoutOutput() async throws {
        let fixture = try Fixture()
        let progress = Progress()
        let (task, pending) = try await fixture.pendingCall(Self.run("df -h /", timeout: 20), progress: progress)
        #expect(pending.command == "df -h /" && pending.reason == "Check the disk." && pending.hostName == "staging")
        #expect(pending.clientLabel == "claude-code 2.1.296 (self-reported)" && pending.toolUseId == "toolu_x")
        #expect(fixture.runner.calls.isEmpty, "nothing runs before the user decides")
        #expect(await eventually { progress.all.count >= 2 })
        #expect(progress.all.first == "Waiting for approval in AeroOps")
        #expect(progress.all.dropFirst().first?.hasPrefix("Waiting for approval in AeroOps (") == true)

        #expect(await fixture.approvals.decide(pending.id, .allowOnce))
        let reply = try #require(await task.value)
        #expect(reply.ok)
        #expect(reply.structuredContent?["exitCode"]?.intValue == 0)
        #expect(reply.structuredContent?["stdout"]?.stringValue == "OUTPUT-7f3a\n")
        #expect(progress.all.last == "Running on staging")
        let call = try #require(fixture.runner.calls.first)
        #expect(call.remoteCommand == RunCommandScript.remoteCommand("df -h /", timeoutSeconds: 20) && call.timeout == .seconds(20))

        let entry = try #require(await fixture.auditEntries().last)
        #expect(entry.decision == .approvedOnce && entry.outcome == .succeeded && entry.exitCode == 0)
        #expect(entry.arguments["command"]?.stringValue == "df -h /")
        #expect(entry.client == "claude-code 2.1.296" && entry.toolUseId == "toolu_x")
        #expect((entry.outputBytes ?? 0) > 0)
        #expect(fixture.auditFile.contains("df -h /"))
        #expect(!fixture.auditFile.contains("OUTPUT-7f3a"), "the audit log never stores command output")
    }

    @Test func deniedAndTimedOutApprovals() async throws {
        let fixture = try Fixture()
        let (denied, first) = try await fixture.pendingCall(Self.run("reboot"))
        await fixture.approvals.decide(first.id, .deny)
        let deniedReply = try #require(await denied.value)
        #expect(deniedReply.error?.code == .denied)
        #expect(deniedReply.error?.message == "The user denied this command in AeroOps. Do not retry it unchanged.")

        let (timed, _) = try await fixture.pendingCall(Self.run("uptime"))
        fixture.clock.advance(by: 61)
        let timedReply = try #require(await timed.value)
        #expect(timedReply.error?.code == .approvalTimedOut)
        #expect(timedReply.error?.message == "Nobody approved the command in AeroOps within 60 seconds, so it was denied.")
        #expect(fixture.runner.calls.isEmpty)
        #expect(await fixture.auditEntries().map(\.decision) == [.denied, .approvalTimedOut])
    }

    @Test func agentCancelWhileWaitingRemovesTheApproval() async throws {
        let fixture = try Fixture()
        let (task, pending) = try await fixture.pendingCall(Self.run("uptime"))
        task.cancel()
        #expect(await task.value == nil, "a cancelled call has no reply")
        #expect(await fixture.approvals.pending(pending.id) == nil)
        #expect(fixture.runner.calls.isEmpty)
        let entry = try #require(await fixture.auditEntries().last)
        #expect(entry.decision == .cancelled && entry.outcome == .cancelledByAgent)
    }

    @Test func agentCancelWhileRunningKillsTheCommand() async throws {
        let fixture = try Fixture(runner: FakeRunner(.hang(seconds: 60)))
        let (task, pending) = try await fixture.pendingCall(Self.run("sleep 60"))
        await fixture.approvals.decide(pending.id, .allowOnce)
        #expect(await eventually { fixture.runner.calls.count == 1 })
        task.cancel()
        #expect(await task.value == nil)
        #expect(fixture.runner.cancellations == 1)
        #expect(await fixture.auditEntries().last?.outcome == .cancelledByAgent)
    }

    @Test func hostWindowSkipsPromptsExceptSudo() async throws {
        let fixture = try Fixture()
        let (first, pending) = try await fixture.pendingCall(Self.run("uptime"))
        await fixture.approvals.decide(pending.id, .allowHost15Min)
        #expect(try #require(await first.value).ok)

        let second = try #require(await fixture.call("run_command", Self.run("free -m")))
        #expect(second.ok, "covered by the window, no prompt")
        let (sudo, sudoPending) = try await fixture.pendingCall(Self.run("sudo systemctl restart nginx"))
        #expect(sudoPending.alwaysAskReasons == [.sudo])
        await fixture.approvals.decide(sudoPending.id, .deny)
        #expect(try #require(await sudo.value).error?.code == .denied)
        #expect(await fixture.auditEntries().map(\.decision) == [.approvedHostWindow, .allowedByWindow, .denied])
    }

    @Test func commandFailuresMapToToolErrors() async throws {
        let timedOut = try Fixture(runner: FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 143, timedOut: true))))
        let (t1, p1) = try await timedOut.pendingCall(Self.run("sleep 999", timeout: 5))
        await timedOut.approvals.decide(p1.id, .allowOnce)
        #expect(try #require(await t1.value).error == BridgeError(code: .timedOut, message: "The command did not finish within 5 seconds and was killed."))

        let ssh = try Fixture(runner: FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 255, transportFailure: "Permission denied (publickey)."))))
        let (t2, p2) = try await ssh.pendingCall(Self.run("uptime"))
        await ssh.approvals.decide(p2.id, .allowOnce)
        #expect(try #require(await t2.value).error == BridgeError(code: .sshFailed, message: "SSH failed: Permission denied (publickey)."))

        let nonZero = try Fixture(runner: FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 2, stderr: Data("no such file\n".utf8)))))
        let (t3, p3) = try await nonZero.pendingCall(Self.run("ls /nope"))
        await nonZero.approvals.decide(p3.id, .allowOnce)
        let reply = try #require(await t3.value)
        #expect(reply.ok, "a non-zero exit is a normal result")
        #expect(reply.structuredContent?["exitCode"]?.intValue == 2)
        #expect(reply.structuredContent?["stderr"]?.stringValue == "no such file\n")
    }
}
