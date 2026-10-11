import AeroCore
import AeroTestSupport
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Collectors
@testable import SSHKit

/// End to end against the OrbStack VM (`dev/vm/setup.sh`, `aeroops-vm.orb.local`: Docker, k3s
/// and the demo workloads). Run with
/// `AEROOPS_INTEGRATION=1 swift test --package-path Packages/AeroKit --filter DockerKubernetesIntegrationTests`.
///
/// Test-only setup, as in SSHKit's integration test: a throwaway Ed25519 key in a private temp
/// dir, authorized with `dev/add-key.sh` and used through `IdentityFile` (the app uses the
/// in-app agent). The VM's host key is pinned from the VM itself (`orb`, not ssh-keyscan), so
/// no unauthenticated connection is made. Every ssh login uses the authorized key: a failed
/// login trips sshd's PerSourcePenalties for every agent on this Mac, so the test stops at the
/// first auth failure instead of retrying. Afterwards the key is de-authorized everywhere
/// `add-key.sh` put it and the ControlMaster sockets are closed. VM workloads are only read.
@Suite(
    "Docker and Kubernetes integration (VM)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AEROOPS_INTEGRATION"] == "1")
)
struct DockerKubernetesIntegrationTests {
    private static let address = "aeroops-vm.orb.local"

    @Test("Probe, containers, logs, follow, inspect, pods, previous logs, events, describe and errors")
    func endToEnd() async throws {
        let vmList = try await VMIntegration.local("/bin/sh", ["-c", "orb list -r -q"])
        try #require(vmList.stdout.split(separator: "\n").contains("aeroops-vm"), "aeroops-vm is not running (dev/vm/setup.sh)")

        let scratch = try VMIntegration.Scratch()
        let repo = try Fixtures.repoRoot()
        let marker = "aero-dk-" + UUID().uuidString.prefix(8).lowercased()
        let keyFile = scratch.file("id")
        let keygen = try await VMIntegration.local(
            "/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", marker, "-f", keyFile.path(percentEncoded: false)]
        )
        try #require(keygen.status == 0, "\(keygen.stderr)")
        let publicKey = try String(contentsOf: scratch.file("id.pub"), encoding: .utf8)
        let added = try await VMIntegration.local(
            "/bin/sh", [repo.appending(path: "dev/add-key.sh").path(percentEncoded: false), scratch.file("id.pub").path(percentEncoded: false)]
        )
        try #require(added.status == 0, "\(added.stderr)")

