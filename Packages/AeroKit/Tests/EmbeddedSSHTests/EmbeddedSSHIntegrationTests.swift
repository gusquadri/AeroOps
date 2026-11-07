import AeroCore
import AeroTestSupport
import Foundation
import KeyAgent
import Testing
@testable import Collectors
@testable import EmbeddedSSH
@testable import SSHKit

/// EmbeddedSSHClient end to end against dev@localhost:2222 (OpenSSH on Alpine with GNU tools)
/// and dev@localhost:2223 (BusyBox Alpine).
/// Run with `AEROOPS_INTEGRATION=1 swift test --package-path Packages/AeroKit --filter EmbeddedSSHIntegration`.
///
/// The client logs in the way the iOS app does: a KeyAgent Ed25519 key (its secret in an
/// in-memory store, never on disk), authorized with `dev/add-key.sh` for the test and revoked
/// with `dev/remove-key.sh` afterwards. Every failed or unauthenticated connection counts toward
/// sshd's `PerSourcePenalties` (which would lock this Mac out of the dev servers for every
/// client), so the test makes only a few on purpose and aborts on the first unexpected one.
@Suite(
    "EmbeddedSSH integration (dev servers)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AEROOPS_INTEGRATION"] == "1")
)
struct EmbeddedSSHIntegrationTests {
    /// The keys `dev/compose.yml`'s `ssh` service has; the Alpine server's are generated per volume.
    private static let devServerKeys: Set<String> = [
        "AAAAC3NzaC1lZDI1NTE5AAAAIPfVoGPvXD/pnZyxb+hG6xVPXZ4tyYudnqH3H3ZcLQ1B",
        "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHXA9dWWECl717zA/VBdIMT7eo113RpCbNaiYZ6mXuLj3tA6xmaDLlrbMSeGfW1THodsXuW/xGwk5sgWRlhS1hA=",
    ]

    private let servers = [
        RemoteHost(name: "dev", address: "localhost", port: 2222, user: "dev"),
        RemoteHost(name: "alpine", address: "localhost", port: 2223, user: "dev"),
    ]

    @Test("Host keys, commands, streams, concurrency, terminals, SFTP and monitoring on both dev servers")
    func endToEnd() async throws {
        let env = try TestEnvironment()
        let repo = try Fixtures.repoRoot()
        let record = try await env.keyStore.generate(.ed25519, name: "aero-e-it", comment: "aero-e-it", policy: .oncePerSession)
        let publicKey = env.scratch.file("id.pub")
        try Data((try await env.keyStore.authorizedKeysLine(for: record.id) + "\n").utf8).write(to: publicKey)

        let added = try await runTool("/bin/sh", [repo.appending(path: "dev/add-key.sh").filePath, publicKey.filePath])
        do {
            try #require(added.status == 0, "\(added.stdout)\(added.stderr)")
            for server in servers {
                try #require(added.stdout.contains("localhost:\(server.port)   authorized:"), "dev@localhost:\(server.port) is not running:\n\(added.stdout)")
            }
            try await scenario(env)
        } catch {
            await revoke(publicKey, repo: repo)
            throw error
        }
        await revoke(publicKey, repo: repo)
    }

    private func scenario(_ env: TestEnvironment) async throws {
        let client = env.client()
        for host in servers {
            try await hostKeys(client, env: env, host: host)
            try await commands(client, host: host)
            try await streams(client, host: host)
            try await concurrency(client, host: host)
            try await sessions(client, env: env, host: host)
        }
        #expect(env.verifier.reasons.count == 1, "\(env.verifier.reasons)")
        try await monitor(client, hostKeys: env.hostKeys)

        let unknown = try await env.keyStore.generate(.ed25519, name: "unauthorized", policy: .always)
        var stranger = servers[1]
        stranger.id = UUID()
        stranger.keyId = unknown.id.uuidString
        let pinned = try await env.hostKeys.pinnedKeys(for: servers[1])
        for key in pinned { try await env.hostKeys.trust(key, for: stranger) }
        await #expect(throws: SSHError.authFailed) { try await client.run("true", on: stranger) }
        await client.disconnectAll()
    }

