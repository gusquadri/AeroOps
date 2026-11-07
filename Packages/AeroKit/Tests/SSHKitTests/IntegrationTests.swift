import AeroCore
import AeroTestSupport
import Darwin
import Foundation
import Testing
@testable import SSHKit

/// End to end against the dev server (`docker compose -f dev/compose.yml up -d`, dev@localhost:2222).
/// Run with `AEROOPS_INTEGRATION=1 swift test --package-path Packages/AeroKit --filter SSHKitTests`.
///
/// Test-only setup: a throwaway Ed25519 key in a private temp dir, authorized with
/// `dev/add-key.sh` and used through `IdentityAgent none` + `IdentityFile <key>` (the app always
/// uses the in-app agent instead). The key is de-authorized and deleted afterwards.
@Suite(
    "Integration (dev server)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AEROOPS_INTEGRATION"] == "1")
)
struct IntegrationTests {
    @Test("TOFU, commands, ControlMaster reuse, streaming, errors and a changed host key")
    func endToEnd() async throws {
        let scratch = try ScratchDirectory()
        let repo = try Fixtures.repoRoot()
        let marker = "aero-it-" + UUID().uuidString.prefix(8).lowercased()

        let keyFile = scratch.file("id")
        let keygen = try await runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", marker, "-f", keyFile.filePath])
        try #require(keygen.status == 0, "\(keygen.stderr)")
        let publicKey = try #require(scratch.read("id.pub"))
        let added = try await runTool("/bin/sh", [repo.appending(path: "dev/add-key.sh").filePath, scratch.file("id.pub").filePath])
        try #require(added.status == 0, "\(added.stderr)")

        let main = SSHContext(paths: scratch.paths("d"))
        let changed = SSHContext(paths: scratch.paths("x"))
        let keyless = SSHContext(paths: scratch.paths("y"))
        let contexts = [main, changed, keyless]
        do {
            try await scenario(context: main, keyFile: keyFile, marker: marker)
            try await changedKeyScenario(context: changed, keyFile: keyFile)
            try await keylessScenario(context: keyless)
        } catch {
            await cleanUp(contexts: contexts, publicKey: publicKey)
            throw error
        }
        await cleanUp(contexts: contexts, publicKey: publicKey)
    }

    private func scenario(context: SSHContext, keyFile: URL, marker: String) async throws {
        var writer = SSHConfigWriter(context: context)
        writer.identity = .privateKeyFileForTesting(keyFile)
        let dev = RemoteHost.test()
        let refused = RemoteHost.test(port: 1)
        let unresolvable = RemoteHost.test(address: "nonexistent-host.invalid", port: 22)
        let rendering = try writer.write([dev, refused, unresolvable])
        #expect(rendering.rejected.isEmpty)

        let store = HostKeyStore(context: context, keychain: InMemoryKeychain())
        let runner = SSHRunner(context: context, hostKeys: store)
        let control = ControlMaster(context: context)

        guard try await checkFirstContact(dev, store: store, runner: runner),
              try await checkMultiplexing(dev, runner: runner, control: control)
        else { return }
        try await checkCommands(dev, runner: runner)
        try await checkStreaming(dev, runner: runner, marker: marker)
        try await checkTransportFailures(refused: refused, unresolvable: unresolvable, store: store, runner: runner)
        try await checkClosingMasters(dev, runner: runner, control: control, context: context)
    }

    private func checkFirstContact(_ dev: RemoteHost, store: HostKeyStore, runner: SSHRunner) async throws -> Bool {
        let untrusted = try await runner.run("true", on: dev)
        #expect(untrusted.transportError == .hostKeyUnknown, "\(untrusted.stderrString)")

        guard case .unknown(let offered) = try await store.verify(dev) else {
            Issue.record("expected an unknown host key")
            return false
        }
        #expect(Set(offered.map(\.displayType)) == ["RSA", "ECDSA", "ED25519"])
        let ed = try #require(offered.first { $0.type == "ssh-ed25519" })
        let serverKey = try await runTool(
            "/bin/sh", ["-c", "docker exec aeroops-ssh ssh-keygen -lf /config/ssh_host_keys/ssh_host_ed25519_key.pub"]
        )
        #expect(serverKey.stdout.hasPrefix("256 \(ed.fingerprint) "), "\(serverKey.stdout)")
        try await store.trust(ed, for: dev)
        #expect(try await store.verify(dev) == .trusted(ed))
        return true
    }