        let context = SSHContext(paths: AeroPaths(
            dotDirectory: scratch.url.appending(path: "d", directoryHint: .isDirectory),
            applicationSupport: scratch.url.appending(path: "s", directoryHint: .isDirectory)
        ))
        do {
            try await scenario(context: context, keyFile: keyFile)
        } catch {
            await cleanUp(context: context, publicKey: publicKey)
            throw error
        }
        await cleanUp(context: context, publicKey: publicKey)
    }

    // MARK: - Scenario

    private func scenario(context: SSHContext, keyFile: URL) async throws {
        let dev = RemoteHost(name: "vm-dev", address: Self.address, user: "dev", kubectlPrefix: "sudo -n k3s kubectl")
        let devPlain = RemoteHost(name: "vm-dev-plain", address: Self.address, user: "dev", dockerSudo: true)
        let nodocker = RemoteHost(name: "vm-nodocker", address: Self.address, user: "nodocker", kubectlPrefix: "sudo -n k3s kubectl")
        let nodockerSudo = RemoteHost(name: "vm-nodocker-sudo", address: Self.address, user: "nodocker", dockerSudo: true)
        let hosts = [dev, devPlain, nodocker, nodockerSudo]

        var writer = SSHConfigWriter(context: context)
        writer.identity = .privateKeyFileForTesting(keyFile)
        let rendering = try writer.write(hosts)
        try #require(rendering.rejected.isEmpty)

        // Pin the VM's real host key, read through OrbStack rather than over the network.
        let hostKeyLine = try await VMIntegration.local(
            "/bin/sh", ["-c", "orb -m aeroops-vm -u root cat /etc/ssh/ssh_host_ed25519_key.pub"]
        )
        let parts = hostKeyLine.stdout.split(separator: " ")
        try #require(parts.count >= 2, "\(hostKeyLine.stderr)")
        let hostKey = try HostKey(type: String(parts[0]), base64: String(parts[1]))
        let store = HostKeyStore(context: context)
        for host in hosts { try await store.trust(hostKey, for: host) }
        let runner = SSHRunner(context: context, hostKeys: store)

        // One login first; stop here on an auth failure rather than hammering sshd.
        let hello = try await runner.run("echo ok", on: dev)
        try #require(hello.succeeded, "first login failed: \(hello.stderrString)")

        try await probe(runner: runner, dev: dev, nodocker: nodocker)
        try await docker(runner: runner, dev: dev, devPlain: devPlain, nodocker: nodocker, nodockerSudo: nodockerSudo)
        try await dockerFollow(runner: runner, dev: dev)
        try await kubernetes(runner: runner, dev: dev, devPlain: devPlain, nodocker: nodocker)
        try await kubernetesFollow(runner: runner, dev: dev)
    }

    private func probe(runner: SSHRunner, dev: RemoteHost, nodocker: RemoteHost) async throws {
        let cache = CapabilityCache(runner: runner)
        let devCaps = try await cache.capabilities(for: dev)
        #expect(devCaps.contains([.docker, .k3s, .dockerOK]), "\(devCaps)")
        #expect(devCaps.suggestedKubectlPrefix == "sudo -n k3s kubectl")
        let nodockerCaps = try await cache.capabilities(for: nodocker)
        #expect(nodockerCaps.dockerNeedsSetup, "\(nodockerCaps)")
        #expect(try await cache.capabilities(for: dev) == devCaps)
        print("Collectors integration: dev \(devCaps.rawValue), nodocker \(nodockerCaps.rawValue)")
    }

    private func docker(
        runner: SSHRunner, dev: RemoteHost, devPlain: RemoteHost, nodocker: RemoteHost, nodockerSudo: RemoteHost
    ) async throws {
        let collector = DockerCollector(runner: runner)

        let started = ContinuousClock.now
        let rows = try await collector.containers(on: dev)
        let listDuration = ContinuousClock.now - started
        let byName = Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for name in ["demo-web", "demo-logger"] {
            let row = try #require(byName[name], "\(name) missing from \(rows.map(\.name))")
            #expect(row.state == .running)
            #expect(row.cpuPercent != nil, "\(name) has no CPU")
            #expect((row.memUsedBytes ?? 0) > 0, "\(name) has no memory")
            #expect((row.memLimitBytes ?? 0) > 0)
        }
        let exited = try #require(byName["demo-exited"])
        #expect(exited.state == .exited)
        #expect(exited.exitCode == 3)
        #expect(exited.cpuPercent == nil)
        print("Collectors integration: docker ps + stats in \(listDuration): "
              + rows.map { "\($0.name) cpu=\($0.cpuPercent.map { String($0) } ?? "-")" }.joined(separator: ", "))

        // Permission paths.
        let denied = await #expect(throws: DockerError.self) { try await collector.containers(on: nodocker) }
        if case .permissionDenied = denied {} else { Issue.record("nodocker: expected permissionDenied, got \(String(describing: denied))") }
        #expect(denied?.hint?.contains("docker group") == true)
        let viaSudo = try await collector.containers(on: nodockerSudo)
        #expect(Set(viaSudo.map(\.name)).isSuperset(of: ["demo-web", "demo-logger", "demo-exited"]))
        await #expect(throws: DockerError.sudoRefused) { try await collector.containers(on: devPlain) }

        // Logs: ANSI stripped; stderr merged (demo-exited printed one of its 3 lines on stderr).
        let logger = try await collector.logs(of: "demo-logger", on: dev, tail: 20)
        let loggerLines = logger.text.split(separator: "\n")
        #expect(!loggerLines.isEmpty && loggerLines.count <= 20)
        #expect(!logger.text.contains("\u{1B}"))
        let exitedLogs = try await collector.logs(of: "demo-exited", on: dev)
        #expect(exitedLogs.text.split(separator: "\n").count == 3, "\(exitedLogs.text)")

        let logs = LogCollector(runner: runner)
        let viaRequest = try await logs.fetch(LogRequest(hostId: dev.id, kind: .container, name: "demo-logger", tail: 5), on: dev)
        #expect(viaRequest.text.split(separator: "\n").count == 5)
        await #expect(throws: CollectorInputError.self) {
            try await logs.fetch(LogRequest(hostId: dev.id, kind: .container, name: "demo-web;id"), on: dev)
        }
        await #expect(throws: DockerError.self) { try await collector.logs(of: "no-such-container", on: dev) }

        // Inspect.
        let inspection = try await collector.inspect("demo-web", on: dev)
        #expect(inspection.summary.name == "demo-web")
        #expect(inspection.summary.healthCheck == .healthy)
    }

    private func dockerFollow(runner: SSHRunner, dev: RemoteHost) async throws {
        let collector = DockerCollector(runner: runner)

        // Busy container: read a few lines, cancel, the remote `docker logs -f` goes away.
        let received = try await VMIntegration.followThenCancel(count: 40, within: .seconds(15)) {
            try await collector.followLogs(of: "demo-logger", on: dev, tail: 37)
        }
        #expect(received.count == 40, "only \(received.count) lines")
        #expect(!received.contains { $0.contains("\u{1B}") })
        #expect(received.contains { $0.contains("ERROR") }, "stderr lines missing from the follow")
        let busyGone = await VMIntegration.remoteGone(runner: runner, host: dev, pattern: "[d]ocker logs -f --tail 37 ")
        #expect(busyGone, "docker logs -f for demo-logger still running")

        // Quiet container (nginx logs a health check every 10 s): cancel right after a line, so
        // only the watchdog's heartbeat, not the next log write, can stop the remote process in
        // time. (Under the ControlMaster, sshd closes the command's stdout but not its stderr.)
        let healthLine = try await VMIntegration.followThenCancel(count: 1, within: .seconds(15)) {
            try await collector.followLogs(of: "demo-web", on: dev, tail: 0)
        }
        #expect(healthLine.count == 1)
        let cancelled = ContinuousClock.now
        let quietGone = await VMIntegration.remoteGone(
            runner: runner, host: dev, pattern: "[d]ocker logs -f --tail 0 --timestamps .?demo-web", timeout: .seconds(7)
        )
        #expect(quietGone, "docker logs -f for quiet demo-web outlived the cancel by 7 s")
        print("Collectors integration: quiet follow gone \(ContinuousClock.now - cancelled) after cancel")
    }

    private func kubernetes(runner: SSHRunner, dev: RemoteHost, devPlain: RemoteHost, nodocker: RemoteHost) async throws {
        let collector = KubernetesCollector(runner: runner)
        let pods = try await collector.pods(on: dev)
        let crasher = try #require(pods.first { $0.namespace == "demo" && $0.name.hasPrefix("crasher-") })
        #expect(crasher.restarts > 0)
        let pending = try #require(pods.first { $0.namespace == "demo" && $0.name.hasPrefix("pending-") })
        #expect(pending.phase == .pending)
        let web = try #require(pods.first { $0.namespace == "demo" && $0.name.hasPrefix("web-") })
        #expect(Set(web.containers.map(\.name)) == ["nginx", "log-sidecar"])
        #expect(pods.contains { $0.namespace == "kube-system" })
        let demoOnly = try await collector.pods(on: dev, namespace: "demo")
        #expect(!demoOnly.isEmpty && demoOnly.allSatisfy { $0.namespace == "demo" })
        print("Collectors integration: \(pods.count) pods; crasher restarts \(crasher.restarts)")

        let logs = LogCollector(runner: runner)
        var previous = try await logs.fetch(
            LogRequest(hostId: dev.id, kind: .pod, name: crasher.name, namespace: "demo", previous: true), on: dev
        ).text
        if previous.hasPrefix("unable to retrieve container logs") {
            // The pod is between restarts (status Error): kubelet already removed the container
            // before the last one, and the last run's logs are the current ones.
            print("Collectors integration: crasher between restarts; reading its current logs")
            previous = try await logs.fetch(
                LogRequest(hostId: dev.id, kind: .pod, name: crasher.name, namespace: "demo"), on: dev
            ).text
        }
        #expect(previous.contains("FATAL"), "\(previous)")
        let sidecar = try await logs.fetch(
            LogRequest(hostId: dev.id, kind: .pod, name: web.name, namespace: "demo", container: "log-sidecar", tail: 3), on: dev
        )
        #expect(!sidecar.text.isEmpty)
        await #expect(throws: KubectlError.noPreviousContainer(container: "nginx", pod: web.name)) {
            try await collector.logs(pod: web.name, namespace: "demo", container: "nginx", previous: true, on: dev)
        }

        let events = try await collector.events(pod: pending.name, namespace: "demo", on: dev)
        #expect(events.contains { $0.reason == "FailedScheduling" }, "\(events.map(\.reason))")
        let describe = try await collector.describe(pod: crasher.name, namespace: "demo", on: dev)
        #expect(describe.text.contains(crasher.name))

        // Error paths with hints.
        let unreadable = await #expect(throws: KubectlError.self) { try await collector.pods(on: devPlain) }
        if case .kubeconfigUnreadable = unreadable {} else {
            Issue.record("plain kubectl: expected kubeconfigUnreadable, got \(String(describing: unreadable))")
        }
        await #expect(throws: KubectlError.sudoRefused) { try await collector.pods(on: nodocker) }
    }

    private func kubernetesFollow(runner: SSHRunner, dev: RemoteHost) async throws {
        let collector = KubernetesCollector(runner: runner)
        let web = try #require(try await collector.pods(on: dev, namespace: "demo").first { $0.name.hasPrefix("web-") })
        let lines = try await VMIntegration.followThenCancel(count: 3, within: .seconds(15)) {
            try await collector.followLogs(pod: web.name, namespace: "demo", container: "log-sidecar", tail: 3, on: dev)
        }
        #expect(lines.count == 3)
        let gone = await VMIntegration.remoteGone(
            runner: runner, host: dev, pattern: "[k]ubectl logs -f -n .?demo.? .?\(web.name)", timeout: .seconds(8)
        )
        #expect(gone, "sudo -n k3s kubectl logs -f still running after cancel")
    }

    // MARK: - Cleanup

    private func cleanUp(context: SSHContext, publicKey: String) async {
        await ControlMaster(context: context).closeAll()
        let key = Data(publicKey.utf8)
        let strip = #"read -r k; for f in "$@"; do [ -f "$f" ] || continue; grep -vxF "$k" "$f" > "$f.tmp" || true; cat "$f.tmp" > "$f"; rm -f "$f.tmp"; done"#
        let targets: [(String, String)] = [
            ("aeroops-ssh", "docker exec -i aeroops-ssh sh -c \(ShellQuote.quote(strip)) sh /config/.ssh/authorized_keys"),
            ("aeroops-alpine", "docker exec -i aeroops-alpine sh -c \(ShellQuote.quote(strip)) sh /home/dev/.ssh/authorized_keys"),
            ("aeroops-vm", "orb -m aeroops-vm -u root sh -c \(ShellQuote.quote(strip)) sh /home/dev/.ssh/authorized_keys /home/nodocker/.ssh/authorized_keys"),
        ]
        for (name, command) in targets {
            if name != "aeroops-vm" {
                let running = try? await VMIntegration.local("/bin/sh", ["-c", "docker inspect -f '{{.State.Running}}' \(name) 2>/dev/null"])
                guard running?.stdout.hasPrefix("true") == true else { continue }
            }
            let removed = try? await VMIntegration.local("/bin/sh", ["-c", command], stdin: key)
            #expect(removed?.status == 0, "could not de-authorize the test key on \(name): \(removed?.stderr ?? "-")")
        }
        let leftover = try? await VMIntegration.local(
            "/bin/sh", ["-c", "orb -m aeroops-vm -u root sh -c 'cat /home/dev/.ssh/authorized_keys /home/nodocker/.ssh/authorized_keys'"]
        )
        #expect(leftover?.stdout.contains(publicKey.trimmingCharacters(in: .whitespacesAndNewlines)) == false)
    }
}

