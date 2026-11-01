import AeroCore
import AeroTestSupport
import Foundation
import Testing
@testable import AgentBridge
@testable import SSHKit

/// `run_command` over real ssh with a ControlMaster, against the dev servers
/// (`docker compose -f dev/compose.yml up -d`): dev@localhost:2222 (OpenSSH, bash login shell)
/// and dev@localhost:2223 (BusyBox, `sh` login shell).
/// Run with `AEROOPS_INTEGRATION=1 swift test --package-path Packages/AeroKit --filter RunCommandIntegration`.
///
/// Proves that cancel and timeout end the remote command, not just the local ssh: under a
/// ControlMaster, killing ssh only closes the command's stdout, and a quiet `sleep 120` would
/// live on without the wrapper's watchdog.
///
/// Test-only setup, as in SSHKit's integration test: a throwaway Ed25519 key in a private temp
/// dir, authorized with `dev/add-key.sh`, de-authorized and deleted afterwards.
@Suite(
    "run_command integration (dev servers)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AEROOPS_INTEGRATION"] == "1")
)
struct RunCommandIntegrationTests {
    struct Server: Sendable, CustomStringConvertible {
        var container: String
        var authorizedKeys: String
        var host: RemoteHost
        var description: String { "\(host.user)@\(host.address):\(host.port)" }
    }

    static let servers = [
        Server(container: "aeroops-ssh", authorizedKeys: "/config/.ssh/authorized_keys",
               host: RemoteHost(name: "dev", address: "localhost", port: 2222, user: "dev", mcpTier: .readExec)),
        Server(container: "aeroops-alpine", authorizedKeys: "/home/dev/.ssh/authorized_keys",
               host: RemoteHost(name: "alpine", address: "localhost", port: 2223, user: "dev", mcpTier: .readExec)),
    ]

