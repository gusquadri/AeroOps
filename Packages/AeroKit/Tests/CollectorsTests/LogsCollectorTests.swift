import AeroCore
import AeroTestSupport
import Foundation
import SSHKit
import Testing
@testable import Collectors

@Suite("LogCollector")
struct LogsCollectorTests {
    private let host = ProbeTestData.host(kubectlPrefix: "sudo -n k3s kubectl")

    @Test("Container requests run docker logs")
    func containerRequest() async throws {
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok("\u{1B}[31mERROR\u{1B}[0m boom\n"))
        let request = LogRequest(hostId: host.id, kind: .container, name: "demo-logger", tail: 5000, sinceSeconds: 30)

        let text = try await LogCollector(runner: runner).fetch(request, on: host)

        #expect(text == CappedText(text: "ERROR boom\n", truncated: false))
        #expect(runner.commands == ["LC_ALL=C docker logs --tail 2000 --timestamps --since 30s 'demo-logger' 2>&1"])
    }

    @Test("Pod requests run kubectl logs; namespace defaults to default")
    func podRequest() async throws {
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok("hello\n"))
        let logs = LogCollector(runner: runner)

        _ = try await logs.fetch(LogRequest(hostId: host.id, kind: .pod, name: "hello-894fb", tail: 20), on: host)
        _ = try await logs.fetch(
            LogRequest(hostId: host.id, kind: .pod, name: "crasher-1", namespace: "demo", container: "crasher", previous: true),
            on: host
        )

        #expect(runner.commands == [
            "LC_ALL=C sudo -n k3s kubectl logs -n 'default' 'hello-894fb' --tail=20 --timestamps",
            "LC_ALL=C sudo -n k3s kubectl logs -n 'demo' 'crasher-1' -c 'crasher' --previous --tail=500 --timestamps",
        ])
    }

    @Test("Container requests ignore namespace and container")
    func containerIgnoresPodFields() async throws {
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(""))
        let request = LogRequest(hostId: host.id, kind: .container, name: "demo-web", namespace: "x y", container: "$(id)")
        _ = try await LogCollector(runner: runner).fetch(request, on: host)
        #expect(runner.commands == ["LC_ALL=C docker logs --tail 500 --timestamps 'demo-web' 2>&1"])
    }

    @Test("Output is capped at 2,000 lines with the truncated flag")
    func capped() async throws {
        let many = (1...2600).map { "\u{1B}[1mline\u{1B}[0m \($0)" }.joined(separator: "\n") + "\n"
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(many))
        let text = try await LogCollector(runner: runner)
            .fetch(LogRequest(hostId: host.id, kind: .container, name: "demo-logger", tail: 2000), on: host)
        #expect(text.truncated)
        #expect(text.text.split(separator: "\n").count == 2000)
        #expect(text.text.hasPrefix("line 601\n"))
        #expect(text.text.hasSuffix("line 2600\n"))
    }

    @Test("Invalid requests are rejected before ssh", arguments: [
        ("hostile pod", LogRequest(hostId: UUID(), kind: .pod, name: "web;id")),
        ("hostile namespace", LogRequest(hostId: UUID(), kind: .pod, name: "web", namespace: "../x")),
        ("hostile container", LogRequest(hostId: UUID(), kind: .pod, name: "web", container: "-c")),
        ("hostile docker name", LogRequest(hostId: UUID(), kind: .container, name: "$(reboot)")),
        ("zero since", LogRequest(hostId: UUID(), kind: .pod, name: "web", sinceSeconds: 0)),
        ("previous for docker", LogRequest(hostId: UUID(), kind: .container, name: "demo-web", previous: true)),
    ])
    func rejected(label: String, request: LogRequest) async {
        var request = request
        request.hostId = host.id
        let runner = ProbeScriptedRunner()
        let logs = LogCollector(runner: runner)
        await #expect(throws: CollectorInputError.self, "\(label)") { try await logs.fetch(request, on: host) }
        await #expect(throws: CollectorInputError.self, "\(label)") { try await logs.follow(request, on: host) }
        #expect(runner.calls.isEmpty)
    }

    @Test("A request for another host is rejected")
    func hostMismatch() async {
        let runner = ProbeScriptedRunner()
        let request = LogRequest(hostId: UUID(), kind: .container, name: "demo-web")
        await #expect(throws: CollectorInputError.hostMismatch) {
            try await LogCollector(runner: runner).fetch(request, on: host)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test("previous cannot be followed")
    func previousNotFollowed() async {
        let request = LogRequest(hostId: host.id, kind: .pod, name: "crasher-1", namespace: "demo", previous: true, follow: true)
        await #expect(throws: CollectorInputError.self) {
            try await LogCollector(runner: ProbeScriptedRunner()).follow(request, on: host)
        }
    }

    @Test("Follow uses the request's tail and kind")
    func follow() async throws {
        let runner = ProbeScriptedRunner(stream: { _ in .init(lines: ["a"], end: .finish) })
        let logs = LogCollector(runner: runner)
        for try await _ in try await logs.follow(LogRequest(hostId: host.id, kind: .container, name: "demo-logger", tail: 37), on: host) {}
        for try await _ in try await logs.follow(LogRequest(hostId: host.id, kind: .pod, name: "web-1", namespace: "demo", tail: 5), on: host) {}
        #expect(runner.commands == [
            LogFollowStream.remoteCommand("LC_ALL=C docker logs -f --tail 37 --timestamps 'demo-logger' 2>&1"),
            LogFollowStream.remoteCommand("LC_ALL=C sudo -n k3s kubectl logs -f -n 'demo' 'web-1' --tail=5 --timestamps"),
        ])
        #expect(runner.calls.allSatisfy { $0.streamed })
    }

    @Test("Follow lines drop heartbeats and ANSI, and split on carriage returns", arguments: [
        ("plain", ["plain"]),
        ("", [""]),
        ("\u{06}", []),
        ("\u{06}\u{06}\u{06}", []),
        ("\u{06}\u{06}\u{1B}[32mINFO\u{1B}[0m ok", ["INFO ok"]),
        ("a\rb", ["a", "b"]),
        ("two\r", ["two"]),
    ])
    func cleanLines(line: String, expected: [String]) {
        #expect(LogFollowStream.cleanLines(line) == expected)
    }

    @Test("Error messages never echo control characters")
    func errorPreview() {
        let error = CollectorInputError.unsafeName(field: "pod", value: "a\nb\u{1B}[31m")
        #expect(error.errorDescription?.contains("\n") == false)
        #expect(error.errorDescription?.contains("\u{1B}") == false)
    }
}