/// Helpers private to this integration test (named to avoid clashing with other test files).
private enum VMIntegration {
    struct LocalResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// A private directory under `/tmp` (short, so ControlMaster socket paths stay < 104 bytes).
    final class Scratch {
        let url: URL

        init() throws {
            var template = Array("/tmp/aero-dk-XXXXXX".utf8CString)
            guard let created = mkdtemp(&template) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            url = URL(filePath: String(cString: created), directoryHint: .isDirectory)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func file(_ name: String) -> URL { url.appending(path: name) }
    }

    /// Runs a local tool through SSHKit's process layer.
    static func local(_ executable: String, _ arguments: [String], stdin: Data? = nil) async throws -> LocalResult {
        let spec = ChildSpec(
            executable: executable,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            stdin: stdin,
            timeout: .seconds(60),
            outputLimit: 1 << 20
        )
        let outcome = try await ChildProcess.run(spec)
        let status: Int32 = switch outcome.termination {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
        return LocalResult(
            status: status,
            stdout: String(decoding: outcome.stdout.data, as: UTF8.self),
            stderr: String(decoding: outcome.stderr.data, as: UTF8.self)
        )
    }

    final class Lines: Sendable {
        let lines = Mutex<[String]>([])
        let ended = Mutex(false)
        var count: Int { lines.withLock { $0.count } }
        var hasEnded: Bool { ended.withLock { $0 } }
    }

    /// Follows in a consumer task the way the Logs sheet does, then cancels that task once
    /// `count` lines arrived (or after `timeout`). Returns the first `count` lines.
    static func followThenCancel(
        count: Int,
        within timeout: Duration,
        _ start: @escaping @Sendable () async throws -> AsyncThrowingStream<String, any Error>
    ) async throws -> [String] {
        let received = Lines()
        let consumer = Task {
            defer { received.ended.withLock { $0 = true } }
            for try await line in try await start() {
                received.lines.withLock { $0.append(line) }
            }
        }
        let deadline = ContinuousClock.now + timeout
        while received.count < count, !received.hasEnded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        consumer.cancel()
        try await consumer.value
        return received.lines.withLock { Array($0.prefix(count)) }
    }

    /// Polls `pgrep -f <pattern>` on the host until nothing matches. Use a `[x]yz` pattern so the
    /// pgrep's own shell does not match.
    static func remoteGone(runner: SSHRunner, host: RemoteHost, pattern: String, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let result = try? await runner.run("pgrep -f \(ShellQuote.quote(pattern)) || true", on: host),
               result.succeeded, result.stdoutString.isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let left = try? await runner.run("pgrep -af \(ShellQuote.quote(pattern)) || true", on: host)
        print("Collectors integration: still running after \(timeout):\n\(left?.stdoutString ?? "-")")
        return false
    }
}
