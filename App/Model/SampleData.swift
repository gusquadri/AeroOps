import AeroCore
import Collectors
import Foundation

/// Sample hosts and states for SwiftUI previews and the DEBUG demo launch options.
/// Never written to the user's real inventory.
enum SampleData {
    /// Six hosts covering every ``HostStatus`` (see ``statuses``), with and without tags.
    static let hosts: [RemoteHost] = [
        RemoteHost(
            id: uuid(1), name: "web-01", address: "10.0.0.12", user: "deploy",
            tags: ["prod", "web", "eu-west"], mcpTier: .read),
        RemoteHost(
            id: uuid(2), name: "db-primary", address: "db1.internal.example.com", port: 2222, user: "postgres",
            tags: ["prod", "db"], mcpTier: .off),
        RemoteHost(
            id: uuid(3), name: "k3s-node", address: "192.168.64.5", user: "ubuntu",
            tags: ["staging", "k8s"], kubectlPrefix: "sudo -n k3s kubectl", dockerSudo: true, mcpTier: .readExec),
        RemoteHost(
            id: uuid(4), name: "dev-container", address: "localhost", port: 2222, user: "dev",
            tags: ["dev"]),
        RemoteHost(
            id: uuid(5), name: "edge-alpine", address: "edge.example.net", user: "root"),
        RemoteHost(
            id: uuid(6), name: "nas", address: "nas.local", user: "admin",
            tags: ["home"]),
    ]

    /// One status per sample host, in order, covering every case.
    static let statuses: [HostStatus] = [.online, .stale, .offline, .loading, .online, .unsupported]

    /// A plausible snapshot for an online host, for previews of filled gauges.
    static func metrics(cpu: Double = 37, memory: Double = 0.62, disk: Double = 0.48) -> MetricsSnapshot {
        let gib: Int64 = 1 << 30
        return MetricsSnapshot(
            cpuPercent: cpu, cpuCount: 4,
            memUsedBytes: Int64(Double(8 * gib) * memory), memTotalBytes: 8 * gib,
            disks: [DiskUsage(mount: "/", device: "/dev/sda1", usedBytes: Int64(Double(80 * gib) * disk), totalBytes: 80 * gib)],
            uptimeSeconds: 1_036_800 + 14_400, load1: 0.42, load5: 0.38, load15: 0.30,
            hostname: "web-01", kernel: "Linux 6.8.0-45-generic x86_64", sampledAt: .now
        )
    }

    /// A snapshot with swap and several mounts, as the detail panel shows them.
    static func detailedMetrics(
        cpu: Double? = 23, memory: Double = 0.41, disk: Double = 0.52, sampledAt: Date = .now, hostname: String = "web-01"
    ) -> MetricsSnapshot {
        let gib: Int64 = 1 << 30
        return MetricsSnapshot(
            cpuPercent: cpu, cpuCount: 8,
            memUsedBytes: Int64(Double(16 * gib) * memory), memTotalBytes: 16 * gib,
            disks: [
                DiskUsage(mount: "/", device: "/dev/nvme0n1p2", usedBytes: Int64(Double(120 * gib) * disk), totalBytes: 120 * gib),
                DiskUsage(mount: "/boot/efi", device: "/dev/nvme0n1p1", usedBytes: 6 << 20, totalBytes: 512 << 20),
                DiskUsage(mount: "/var/lib/docker", device: "/dev/mapper/vg0-docker", usedBytes: 412 * gib, totalBytes: 480 * gib),
                DiskUsage(mount: "/srv/backups/nightly-snapshots", device: "nas.local:/volume1/backups", usedBytes: 3_900 * gib, totalBytes: 4_000 * gib),
            ],
            uptimeSeconds: 1_036_800 + 14_400, load1: 1.42, load5: 0.98, load15: 0.71,
            hostname: hostname, kernel: "Linux 6.8.0-45-generic x86_64", sampledAt: sampledAt,
            swapTotalBytes: 4 * gib, swapUsedBytes: 310 << 20
        )
    }

    /// Monitor updates for the six sample hosts, one per card state the dashboard draws:
    /// online, stale (numbers dimmed), changed host key (blocked), first-contact key not trusted,
    /// offline with old numbers, and unsupported OS.
    static func liveUpdates(for hosts: [RemoteHost], now: Date = .now) -> [HostMonitorUpdate] {
        hosts.enumerated().map { index, host in
            let id = host.id
            switch index % 6 {
            case 0:
                return HostMonitorUpdate(hostID: id, status: .online, snapshot: detailedMetrics(hostname: host.name), lastSuccessAt: now)
            case 1:
                let sampled = now.addingTimeInterval(-47)
                return HostMonitorUpdate(
                    hostID: id, status: .stale,
                    snapshot: detailedMetrics(cpu: 64, memory: 0.83, disk: 0.71, sampledAt: sampled, hostname: host.name),
                    lastError: .timeout, lastSuccessAt: sampled, consecutiveFailures: 1)
            case 2:
                return HostMonitorUpdate(hostID: id, status: .offline, hostKeyIssue: .changed(nil))
            case 3:
                return HostMonitorUpdate(hostID: id, status: .offline, hostKeyIssue: .unknown)
            case 4:
                let sampled = now.addingTimeInterval(-260)
                return HostMonitorUpdate(
                    hostID: id, status: .offline,
                    snapshot: detailedMetrics(cpu: 8, memory: 0.22, disk: 0.97, sampledAt: sampled, hostname: host.name),
                    lastError: .connectionRefused, lastSuccessAt: sampled, consecutiveFailures: 6)
            default:
                return HostMonitorUpdate(hostID: id, status: .unsupported, lastSuccessAt: now, unsupportedSystem: "FreeBSD 14.1-RELEASE amd64")
            }
        }
    }

    private static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }
}

extension AppModel {
    /// A model over a throwaway store in the temporary directory, filled with `hosts`.
    /// With `statuses`, host *i* gets `statuses[i % count]`; with `withMetrics`, online hosts get
    /// a sample snapshot. For previews only.
    static func preview(
        hosts: [RemoteHost] = SampleData.hosts,
        statuses: [HostStatus] = SampleData.statuses,
        withMetrics: Bool = false
    ) -> AppModel {
        let directory = URL.temporaryDirectory.appending(path: "AeroOpsPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = AppModel(hostStore: HostStore(directory: directory), connectionTester: SimulatedConnectionTester(delay: .seconds(1)))
        for host in hosts {
            try? model.addHost(host)
        }
        model.selection = nil
        model.applySampleStatuses(statuses, withMetrics: withMetrics)
        return model
    }

    /// Gives the hosts ``SampleData/liveUpdates(for:now:)``, as if their monitors had reported:
    /// every card state with numbers. Used by previews and the DEBUG demo option.
    func applySampleLiveStates() {
        for update in SampleData.liveUpdates(for: hosts) {
            displayStates[update.hostID]?.apply(update)
        }
    }

    /// Gives host *i* status `statuses[i % count]`. Used by previews and the DEBUG demo option.
    func applySampleStatuses(_ statuses: [HostStatus] = SampleData.statuses, withMetrics: Bool = false) {
        guard !statuses.isEmpty else { return }
        for (index, host) in hosts.enumerated() {
            let status = statuses[index % statuses.count]
            let metrics = withMetrics && status == .online
                ? SampleData.metrics(cpu: Double(15 + index * 17), memory: 0.35 + Double(index) * 0.1, disk: 0.3 + Double(index) * 0.12)
                : nil
            updateState(of: host.id, status: status, metrics: metrics, message: nil)
        }
    }
}
