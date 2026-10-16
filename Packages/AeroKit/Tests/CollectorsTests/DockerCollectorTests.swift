import AeroCore
import AeroTestSupport
import Foundation
import SSHKit
import Testing
@testable import Collectors

/// Names that must never reach a remote shell.
let dockerHostileNames = [
    "", "-v", "--privileged", "a b", "x;id", "x'y", "x\"y", "$(id)", "`id`", "x|y", "x&y", "x>y", "x\ny",
    "../etc", "a/b", "*", "~root", "café", "x\u{0}y",
]

@Suite("Docker commands")
struct DockerCommandTests {
    @Test("List runs ps and stats in one sh -c script with markers")
    func listCommand() {
        let inner = "docker ps -a --no-trunc --format '{{json .}}' || exit $?; echo @@aero-docker-stats; "
            + "docker stats --no-stream --format '{{json .}}' 2>/dev/null || echo @@aero-docker-stats-failed"
        #expect(DockerCommands.list(sudo: false) == "LC_ALL=C sh -c " + ShellQuote.quote(inner))
        #expect(!DockerCommands.list(includeStopped: false, sudo: false).contains(" ps -a "))
    }

    @Test("sudo -n prefixes every docker invocation when dockerSudo is on")
    func sudoPrefix() throws {
        let list = DockerCommands.list(sudo: true)
        #expect(list.contains("sudo -n docker ps -a"))
        #expect(list.contains("sudo -n docker stats --no-stream"))
        #expect(try DockerCommands.logs(container: "demo-web", tail: 10, sudo: true)
            == "LC_ALL=C sudo -n docker logs --tail 10 --timestamps 'demo-web' 2>&1")
        #expect(try DockerCommands.inspect(container: "demo-web", sudo: true)
            == "LC_ALL=C sudo -n docker inspect --type container 'demo-web'")
    }

    @Test("Logs: tail, timestamps, since, follow, quoted name, stderr merged")
    func logsCommand() throws {
        #expect(try DockerCommands.logs(container: "demo-logger", tail: 500, sudo: false)
            == "LC_ALL=C docker logs --tail 500 --timestamps 'demo-logger' 2>&1")
        #expect(try DockerCommands.logs(container: "demo_logger.1", tail: 9999, sinceSeconds: 90, follow: true, sudo: false)
            == "LC_ALL=C docker logs -f --tail 2000 --timestamps --since 90s 'demo_logger.1' 2>&1")
        #expect(try DockerCommands.logs(container: "abc123", tail: -5, follow: true, sudo: false)
            == "LC_ALL=C docker logs -f --tail 0 --timestamps 'abc123' 2>&1")
        #expect(try DockerCommands.terminalFollow(container: "demo-logger", sudo: false)
            == "docker logs -f --tail 100 --timestamps 'demo-logger'")
    }

    @Test("Hostile names and bad since values are rejected", arguments: dockerHostileNames)
    func hostileNames(name: String) {
        #expect(throws: CollectorInputError.unsafeName(field: "container", value: name)) {
            try DockerCommands.logs(container: name, tail: 10, sudo: false)
        }
        #expect(throws: CollectorInputError.unsafeName(field: "container", value: name)) {
            try DockerCommands.inspect(container: name, sudo: false)
        }
        #expect(throws: CollectorInputError.unsafeName(field: "container", value: name)) {
            try DockerCommands.terminalFollow(container: name, sudo: false)
        }
    }

    @Test("Stop, restart and remove: quoted name, sudo, rm -f")
    func actionCommands() throws {
        #expect(try DockerCommands.action(.stop, container: "demo-web", sudo: false) == "LC_ALL=C docker stop 'demo-web'")
        #expect(try DockerCommands.action(.restart, container: "demo-web", sudo: true) == "LC_ALL=C sudo -n docker restart 'demo-web'")
        #expect(try DockerCommands.action(.remove, container: "0123abcd", sudo: false) == "LC_ALL=C docker rm -f '0123abcd'")
        for action in DockerContainerAction.allCases {
            #expect(throws: CollectorInputError.unsafeName(field: "container", value: "x;id")) {
                try DockerCommands.action(action, container: "x;id", sudo: false)
            }
        }
    }

    @Test("since must be positive")
    func badSince() {
        #expect(throws: CollectorInputError.invalidSince(0)) {
            try DockerCommands.logs(container: "demo-web", tail: 10, sinceSeconds: 0, sudo: false)
        }
    }

    @Test("The list script really runs under sh and passes docker the right arguments")
    func listUnderRealShell() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aero-docker-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A stub docker that prints its arguments, one per line, prefixed with the subcommand.
        let stub = dir.appending(path: "docker")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s|%s\\n' \"$1\" \"$a\"; done\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", DockerCommands.list(sudo: false)]
        process.environment = ["PATH": dir.path + ":/usr/bin:/bin"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines == [
            "ps|ps", "ps|-a", "ps|--no-trunc", "ps|--format", "ps|{{json .}}",
            "@@aero-docker-stats",
            "stats|stats", "stats|--no-stream", "stats|--format", "stats|{{json .}}",
        ])
    }

    @Test("Splitting list output")
    func splitListOutput() {
        let both = DockerCommands.splitListOutput("{\"a\":1}\n@@aero-docker-stats\n{\"b\":2}\n")
        #expect(both.ps == "{\"a\":1}")
        #expect(both.stats == "{\"b\":2}\n")
        #expect(!both.statsFailed)

        let failed = DockerCommands.splitListOutput("{\"a\":1}\n@@aero-docker-stats\n@@aero-docker-stats-failed\n")
        #expect(failed.statsFailed)
        #expect(failed.stats.allSatisfy { $0.isWhitespace })

        let empty = DockerCommands.splitListOutput("@@aero-docker-stats\n")
        #expect(empty.ps.isEmpty)

        let noMarker = DockerCommands.splitListOutput("{\"a\":1}\n")
        #expect(noMarker.ps == "{\"a\":1}\n")
        #expect(noMarker.stats.isEmpty)
    }
}