    /// The scanner's key; then an unknown key, a changed one (which blocks the host) and the
    /// right one. Three unauthenticated connections per server.
    private func hostKeys(_ client: EmbeddedSSHClient, env: TestEnvironment, host: RemoteHost) async throws {
        let scanned = try await EmbeddedHostKeyScanner().scan(address: host.address, port: host.port)
        let key = try #require(scanned.first)
        #expect(scanned.count == 1)
        #expect(["ssh-ed25519", "ecdsa-sha2-nistp256"].contains(key.type))
        if host.port == 2222 { #expect(Self.devServerKeys.contains(key.blob.base64EncodedString())) }

        await #expect(throws: SSHError.hostKeyUnknown) { try await client.run("true", on: host) }

        let impostor = key.type == "ssh-ed25519" ? TestKeys.ed25519() : TestKeys.ecdsa256()
        try await env.hostKeys.trust(impostor, for: host)
        await #expect(throws: SSHError.hostKeyChanged) { try await client.run("true", on: host) }
        let block = try #require(await env.hostKeys.block(for: host))
        #expect(block.offered == [key])
        await #expect(throws: SSHError.hostKeyChanged) { try await client.run("true", on: host) }

        try await env.hostKeys.trust(key, for: host, replacingPinned: true)
        #expect(await !env.hostKeys.isBlocked(host))
    }

    private func commands(_ client: EmbeddedSSHClient, host: RemoteHost) async throws {
        let first = try await client.run("echo hello; echo oops >&2; exit 3", on: host)
        #expect(first.exitCode == 3)
        #expect(first.stdoutString == "hello\n")
        #expect(String(decoding: first.stderr, as: UTF8.self) == "oops\n")
        #expect(!first.timedOut)

        let cat = try await client.run("cat", on: host, stdin: Data("line one\nline two".utf8))
        #expect(cat.exitCode == 0)
        #expect(cat.stdoutString == "line one\nline two")

        let noInput = try await client.run("cat; echo done", on: host)
        #expect(noInput.stdoutString == "done\n", "stdin is at EOF without input")

        let big = try await client.run(
            "i=0; while [ $i -lt 500 ]; do echo 0123456789; i=$((i+1)); done", on: host, outputLimit: 1000
        )
        #expect(big.exitCode == 0)
        #expect(big.stdout.count == 1000)
        #expect(big.stdoutTruncated)
        #expect(!big.stderrTruncated)

        let slow = try await client.run("sleep 5", on: host, timeout: .seconds(1))
        #expect(slow.timedOut)
        #expect(slow.exitCode == 255)
        #expect(slow.duration < .seconds(3))

        let killed = try await client.run("kill -TERM $$", on: host)
        #expect(killed.exitCode == 143)

        await client.disconnect(host.id)
        let again = try await client.run("echo again", on: host)
        #expect(again.stdoutString == "again\n", "a new connection after disconnect")
    }

    private func streams(_ client: EmbeddedSSHClient, host: RemoteHost) async throws {
        var lines: [String] = []
        for try await line in try await client.stream("printf 'a\\nb\\r\\nc'", on: host) { lines.append(line) }
        #expect(lines == ["a", "b", "c"])

        var seen: [String] = []
        do {
            for try await line in try await client.stream("echo x; echo bad >&2; exit 4", on: host) { seen.append(line) }
            Issue.record("a failing stream should throw")
        } catch let error as SSHError {
            #expect(error == .remoteCommandFailed(exitCode: 4, stderr: "bad"))
        }
        #expect(seen == ["x"])

        for try await line in try await client.stream("while :; do echo y; sleep 1; done", on: host) {
            #expect(line == "y")
            break
        }

        await #expect(throws: SSHError.timeout) {
            for try await _ in try await client.stream("sleep 5", on: host, timeout: .seconds(1)) {}
        }
    }

    /// More commands at once than sshd's `MaxSessions` allows on one connection.
    private func concurrency(_ client: EmbeddedSSHClient, host: RemoteHost) async throws {
        let count = SSHConnection.maxSessions + 4
        let results = try await withThrowingTaskGroup(of: (Int, SSHResult).self) { group in
            for index in 0..<count {
                group.addTask { (index, try await client.run("sleep 1; echo \(index)", on: host)) }
            }
            return try await group.reduce(into: [Int: SSHResult]()) { $0[$1.0] = $1.1 }
        }
        #expect(results.count == count)
        for (index, result) in results {
            #expect(result.exitCode == 0, "command \(index): \(String(decoding: result.stderr, as: UTF8.self))")
            #expect(result.stdoutString == "\(index)\n")
        }
    }

