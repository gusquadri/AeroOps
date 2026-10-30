import AeroCore
import AeroTestSupport
import Darwin
import Foundation
import Testing
@testable import Collectors
@testable import SSHKit

/// MonitorCoordinator end to end against the dev servers:
/// dev@localhost:2222 (Debian), dev@localhost:2223 (BusyBox Alpine) and dev@aeroops-vm.orb.local:22.
/// Run with `AEROOPS_INTEGRATION=1 swift test --package-path Packages/AeroKit --filter HostMonitorIntegration`.
///
/// Test-only setup, as in SSHKit's integration test: a throwaway Ed25519 key in a private temp
/// dir, authorized with `dev/add-key.sh` and used through `IdentityFile` (the app uses the in-app
/// agent), plus host keys pinned from one `ssh-keyscan -t ed25519` per server. Any
/// authentication failure or host-key problem aborts at once: sshd's `PerSourcePenalties`
/// would otherwise ban this Mac's address for every client. Afterwards the key is
/// de-authorized and deleted and the ControlMasters are closed; servers are left running.
@Suite(
    "HostMonitor integration (dev servers)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AEROOPS_INTEGRATION"] == "1")
)
struct HostMonitorIntegrationTests {
    private struct Server {
        var label: String
        var container: String?
        var host: RemoteHost
    }

    private struct Observations {
        var firstSnapshot: [RemoteHost.ID: Duration] = [:]
        var firstCPU: [RemoteHost.ID: (Duration, MetricsSnapshot)] = [:]
        var offlineAfter: Duration?
        var closedStatuses: [HostStatus] = []

        /// Whether the first phase is over: every server has a CPU %, or 12 s have passed.
        mutating func recordOnline(_ update: HostMonitorUpdate, elapsed: Duration, serverCount: Int) -> Bool {
            guard let snapshot = update.snapshot, update.status == .online else { return false }
            if firstSnapshot[update.hostID] == nil { firstSnapshot[update.hostID] = elapsed }
            if snapshot.cpuPercent != nil, firstCPU[update.hostID] == nil { firstCPU[update.hostID] = (elapsed, snapshot) }
            return firstCPU.count == serverCount || elapsed > .seconds(12)
        }

        /// Whether the wait is over: the closed port went offline, or 35 s have passed.
        mutating func recordClosed(_ update: HostMonitorUpdate, elapsed: Duration) -> Bool {
            closedStatuses.append(update.status)
            guard update.status == .offline else { return elapsed > .seconds(35) }
            #expect(update.lastError == .connectionRefused, "\(update.message ?? "-")")
            offlineAfter = elapsed
            return true
        }
    }

    private let servers = [
        Server(label: "dev@localhost:2222", container: "aeroops-ssh",
               host: RemoteHost(name: "dev", address: "localhost", port: 2222, user: "dev")),
        Server(label: "dev@localhost:2223 (BusyBox)", container: "aeroops-alpine",
               host: RemoteHost(name: "alpine", address: "localhost", port: 2223, user: "dev")),
        Server(label: "dev@aeroops-vm.orb.local:22", container: nil,
               host: RemoteHost(name: "vm", address: "aeroops-vm.orb.local", port: 22, user: "dev")),
    ]