    @Test("Cancel and timeout kill the remote command under a ControlMaster")
    func cancelAndTimeoutEndTheRemoteCommand() async throws {
        let scratch = try TempDirectory()
        defer { scratch.remove() }
        let repo = try Fixtures.repoRoot()
        let tag = "aero-rc-" + String(UInt32.random(in: 0...UInt32.max), radix: 16)

        let keyFile = scratch.appending("id")
        let keygen = try await LocalProcess.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", tag, "-f", keyFile.path(percentEncoded: false)])
        try #require(keygen.status == 0, "\(keygen.stdout)")
        let publicKey = try String(contentsOf: scratch.appending("id.pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let added = try await LocalProcess.run("/bin/sh", [repo.appending(path: "dev/add-key.sh").path(percentEncoded: false), scratch.appending("id.pub").path(percentEncoded: false)])
        try #require(added.status == 0, "\(added.stdout)")

        let context = SSHContext(paths: AeroPaths(dotDirectory: scratch.appending("d")))
        do {
            var writer = SSHConfigWriter(context: context)
            writer.identity = .privateKeyFileForTesting(keyFile)
            try writer.write(Self.servers.map(\.host))
            let store = HostKeyStore(context: context, keychain: InMemoryKeychain())
            for server in Self.servers {
                guard case .unknown(let offered) = try await store.verify(server.host) else {
                    Issue.record("\(server): expected an unknown host key")
                    continue
                }
                try await store.trust(try #require(offered.first { $0.type == "ssh-ed25519" }), for: server.host)
            }
            let runner = SSHRunner(context: context, hostKeys: store)
            for server in Self.servers {
                try await scenario(server, runner: runner, context: context, tag: tag)
            }
        } catch {
            await cleanUp(context: context, publicKey: publicKey)
            throw error
        }
        await cleanUp(context: context, publicKey: publicKey)
    }

    private func scenario(_ server: Server, runner: SSHRunner, context: SSHContext, tag: String) async throws {
        let host = server.host
        let executor = CommandExecutor(runner: SSHCommandRunner(runner: runner), heartbeatSeconds: 1)

        // Normal runs: output (heartbeats removed), stderr, exit status, quoting.
        let normal = try await executor.execute("echo hi; sleep 2; echo bye", on: host, timeoutSeconds: 30)
        #expect(normal.stdout == "hi\nbye\n" && normal.exitCode == 0, "\(server): \(normal)")
        #expect(normal.durationMs >= 2000)
        let failing = try await executor.execute(#"printf '%s|' "it's" '$(id)'; echo oops >&2; exit 7"#, on: host, timeoutSeconds: 30)
        #expect(failing.exitCode == 7 && failing.stdout == "it's|$(id)|" && failing.stderr == "oops\n", "\(server): \(failing)")

        // Everything below runs over the ControlMaster the first command opened.
        guard case .running = try await ControlMaster(context: context).check(host) else {
            Issue.record("\(server): no ControlMaster running")
            return
        }

        // Agent cancel of a quiet `sleep 120`.
        let cancelMarker = "\(tag)-cancel"
        let call = Task { try await executor.execute("sleep 120; echo \(cancelMarker)", on: host, timeoutSeconds: 300) }
        let started = await eventually(timeout: .seconds(15)) {
            (try? await remoteProcesses(matching: cancelMarker, on: host, runner: runner))?.isEmpty == false
        }
        #expect(started, "\(server): the command never showed up in ps")
        let before = try await remoteProcesses(matching: "sleep 120", on: host, runner: runner)
        #expect(!before.isEmpty, "\(server): ps shows no sleep 120 while it runs")
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        let cancelled = await eventually(timeout: .seconds(10)) {
            let marked = try? await remoteProcesses(matching: cancelMarker, on: host, runner: runner)
            let sleeps = try? await remoteProcesses(matching: "sleep 120", on: host, runner: runner)
            return marked?.isEmpty == true && sleeps?.isEmpty == true
        }
        let leftovers = (try? await remoteProcesses(matching: "sleep 120", on: host, runner: runner)) ?? []
        #expect(cancelled, "\(server): still running after cancel: \(leftovers)")

        // Timeout of the same quiet command.
        let timeoutMarker = "\(tag)-timeout"
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CommandExecutionError.timedOut(seconds: 2)) {
            try await executor.execute("sleep 120; echo \(timeoutMarker)", on: host, timeoutSeconds: 2)
        }
        #expect(clock.now - start < .seconds(10))
        let timedOut = await eventually(timeout: .seconds(10)) {
            let marked = try? await remoteProcesses(matching: timeoutMarker, on: host, runner: runner)
            let sleeps = try? await remoteProcesses(matching: "sleep 120", on: host, runner: runner)
            return marked?.isEmpty == true && sleeps?.isEmpty == true
        }
        #expect(timedOut, "\(server): still running after the timeout")
        print("run_command integration \(server): cancel and timeout left no remote process")

        // Control, for the record only: the same command without the wrapper, cancelled the same
        // way, outlives its ssh under the ControlMaster.
        let controlMarker = "\(tag)-control"
        let raw = Task { try await runner.run("sleep 120; echo \(controlMarker)", on: host, timeout: .seconds(300)) }
        await eventually(timeout: .seconds(15)) {
            (try? await remoteProcesses(matching: controlMarker, on: host, runner: runner))?.isEmpty == false
        }
        raw.cancel()
        _ = try? await raw.value
        try await Task.sleep(for: .seconds(4))
        let survivors = (try? await remoteProcesses(matching: controlMarker, on: host, runner: runner)) ?? []
        print("run_command integration \(server): without the wrapper the cancelled command \(survivors.isEmpty ? "ended as well" : "is still running: \(survivors)")")
        // Clean up the control's process group: the shell and its sleep.
        let pids = survivors.compactMap { $0.split(separator: " ").first.flatMap { Int($0) } }
        if !pids.isEmpty {
            _ = try? await runner.run("pkill -KILL -P \(pids.map(String.init).joined(separator: ",")); kill -KILL \(pids.map(String.init).joined(separator: " ")) 2>/dev/null; true", on: host)
        }
        #expect(await eventually(timeout: .seconds(5)) {
            (try? await remoteProcesses(matching: controlMarker, on: host, runner: runner))?.isEmpty == true
        })
    }

    /// `ps -A -o pid,args` lines containing `text`, without the ps pipeline itself.
    private func remoteProcesses(matching text: String, on host: RemoteHost, runner: SSHRunner) async throws -> [String] {
        let result = try await runner.run("ps -A -o pid,args", on: host, timeout: .seconds(10))
        guard result.succeeded else { throw TestFailure("ps failed: \(result.stderrString)") }
        return result.stdoutString.split(separator: "\n").map(String.init).filter { $0.contains(text) && !$0.contains("ps -A") }
    }

    private func cleanUp(context: SSHContext, publicKey: String) async {
        await ControlMaster(context: context).closeAll()
        let script = #"f=$1; k=$2; grep -vxF "$k" "$f" > "$f.tmp" || true; cat "$f.tmp" > "$f"; rm -f "$f.tmp""#
        for server in Self.servers {
            let removed = try? await LocalProcess.run("/usr/bin/env", ["docker", "exec", server.container, "sh", "-c", script, "sh", server.authorizedKeys, publicKey])
            #expect(removed?.status == 0, "could not de-authorize the test key on \(server.container): \(removed?.stdout ?? "-")")
        }
    }
}