    private func checkMultiplexing(_ dev: RemoteHost, runner: SSHRunner, control: ControlMaster) async throws -> Bool {
        let first = try await runner.run("uname -a", on: dev)
        #expect(first.succeeded, "\(first.stderrString)")
        #expect(first.stdoutString.hasPrefix("Linux "))
        guard case .running(let pid) = try await control.check(dev) else {
            Issue.record("expected a running master")
            return false
        }
        #expect(pid != nil)
        let second = try await runner.run("echo $((6 * 7))", on: dev)
        #expect(second.stdoutString == "42\n")
        #expect(second.duration < .milliseconds(500), "mux command took \(second.duration)")
        print("SSHKit integration: first \(first.duration), multiplexed \(second.duration)")
        return true
    }

    private func checkCommands(_ dev: RemoteHost, runner: SSHRunner) async throws {
        let echoed = try await runner.run("cat", on: dev, stdin: Data("hello from stdin\n".utf8))
        #expect(echoed.stdoutString == "hello from stdin\n")
        let failed = try await runner.run("echo nope >&2; exit 3", on: dev)
        #expect(failed.exitCode == 3 && failed.transportError == nil)
        #expect(throws: SSHError.remoteCommandFailed(exitCode: 3, stderr: "nope")) { try failed.checked() }
        let capped = try await runner.run("head -c 100000 /dev/zero", on: dev, outputLimit: 4096)
        #expect(capped.stdout.count == 4096 && capped.stdoutTruncated)

        let slow = try await runner.run("sleep 20", on: dev, timeout: .milliseconds(500))
        #expect(slow.timedOut && slow.transportError == .timeout)
    }

    private func checkStreaming(_ dev: RemoteHost, runner: SSHRunner, marker: String) async throws {
        let tick = "tick-\(marker)"
        do {
            let stream = try await runner.stream(
                "i=0; while [ $i -lt 600 ]; do echo \(ShellQuote.quote(tick))-$i; i=$((i+1)); sleep 0.1; done", on: dev
            )
            var lines: [String] = []
            for try await line in stream {
                lines.append(line)
                if lines.count == 3 { break }
            }
            #expect(lines == ["\(tick)-0", "\(tick)-1", "\(tick)-2"])
        }
        let localGone = await eventually(timeout: .seconds(5)) {
            let result = try? await runTool("/usr/bin/pgrep", ["-f", tick])
            return result?.status == 1
        }
        #expect(localGone, "local ssh still running")
        let pattern = ShellQuote.quote("[t]" + tick.dropFirst())
        let remoteGone = await eventually(timeout: .seconds(5)) {
            let result = try? await runner.run("pgrep -f \(pattern) || true", on: dev)
            return result?.succeeded == true && result?.stdoutString.isEmpty == true
        }
        #expect(remoteGone, "remote loop still running")
    }

    private func checkTransportFailures(refused: RemoteHost, unresolvable: RemoteHost, store: HostKeyStore, runner: SSHRunner) async throws {
        let refusedResult = try await runner.run("true", on: refused)
        #expect(refusedResult.transportError == .connectionRefused, "\(refusedResult.stderrString)")
        let dns = try await runner.run("true", on: unresolvable)
        #expect(dns.transportError == .nameResolutionFailed, "\(dns.stderrString)")
        await #expect(throws: SSHError.connectionRefused) { try await store.verify(refused) }
        await #expect(throws: SSHError.nameResolutionFailed) { try await store.verify(unresolvable) }
    }