    /// Terminals and SFTP on the connection the commands use.
    private func sessions(_ client: EmbeddedSSHClient, env: TestEnvironment, host: RemoteHost) async throws {
        let size = try await client.openTerminal(
            on: host, term: "xterm-256color", size: PseudoTerminalSize(columns: 100, rows: 30), command: "stty size; echo $TERM"
        )
        #expect(try await output(of: size) == "30 100\r\nxterm-256color\r\n")
        #expect(size.exitStatus == 0)

        let shell = try await client.openTerminal(on: host, term: "xterm-256color", size: PseudoTerminalSize(columns: 80, rows: 24))
        shell.resize(PseudoTerminalSize(columns: 120, rows: 40))
        shell.send(Data("stty size; exit 5\r".utf8))
        #expect(try await output(of: shell).contains("40 120\r\n"))
        #expect(shell.exitStatus == 5)
        #expect(await shell.waitForEnd() == nil)

        let sftp = try await SFTPClient.connect(using: client, to: host)
        let folder = try await sftp.homeDirectory().appending(component: "aero-e-it-\(UUID().uuidString.prefix(8))")
        try await sftp.createDirectory(folder)
        let local = env.scratch.file("payload-\(host.port)").filePath
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<(3 << 20)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: URL(filePath: local))
        try await sftp.upload(local, to: folder.appending(component: "payload.bin"))
        let entries = try await sftp.list(folder)
        #expect(entries.map(\.displayName) == ["payload.bin"])
        #expect(entries.first?.attributes.size == UInt64(payload.count))
        try await sftp.download(folder.appending(component: "payload.bin"), to: local + ".back")
        #expect(try Data(contentsOf: URL(filePath: local + ".back")) == payload)
        try await sftp.removeRecursively(folder)
        sftp.disconnect()
    }

    /// Everything a terminal printed until it ended, or a failure after 15 seconds.
    private func output(of channel: EmbeddedSSHChannel) async throws -> String {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(15))
            channel.close()
            Issue.record("the terminal did not end")
        }
        defer { watchdog.cancel() }
        var output = Data()
        for await chunk in channel.incoming { output += chunk }
        return String(decoding: output, as: UTF8.self)
    }

    /// The collectors' metrics through the in-process client, as the iOS dashboard runs them.
    @MainActor
    private func monitor(_ client: EmbeddedSSHClient, hostKeys: HostKeyStore) async throws {
        let coordinator = MonitorCoordinator(runner: client, hostKeys: hostKeys)
        let updates = coordinator.updates
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            await coordinator.shutdown()
        }
        defer { watchdog.cancel() }
        coordinator.setHosts(servers)

        var snapshots: [RemoteHost.ID: MetricsSnapshot] = [:]
        for await update in updates {
            if update.lastError == .authFailed || update.hostKeyIssue != nil {
                Issue.record("Aborting on \(update.hostID): \(update.message ?? "-")")
                break
            }
            if update.status == .online, let snapshot = update.snapshot { snapshots[update.hostID] = snapshot }
            if snapshots.count == servers.count { break }
        }
        await coordinator.shutdown()

        for host in servers {
            let snapshot = try #require(snapshots[host.id], "no snapshot from dev@localhost:\(host.port)")
            #expect(snapshot.memTotalBytes > 0)
            #expect(snapshot.memUsedBytes > 0)
            #expect(!snapshot.hostname.isEmpty)
            #expect(snapshot.uptimeSeconds > 0)
            #expect(!snapshot.disks.isEmpty)
        }
    }

    private func revoke(_ publicKey: URL, repo: URL) async {
        let removed = try? await runTool("/bin/sh", [repo.appending(path: "dev/remove-key.sh").filePath, publicKey.filePath])
        #expect(removed?.status == 0, "could not revoke the test key: \(removed?.stderr ?? "-")")
    }
}