    @MainActor
    @Test("Every dev server reports plausible metrics with CPU % by the second poll; a closed port goes offline")
    func monitorsDevServers() async throws {
        let scratch = try MonitorScratchDirectory()
        let repo = try Fixtures.repoRoot()
        let keyFile = scratch.file("id")
        let keygen = try await monitorRunTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "aero-hm-it", "-f", keyFile.filePath])
        try #require(keygen.status == 0, "\(keygen.stderr)")
        let publicKey = try String(contentsOf: scratch.file("id.pub"), encoding: .utf8)
        let context = SSHContext(paths: AeroPaths(
            dotDirectory: scratch.url.appending(path: "d", directoryHint: .isDirectory),
            applicationSupport: scratch.url.appending(path: "s", directoryHint: .isDirectory)
        ))

        let added = try await monitorRunTool("/bin/sh", [repo.appending(path: "dev/add-key.sh").filePath, scratch.file("id.pub").filePath])
        do {
            try #require(added.status == 0, "\(added.stdout)\(added.stderr)")
            let authorized = added.stdout.split(separator: "\n").filter { $0.contains("authorized:") }
            try #require(authorized.count == 3, "Not every dev server is running:\n\(added.stdout)")
            try await scenario(context: context, keyFile: keyFile)
        } catch {
            await cleanUp(context: context, publicKey: publicKey)
            throw error
        }
        await cleanUp(context: context, publicKey: publicKey)
    }

    @MainActor
    private func scenario(context: SSHContext, keyFile: URL) async throws {
        let closed = RemoteHost(name: "closed", address: "127.0.0.1", port: 1, user: "dev")
        var writer = SSHConfigWriter(context: context)
        writer.identity = .privateKeyFileForTesting(keyFile)
        let rendering = try writer.write(servers.map(\.host) + [closed])
        #expect(rendering.rejected.isEmpty)

        // Pin each server's Ed25519 key (one keyscan connection each). Nothing listens on the
        // closed port, so any pin lets it past the monitor's unknown-key check.
        let store = HostKeyStore(context: context, keychain: InMemoryKeychain())
        for server in servers {
            try await store.trust(try await scanEd25519(server.host), for: server.host)
        }
        try await store.trust(try HostKey(type: "ssh-ed25519", base64: "AAAAC3NzaC1lZDI1NTE5AAAAIPfVoGPvXD/pnZyxb+hG6xVPXZ4tyYudnqH3H3ZcLQ1B"), for: closed)

        let coordinator = MonitorCoordinator(runner: SSHRunner(context: context, hostKeys: store), hostKeys: store)
        let seen = await watch(coordinator, closed: closed)

        for server in servers {
            try expectPlausibleMetrics(server, seen)
        }
        let offline = try #require(seen.offlineAfter, "closed port never went offline: \(seen.closedStatuses)")
        #expect(offline <= .seconds(30))
        #expect(seen.closedStatuses.prefix(3) == [.loading, .stale, .stale])
        print(String(format: "HostMonitor integration: 127.0.0.1:1 offline after %.2f s (%@)", Self.seconds(offline), seen.closedStatuses.map(\.rawValue).joined(separator: " → ")))
    }

    @MainActor
    private func watch(_ coordinator: MonitorCoordinator, closed: RemoteHost) async -> Observations {
        let updates = coordinator.updates
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(50))
            await coordinator.shutdown()
        }
        defer { watchdog.cancel() }

        // Phase 1: the three servers, visible (5 s cadence).
        var started = ContinuousClock.now
        var seen = Observations()
        var phase = 1
        coordinator.setHosts(servers.map(\.host))

        for await update in updates {
            let elapsed = started.duration(to: .now)
            if abortsRun(update) { break }
            if phase == 1 {
                if seen.recordOnline(update, elapsed: elapsed, serverCount: servers.count) {
                    // Phase 2: a host on a closed port must go offline within 30 s.
                    phase = 2
                    started = ContinuousClock.now
                    coordinator.setHosts(servers.map(\.host) + [closed])
                }
            } else if update.hostID == closed.id, seen.recordClosed(update, elapsed: elapsed) {
                break
            }
        }
        await coordinator.shutdown()
        watchdog.cancel()
        return seen
    }

    private func abortsRun(_ update: HostMonitorUpdate) -> Bool {
        guard update.lastError == .authFailed || update.hostKeyIssue != nil else { return false }
        Issue.record("Aborting on \(update.hostID): \(update.message ?? "-")")
        return true
    }

    private func expectPlausibleMetrics(_ server: Server, _ seen: Observations) throws {
        let id = server.host.id
        let snapshotAt = try #require(seen.firstSnapshot[id], "\(server.label): no snapshot")
        let (cpuAt, snapshot) = try #require(seen.firstCPU[id], "\(server.label): no CPU % by the second poll")
        #expect(cpuAt <= .seconds(10), "\(server.label): CPU % after \(cpuAt)")
        let cpu = try #require(snapshot.cpuPercent)
        #expect((0...100).contains(cpu), "\(server.label): cpu \(cpu)")
        #expect((snapshot.cpuCount ?? 0) >= 1, "\(server.label)")
        #expect(snapshot.memTotalBytes > 64 << 20, "\(server.label): mem total \(snapshot.memTotalBytes)")
        #expect(snapshot.memUsedBytes > 0 && snapshot.memUsedBytes <= snapshot.memTotalBytes, "\(server.label)")
        #expect(snapshot.uptimeSeconds > 0, "\(server.label)")
        #expect(snapshot.load1 >= 0 && snapshot.load15 >= 0, "\(server.label)")
        #expect(!snapshot.hostname.isEmpty, "\(server.label)")
        #expect(snapshot.kernel.hasPrefix("Linux "), "\(server.label): \(snapshot.kernel)")
        let root = snapshot.disk(mountedAt: "/") ?? snapshot.disks.first
        let disk = try #require(root, "\(server.label): no disks")
        #expect(disk.totalBytes > 0 && disk.usedBytes >= 0 && disk.usedBytes <= disk.totalBytes, "\(server.label)")
        print(String(
            format: "HostMonitor integration: %@: first snapshot %.2f s, CPU %% at %.2f s: cpu %.1f%% of %d, mem %.2f/%.2f GiB, load %.2f, %@ %.0f%% of %.1f GiB, %@",
            server.label, Self.seconds(snapshotAt), Self.seconds(cpuAt), cpu, snapshot.cpuCount ?? 0,
            Double(snapshot.memUsedBytes) / 1_073_741_824, Double(snapshot.memTotalBytes) / 1_073_741_824,
            snapshot.load1, disk.mount, (disk.usedFraction ?? 0) * 100, Double(disk.totalBytes) / 1_073_741_824,
            snapshot.kernel
        ))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// One `ssh-keyscan -t ed25519` connection.
    private func scanEd25519(_ host: RemoteHost) async throws -> HostKey {
        let scan = try await monitorRunTool("/usr/bin/ssh-keyscan", ["-T", "5", "-t", "ed25519", "-p", String(host.port), host.address], timeout: .seconds(15))
        let fields = scan.stdout.split(separator: "\n").first { !$0.hasPrefix("#") }?.split(separator: " ") ?? []
        try #require(fields.count >= 3, "ssh-keyscan \(host.address):\(host.port): \(scan.stderr)")
        return try HostKey(type: String(fields[1]), base64: String(fields[2]))
    }

    private func cleanUp(context: SSHContext, publicKey: String) async {
        await ControlMaster(context: context).closeAll()
        let key = Data(publicKey.utf8)
        let remove = #"read -r k; grep -vxF "$k" "$f" > "$f.tmp" || true; cat "$f.tmp" > "$f"; rm -f "$f.tmp""#
        for (container, file) in [("aeroops-ssh", "/config/.ssh/authorized_keys"), ("aeroops-alpine", "/home/dev/.ssh/authorized_keys")] {
            let script = "f=\(ShellQuote.quote(file)); \(remove)"
            let result = try? await monitorRunTool("/usr/bin/env", ["docker", "exec", "-i", container, "sh", "-c", script], stdin: key)
            #expect(result?.status == 0, "could not de-authorize the test key on \(container): \(result?.stderr ?? "-")")
        }
        let vmScript = #"read -r k; for u in dev nodocker; do f=/home/$u/.ssh/authorized_keys; [ -f "$f" ] || continue; grep -vxF "$k" "$f" > "$f.tmp" || true; cat "$f.tmp" > "$f"; rm -f "$f.tmp"; done"#
        let vm = try? await monitorRunTool("/usr/bin/env", ["orb", "-m", "aeroops-vm", "-u", "root", "sh", "-c", vmScript], stdin: key)
        #expect(vm?.status == 0, "could not de-authorize the test key on aeroops-vm: \(vm?.stderr ?? "-")")
    }
}

// MARK: - Helpers

/// A private `/tmp/aero-m-XXXXXX` directory (short, for ControlMaster socket paths), removed on deinit.
final class MonitorScratchDirectory: Sendable {
    let url: URL

    init() throws {
        var template = Array("/tmp/aero-m-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        url = URL(filePath: String(cString: created), directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

struct MonitorToolResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs a local tool to completion through SSHKit's process layer.
func monitorRunTool(_ executable: String, _ arguments: [String], stdin: Data? = nil, timeout: Duration = .seconds(60)) async throws -> MonitorToolResult {
    let spec = ChildSpec(
        executable: executable,
        arguments: arguments,
        environment: ProcessInfo.processInfo.environment,
        stdin: stdin,
        timeout: timeout,
        outputLimit: 1 << 20
    )
    let outcome = try await ChildProcess.run(spec)
    let status: Int32 = switch outcome.termination {
    case .exited(let code): code
    case .signaled(let signal): 128 + signal
    }
    return MonitorToolResult(
        status: status,
        stdout: String(decoding: outcome.stdout.data, as: UTF8.self),
        stderr: String(decoding: outcome.stderr.data, as: UTF8.self)
    )
}