    private func checkClosingMasters(_ dev: RemoteHost, runner: SSHRunner, control: ControlMaster, context: SSHContext) async throws {
        let exited = try await control.exit(dev)
        #expect(exited)
        #expect(await eventually { (try? await control.check(dev)) == .notRunning })
        let exitedAgain = try await control.exit(dev)
        #expect(!exitedAgain)

        let reopened = try await runner.run("true", on: dev)
        #expect(reopened.succeeded, "\(reopened.stderrString)")
        let closed = await control.closeAll()
        #expect(closed == 1)
        #expect(await eventually { ControlMaster.sockets(in: context.controlMasterDirectory).isEmpty })
    }

    /// known_hosts pins a different Ed25519 key for the dev server.
    private func changedKeyScenario(context: SSHContext, keyFile: URL) async throws {
        var writer = SSHConfigWriter(context: context)
        writer.identity = .privateKeyFileForTesting(keyFile)
        let dev = RemoteHost.test()
        try writer.write([dev])
        let impostor = TestKeys.ed25519()

        let pins = InMemoryKeychain()
        let store = HostKeyStore(context: context, keychain: pins)
        try await store.trust(impostor, for: dev)
        guard case .changed(let pinned, let offered) = try await store.verify(dev) else {
            Issue.record("expected a changed host key")
            return
        }
        #expect(pinned == [impostor])
        let real = try #require(offered.first { $0.type == "ssh-ed25519" })
        #expect(await store.isBlocked(dev))

        let freshStore = HostKeyStore(context: context, keychain: pins)
        let runner = SSHRunner(context: context, hostKeys: freshStore)
        let result = try await runner.run("true", on: dev)
        #expect(result.transportError == .hostKeyChanged, "\(result.stderrString)")
        #expect(result.stderrString.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
        #expect(await freshStore.isBlocked(dev))
        await #expect(throws: SSHError.hostKeyChanged) { try await runner.run("true", on: dev) }

        await #expect(throws: HostKeyError.self) { try await freshStore.trust(real, for: dev) }
        try await freshStore.trust(real, for: dev, replacingPinned: true)
        let accepted = try await runner.run("echo ok", on: dev)
        #expect(accepted.stdoutString == "ok\n", "\(accepted.stderrString)")
        await ControlMaster(context: context).closeAll()
    }

    /// The app's path for a host without a key: `IdentityFile none` and an agent socket that is
    /// not running here, so ssh has nothing to offer and BatchMode forbids prompting.
    /// (A key-less attempt only costs a 1 s `noauth` penalty; an invalid user name would cost
    /// 5 s+ and, with the scans, trip sshd's PerSourcePenalties for the whole Docker host.)
    private func keylessScenario(context: SSHContext) async throws {
        let dev = RemoteHost.test()
        try SSHConfigWriter(context: context).write([dev])
        let store = HostKeyStore(context: context, keychain: InMemoryKeychain())
        try await store.trust(DevServerKeys.ed25519Key, for: dev)
        let runner = SSHRunner(context: context, hostKeys: store)
        let result = try await runner.run("true", on: dev)
        #expect(result.transportError == .authFailed, "\(result.stderrString)")
        print("SSHKit integration: key-less stderr: \(result.stderrString.debugDescription)")
    }

    private func cleanUp(contexts: [SSHContext], publicKey: String) async {
        for context in contexts {
            await ControlMaster(context: context).closeAll()
        }
        let script = #"f=/config/.ssh/authorized_keys; read -r k; grep -vxF "$k" "$f" > "$f.tmp" || true; cat "$f.tmp" > "$f"; rm -f "$f.tmp""#
        let removed = try? await runTool(
            "/bin/sh", ["-c", "docker exec -i aeroops-ssh sh -c \(ShellQuote.quote(script))"],
            stdin: Data(publicKey.utf8)
        )
        #expect(removed?.status == 0, "could not de-authorize the test key: \(removed?.stderr ?? "-")")
    }
}
