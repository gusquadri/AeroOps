import AeroCore
import BridgeProtocol
import Foundation
import Synchronization
import Testing
@testable import AgentBridge

/// The whole pipeline (tool → arguments → host → policy → handler/executor)
/// through `Bridge.process`, with fakes for the host data, ssh and time.
@Suite("Bridge pipeline")
struct BridgePipelineTests {
    final class Fixture: Sendable {
        let dir: TempDirectory
        let clock = FakeClock()
        let handler: FakeToolHandler
        let runner: FakeRunner
        let bridge: Bridge

        init(handler: FakeToolHandler = FakeToolHandler(),
             runner: FakeRunner = FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 0, stdout: Data("OUTPUT-7f3a\n".utf8), duration: .milliseconds(15))))) throws {
            dir = try TempDirectory()
            self.handler = handler
            self.runner = runner
            bridge = Bridge(socketURL: dir.appending("bridge.sock"), handler: handler,
                            executor: CommandExecutor(runner: runner, clock: clock),
                            peerValidator: AcceptAllPeers(), clock: clock)
        }

        deinit { dir.remove() }

        func call(_ tool: String, _ arguments: [String: JSONValue] = [:], progress: Progress? = nil) async -> BridgeReply? {
            let request = BridgeRequest(id: 1, tool: tool, arguments: arguments,
                                        client: BridgeClientInfo(name: "claude-code", version: "2.1.296"), toolUseId: "toolu_x")
            return await bridge.process(request, peer: testPeer) { progress?.append($0) }
        }
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
    }

    @Test func readToolsReturnHandlerData() async throws {
        let fixture = try Fixture()
        let metrics = try #require(await fixture.call("get_host_metrics", ["host": "staging"]))
        #expect(metrics.structuredContent?["cpuPercent"] == .double(12.3))
        #expect(metrics.structuredContent?["host"]?.stringValue == "staging")
        let containers = try #require(await fixture.call("list_containers", ["host": "prod", "all": true]))
        #expect(containers.structuredContent?["containers"]?.arrayValue?.first?["name"]?.stringValue == "api")
        #expect(fixture.handler.calls == ["metrics staging", "containers prod true"])
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
    }

    @Test func handlerFailuresBecomeToolErrors() async throws {
        let fixture = try Fixture(handler: FakeToolHandler(failure: .unavailable("Docker is not installed on staging.")))
        let reply = try #require(await fixture.call("list_containers", ["host": "staging"]))
        #expect(reply.error == BridgeError(code: .unavailable, message: "Docker is not installed on staging."))
    }

    // MARK: run_command

    @Test func readTierRejectsRunCommand() async throws {
        let fixture = try Fixture()
        let reply = try #require(await fixture.call("run_command", Self.run("uptime", on: "prod")))
        #expect(reply.error?.code == .execNotAllowed)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func readExecRunsWithoutAsking() async throws {
        let fixture = try Fixture()
        let progress = Progress()
        let reply = try #require(await fixture.call("run_command", Self.run("df -h /", timeout: 20), progress: progress))
        #expect(reply.ok)
        #expect(reply.structuredContent?["exitCode"]?.intValue == 0)
        #expect(reply.structuredContent?["stdout"]?.stringValue == "OUTPUT-7f3a\n")
        #expect(progress.all == ["Running on staging"])
        let call = try #require(fixture.runner.calls.first)
        #expect(call.remoteCommand == RunCommandScript.remoteCommand("df -h /", timeoutSeconds: 20) && call.timeout == .seconds(20))

        // sudo and the like are up to the agent and the user too.
        let sudo = try #require(await fixture.call("run_command", Self.run("sudo systemctl restart nginx")))
        #expect(sudo.ok)
        #expect(fixture.runner.calls.count == 2)
    }

    @Test func agentCancelWhileRunningKillsTheCommand() async throws {
        let fixture = try Fixture(runner: FakeRunner(.hang(seconds: 60)))
        let task = Task { await fixture.call("run_command", Self.run("sleep 60")) }
        #expect(await eventually { fixture.runner.calls.count == 1 })
        task.cancel()
        #expect(await task.value == nil, "a cancelled call has no reply")
        #expect(fixture.runner.cancellations == 1)
    }

    @Test func commandFailuresMapToToolErrors() async throws {
        let timedOut = try Fixture(runner: FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 143, timedOut: true))))
        let t1 = try #require(await timedOut.call("run_command", Self.run("sleep 999", timeout: 5)))
        #expect(t1.error == BridgeError(code: .timedOut, message: "The command did not finish within 5 seconds and was killed."))

        let ssh = try Fixture(runner: FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 255, transportFailure: "Permission denied (publickey)."))))
        let t2 = try #require(await ssh.call("run_command", Self.run("uptime")))
        #expect(t2.error == BridgeError(code: .sshFailed, message: "SSH failed: Permission denied (publickey)."))

        let nonZero = try Fixture(runner: FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 2, stderr: Data("no such file\n".utf8)))))
        let reply = try #require(await nonZero.call("run_command", Self.run("ls /nope")))
        #expect(reply.ok, "a non-zero exit is a normal result")
        #expect(reply.structuredContent?["exitCode"]?.intValue == 2)
        #expect(reply.structuredContent?["stderr"]?.stringValue == "no such file\n")
    }
}