@Suite("DockerCollector")
struct DockerCollectorTests {
    private func listOutput(ps: String, stats: String) -> String {
        ps + "@@aero-docker-stats\n" + stats
    }

    @Test("Lists containers with CPU and memory merged from stats")
    func listsContainers() async throws {
        let output = listOutput(ps: try Fixtures.string("docker/ps-a.jsonl"), stats: try Fixtures.string("docker/stats.jsonl"))
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(output))
        let host = ProbeTestData.host()

        let rows = try await DockerCollector(runner: runner).containers(on: host)

        #expect(rows.map(\.name).sorted() == ["demo-exited", "demo-logger", "demo-web"])
        let running = rows.filter { $0.state == .running }
        #expect(running.count == 2)
        #expect(running.allSatisfy { $0.cpuPercent != nil && $0.memUsedBytes != nil })
        #expect(rows.first { $0.name == "demo-exited" }?.cpuPercent == nil)
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.command == DockerCommands.list(sudo: false))
        #expect(runner.calls.first?.hostID == host.id)
    }

    @Test("A failing docker stats still returns the list")
    func statsFailure() async throws {
        let output = try Fixtures.string("docker/ps-a.jsonl") + "@@aero-docker-stats\n@@aero-docker-stats-failed\n"
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(output))
        let rows = try await DockerCollector(runner: runner).containers(on: ProbeTestData.host())
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.cpuPercent == nil })
    }

    @Test("The host's dockerSudo setting switches to sudo -n docker")
    func usesHostSudo() async throws {
        let output = listOutput(ps: try Fixtures.string("docker/ps-a-via-sudo.jsonl"), stats: "")
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(output))
        _ = try await DockerCollector(runner: runner).containers(on: ProbeTestData.host(dockerSudo: true))
        #expect(runner.commands == [DockerCommands.list(sudo: true)])
    }

    @Test("Permission denied maps to DockerError.permissionDenied with the group hint")
    func permissionDenied() async throws {
        let runner = ProbeScriptedRunner(result: try ProbeTestData.errorFixture("docker/error-permission-denied.txt"))
        let error = await #expect(throws: DockerError.self) {
            try await DockerCollector(runner: runner).containers(on: ProbeTestData.host())
        }
        #expect(error == .permissionDenied(socket: "unix:///var/run/docker.sock"))
        #expect(error?.hint?.contains("docker group") == true)
        #expect(error?.hint?.contains("sudo -n") == true)
    }

    @Test("Errors on stdout (2>&1) are classified too")
    func errorOnStdout() async throws {
        let runner = ProbeScriptedRunner(result: try ProbeTestData.errorFixture("docker/error-permission-denied.txt", onStdout: true))
        await #expect(throws: DockerError.permissionDenied(socket: "unix:///var/run/docker.sock")) {
            try await DockerCollector(runner: runner).logs(of: "demo-web", on: ProbeTestData.host())
        }
    }

    @Test("sudo without a NOPASSWD rule maps to sudoRefused")
    func sudoRefused() async throws {
        let runner = ProbeScriptedRunner(result: try ProbeTestData.errorFixture("kubectl/error-sudo-not-allowed.txt"))
        let error = await #expect(throws: DockerError.self) {
            try await DockerCollector(runner: runner).containers(on: ProbeTestData.host(dockerSudo: true))
        }
        #expect(error == .sudoRefused)
        #expect(error?.hint != nil)
    }

    @Test("Missing docker maps to notInstalled; ssh failures stay SSHError")
    func otherFailures() async throws {
        let missing = ProbeScriptedRunner(result: ProbeTestData.failure(exitCode: 127, stderr: "sh: 1: docker: not found\n"))
        await #expect(throws: DockerError.notInstalled) {
            try await DockerCollector(runner: missing).containers(on: ProbeTestData.host())
        }
        let auth = ProbeScriptedRunner(result: ProbeTestData.failure(exitCode: 255, stderr: "dev@vm: Permission denied (publickey).\n"))
        await #expect(throws: SSHError.authFailed) {
            try await DockerCollector(runner: auth).containers(on: ProbeTestData.host())
        }
        let slow = ProbeScriptedRunner(result: SSHResult(exitCode: 143, signal: nil, timedOut: true))
        await #expect(throws: SSHError.timeout) {
            try await DockerCollector(runner: slow).logs(of: "demo-web", on: ProbeTestData.host())
        }
    }

    @Test("Logs are ANSI-stripped, the command is quoted and tail is at least 1")
    func logs() async throws {
        let raw = try Fixtures.string("docker/logs-demo-logger.txt")
        #expect(raw.contains("\u{1B}["))
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(raw))

        let text = try await DockerCollector(runner: runner).logs(of: "demo-logger", on: ProbeTestData.host(), tail: 0)

        #expect(!text.text.contains("\u{1B}"))
        #expect(text.text.contains("WARN  slow query"))
        #expect(!text.truncated)
        #expect(runner.commands == ["LC_ALL=C docker logs --tail 1 --timestamps 'demo-logger' 2>&1"])
    }

    @Test("Logs report truncation by line cap and by ssh output cap")
    func logsTruncation() async throws {
        let many = (1...2500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let capped = try await DockerCollector(runner: ProbeScriptedRunner(result: ProbeTestData.ok(many)))
            .logs(of: "demo-logger", on: ProbeTestData.host(), tail: 2000)
        #expect(capped.truncated)
        #expect(capped.text.hasPrefix("line 501\n"))

        let cut = SSHResult(exitCode: 0, stdout: Data("a\nb\n".utf8), stdoutTruncated: true)
        let sshCapped = try await DockerCollector(runner: ProbeScriptedRunner(result: cut))
            .logs(of: "demo-logger", on: ProbeTestData.host())
        #expect(sshCapped.truncated)
    }

    @Test("Hostile names never reach the runner", arguments: dockerHostileNames)
    func hostileNamesRejected(name: String) async {
        let runner = ProbeScriptedRunner()
        let docker = DockerCollector(runner: runner)
        let host = ProbeTestData.host()
        await #expect(throws: CollectorInputError.self) { try await docker.logs(of: name, on: host) }
        await #expect(throws: CollectorInputError.self) { try await docker.followLogs(of: name, on: host) }
        await #expect(throws: CollectorInputError.self) { try await docker.inspect(name, on: host) }
        await #expect(throws: CollectorInputError.self) { try await docker.perform(.remove, on: name, host: host) }
        #expect(runner.calls.isEmpty)
    }

    @Test("Actions run once with the long timeout; docker's error is classified")
    func actions() async throws {
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok("demo-web\n"))
        try await DockerCollector(runner: runner).perform(.stop, on: "demo-web", host: ProbeTestData.host())
        #expect(runner.commands == ["LC_ALL=C docker stop 'demo-web'"])
        #expect(runner.calls.first?.timeout == DockerCollector.actionTimeout)

        let missing = ProbeScriptedRunner(result: ProbeTestData.failure(stderr: "Error response from daemon: No such container: nope\n"))
        let error = await #expect(throws: DockerError.self) {
            try await DockerCollector(runner: missing).perform(.restart, on: "nope", host: ProbeTestData.host())
        }
        guard case .failed(let message)? = error else {
            Issue.record("expected .failed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("No such container"))
    }

    @Test("Inspect returns the summary and the raw JSON")
    func inspect() async throws {
        let json = try Fixtures.data("docker/inspect-demo-web.json")
        let runner = ProbeScriptedRunner(result: SSHResult(exitCode: 0, stdout: json))

        let inspection = try await DockerCollector(runner: runner).inspect("demo-web", on: ProbeTestData.host())

        #expect(inspection.summary.name == "demo-web")
        #expect(inspection.summary.healthCheck == .healthy)
        #expect(inspection.json == json)
        #expect(runner.commands == ["LC_ALL=C docker inspect --type container 'demo-web'"])
    }

    @Test("Inspect of an unknown container fails with docker's message")
    func inspectUnknown() async throws {
        let missing = ProbeScriptedRunner(result: ProbeTestData.failure(stderr: "Error: No such container: nope\n"))
        let error = await #expect(throws: DockerError.self) {
            try await DockerCollector(runner: missing).inspect("nope", on: ProbeTestData.host())
        }
        guard case .failed(let message)? = error else {
            Issue.record("expected .failed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("No such container"))

        let empty = ProbeScriptedRunner(result: ProbeTestData.ok("[]\n"))
        await #expect(throws: DockerError.self) {
            try await DockerCollector(runner: empty).inspect("demo-web", on: ProbeTestData.host())
        }
    }
}

