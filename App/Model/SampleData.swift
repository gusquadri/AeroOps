import AeroCore
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