/// Runs the watchdog script under real local shells. Stands in for the remote side: closing the
/// read end of the stderr pipe is what sshd does when the ssh channel closes.
@Suite("Follow watchdog", .serialized)
struct LogsWatchdogTests {
    static let shells = ["/bin/sh", "/bin/dash", "/bin/bash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    @Test("The script parses", arguments: shells)
    func syntax(shell: String) throws {
        let script = LogFollowStream.watchdogScript("LC_ALL=C docker logs -f --tail 100 --timestamps 'demo-logger' 2>&1")
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-n", "-c", script]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("Passes stdout through and keeps the command's exit status", arguments: shells)
    func passThrough(shell: String) throws {
        let run = try Self.launch(shell: shell, command: "printf 'one\\ntwo\\n'; exit 3")
        let started = ContinuousClock.now
        let output = run.stdout.fileHandleForReading.readDataToEndOfFile()
        run.process.waitUntilExit()
        #expect(String(decoding: output, as: UTF8.self) == "one\ntwo\n")
        #expect(run.process.terminationStatus == 3)
        // The heartbeat's sleep must not hold stdout open after the command exits.
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("Heartbeats are single ACK bytes on stdout, nothing on stderr", arguments: shells)
    func heartbeat(shell: String) throws {
        let run = try Self.launch(shell: shell, command: "sleep 2; echo done")
        let output = run.stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = run.stderr.fileHandleForReading.readDataToEndOfFile()
        run.process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.unicodeScalars.contains(LogFollowStream.heartbeat))
        #expect(text.unicodeScalars.allSatisfy { $0 == LogFollowStream.heartbeat || "done\n".unicodeScalars.contains($0) })
        #expect(errors.isEmpty)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { LogFollowStream.cleanLines(String($0)) }
            .filter { !$0.isEmpty }
        #expect(lines == ["done"])
    }

    @Test("Kills a quiet command once stdout's reader is gone", arguments: shells)
    func killsQuietCommand(shell: String) async throws {
        let run = try Self.launch(shell: shell, command: "sleep 30")
        try run.stdout.fileHandleForReading.close()
        let deadline = ContinuousClock.now + .seconds(8)
        while run.process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let stillRunning = run.process.isRunning
        if stillRunning { run.process.terminate() }
        #expect(!stillRunning, "the watchdog did not stop `sleep 30` within 8 s")
    }

    private static func launch(shell: String, command: String) throws -> (process: Process, stdout: Pipe, stderr: Pipe) {
        // `command` here is a compound list, so wrap it in a subshell to keep the script valid.
        let script = LogFollowStream.watchdogScript("(\(command))", heartbeatSeconds: 1)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return (process, stdout, stderr)
    }
}