@Suite("Docker follow")
struct DockerFollowTests {
    @Test("Follow streams ANSI-stripped lines under the watchdog")
    func followLines() async throws {
        let runner = ProbeScriptedRunner(stream: { _ in
            .init(lines: ["\u{1B}[32mINFO\u{1B}[0m one", "two\r"], end: .finish)
        })
        let stream = try await DockerCollector(runner: runner).followLogs(of: "demo-logger", on: ProbeTestData.host())
        var lines: [String] = []
        for try await line in stream { lines.append(line) }

        #expect(lines == ["INFO one", "two"])
        let expected = LogFollowStream.remoteCommand("LC_ALL=C docker logs -f --tail 100 --timestamps 'demo-logger' 2>&1")
        #expect(runner.calls.map(\.command) == [expected])
        #expect(runner.calls.first?.streamed == true)
        #expect(runner.calls.first?.timeout == nil)
    }

    @Test("Cancelling the consumer cancels the ssh stream")
    func cancelKillsStream() async throws {
        let runner = ProbeScriptedRunner(stream: { _ in .init(lines: ["a", "b", "c"], end: .hang) })
        let stream = try await DockerCollector(runner: runner).followLogs(of: "demo-logger", on: ProbeTestData.host())
        let received = AsyncStream<String>.makeStream()
        let consumer = Task {
            for try await line in stream { received.continuation.yield(line) }
        }
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next() == "a")
        #expect(runner.cancelledStreams == 0)

