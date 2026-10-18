import AeroCore
import Collectors
import Foundation
import SSHKit

/// Sample hosts and states for SwiftUI previews and the DEBUG demo launch options.
/// Never written to the user's real inventory.
enum SampleData {
    /// Seven hosts covering every ``HostStatus`` (see ``statuses``), with and without tags. The
    /// last has monitoring off.
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
        RemoteHost(
            id: uuid(7), name: "backup", address: "backup.example.com", user: "backup",
            tags: ["home"], monitored: false),
    ]

    /// One status per sample host, in order, covering every case.
    static let statuses: [HostStatus] = [.online, .stale, .offline, .loading, .online, .unsupported, .unmonitored]

    /// A plausible snapshot for an online host, for previews of filled gauges.
    static func metrics(cpu: Double = 37, memory: Double = 0.62, disk: Double = 0.48) -> MetricsSnapshot {
        let gib: Int64 = 1 << 30
        return MetricsSnapshot(
            cpuPercent: cpu, cpuCount: 4,
            memUsedBytes: Int64(Double(8 * gib) * memory), memTotalBytes: 8 * gib,
            disks: [DiskUsage(mount: "/", device: "/dev/sda1", usedBytes: Int64(Double(80 * gib) * disk), totalBytes: 80 * gib)],
            uptimeSeconds: 1_036_800 + 14_400, load1: 0.42, load5: 0.38, load15: 0.30,
            hostname: "web-01", kernel: "Linux 6.8.0-45-generic x86_64", sampledAt: .now,
            os: ubuntu
        )
    }

    /// os-release of the sample hosts, for the logo in their card's status bubble.
    static let ubuntu = OSRelease(id: "ubuntu", idLike: ["debian"], name: "Ubuntu", prettyName: "Ubuntu 24.04.1 LTS", versionID: "24.04")
    static let debian = OSRelease(id: "debian", name: "Debian GNU/Linux", prettyName: "Debian GNU/Linux 13 (trixie)", versionID: "13")
    static let alpine = OSRelease(id: "alpine", name: "Alpine Linux", prettyName: "Alpine Linux v3.24", versionID: "3.24.2")

    /// A snapshot with swap and several mounts, as the detail panel shows them.
    static func detailedMetrics(
        cpu: Double? = 23, memory: Double = 0.41, disk: Double = 0.52, sampledAt: Date = .now, hostname: String = "web-01",
        os: OSRelease = ubuntu, kernel: String = "Linux 6.8.0-45-generic x86_64"
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
            hostname: hostname, kernel: kernel, sampledAt: sampledAt,
            swapTotalBytes: 4 * gib, swapUsedBytes: 310 << 20, os: os
        )
    }

    /// Monitor updates for the sample hosts, one per card state the dashboard draws:
    /// online, stale (numbers dimmed), changed host key (blocked), first-contact key not trusted,
    /// offline with old numbers, and unsupported OS. Hosts with monitoring off get none.
    static func liveUpdates(for hosts: [RemoteHost], now: Date = .now) -> [HostMonitorUpdate] {
        hosts.enumerated().compactMap { index, host in
            guard host.monitored else { return nil }
            let id = host.id
            switch index % 6 {
            case 0:
                return HostMonitorUpdate(hostID: id, status: .online, snapshot: detailedMetrics(hostname: host.name), lastSuccessAt: now)
            case 1:
                let sampled = now.addingTimeInterval(-47)
                return HostMonitorUpdate(
                    hostID: id, status: .stale,
                    snapshot: detailedMetrics(cpu: 64, memory: 0.83, disk: 0.71, sampledAt: sampled, hostname: host.name, os: debian),
                    lastError: .timeout, lastSuccessAt: sampled, consecutiveFailures: 1)
            case 2:
                return HostMonitorUpdate(hostID: id, status: .offline, hostKeyIssue: .changed(nil))
            case 3:
                return HostMonitorUpdate(hostID: id, status: .offline, hostKeyIssue: .unknown)
            case 4:
                let sampled = now.addingTimeInterval(-260)
                return HostMonitorUpdate(
                    hostID: id, status: .offline,
                    snapshot: detailedMetrics(
                        cpu: 8, memory: 0.22, disk: 0.97, sampledAt: sampled, hostname: host.name,
                        os: alpine, kernel: "Linux 6.12.13-0-lts x86_64"),
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

/// Well-formed but meaningless host keys for previews and demo snapshots.
enum SampleHostKeys {
    static func ed25519(seed: UInt8) -> HostKey {
        make(type: "ssh-ed25519", body: [Data(repeating: seed, count: 32)])
    }

    static func ecdsa(seed: UInt8) -> HostKey {
        make(type: "ecdsa-sha2-nistp256", body: [Data("nistp256".utf8), Data([0x04]) + Data(repeating: seed, count: 64)])
    }

    private static func make(type: String, body: [Data]) -> HostKey {
        var blob = Data()
        for field in [Data(type.utf8)] + body {
            var length = UInt32(field.count).bigEndian
            blob.append(Data(bytes: &length, count: 4))
            blob.append(field)
        }
        // The blob is built above with a valid type prefix, so parsing cannot fail.
        return try! HostKey(type: type, base64: blob.base64EncodedString())
    }
}