        consumer.cancel()
        _ = await consumer.result
        #expect(await runner.waitUntil { $0.cancelledStreams == 1 })
    }

    @Test("Dropping the stream after break cancels the ssh stream")
    func breakKillsStream() async throws {
        let runner = ProbeScriptedRunner(stream: { _ in .init(lines: ["a", "b", "c"], end: .hang) })
        let docker = DockerCollector(runner: runner)
        let host = ProbeTestData.host()
        let first = try await Task { () async throws -> String? in
            let stream = try await docker.followLogs(of: "demo-logger", on: host)
            for try await line in stream { return line }
            return nil
        }.value
        #expect(first == "a")
        #expect(await runner.waitUntil { $0.cancelledStreams == 1 })
    }

    @Test("A failing follow throws the classified DockerError (error text came on stdout)")
    func followFailure() async throws {
        let message = "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock"
        let runner = ProbeScriptedRunner(stream: { _ in
            .init(lines: [message], end: .fail(.remoteCommandFailed(exitCode: 1, stderr: "")))
        })
        let stream = try await DockerCollector(runner: runner).followLogs(of: "demo-web", on: ProbeTestData.host())
        await #expect(throws: DockerError.permissionDenied(socket: "unix:///var/run/docker.sock")) {
            for try await _ in stream {}
        }
    }

    @Test("Transport failures during follow stay SSHError")
    func followTransportFailure() async throws {
        let runner = ProbeScriptedRunner(stream: { _ in .init(lines: [], end: .fail(.connectionClosed)) })
        let stream = try await DockerCollector(runner: runner).followLogs(of: "demo-web", on: ProbeTestData.host())
        await #expect(throws: SSHError.connectionClosed) {
            for try await _ in stream {}
        }
    }
}
