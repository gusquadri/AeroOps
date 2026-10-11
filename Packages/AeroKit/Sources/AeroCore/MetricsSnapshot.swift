import Foundation

/// One poll of a host's metrics, as parsed from `Scripts/remote/metrics.sh` output.
///
/// Built by ``MetricsParser``. Also the payload of the MCP `get_host_metrics` tool.
public struct MetricsSnapshot: Codable, Sendable, Hashable {
    /// Busy CPU percentage (0...100) across all cores since the previous poll.
    /// `nil` on the first poll, because CPU % needs two `/proc/stat` samples.
    public var cpuPercent: Double?
    /// Number of logical CPUs (`@@cpus`), if reported.
    public var cpuCount: Int?
    /// Used memory in bytes: MemTotal − MemAvailable (or − (MemFree + Buffers + Cached)).
    public var memUsedBytes: Int64
    /// Total memory in bytes (MemTotal).
    public var memTotalBytes: Int64
    /// Every mounted filesystem from `df -Pk`, de-duplicated by device.
    public var disks: [DiskUsage]
    /// Seconds since boot (first field of `/proc/uptime`).
    public var uptimeSeconds: Double
    /// 1-minute load average.
    public var load1: Double
    /// 5-minute load average.
    public var load5: Double
    /// 15-minute load average.
    public var load15: Double
    /// Output of `hostname` on the server.
    public var hostname: String
    /// Output of `uname -srm`, e.g. `Linux 6.8.0-45-generic x86_64`.
    public var kernel: String
    /// When the app received this sample (local clock).
    public var sampledAt: Date
    /// Total swap in bytes (SwapTotal), if reported. `0` means the host has no swap.
    public var swapTotalBytes: Int64?
    /// Used swap in bytes (SwapTotal − SwapFree), if both were reported.
    public var swapUsedBytes: Int64?

    /// Creates a snapshot.
    public init(
        cpuPercent: Double?,
        cpuCount: Int? = nil,
        memUsedBytes: Int64,
        memTotalBytes: Int64,
        disks: [DiskUsage],
        uptimeSeconds: Double,
        load1: Double,
        load5: Double,
        load15: Double,
        hostname: String,
        kernel: String,
        sampledAt: Date,
        swapTotalBytes: Int64? = nil,
        swapUsedBytes: Int64? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.cpuCount = cpuCount
        self.memUsedBytes = memUsedBytes
        self.memTotalBytes = memTotalBytes
        self.disks = disks
        self.uptimeSeconds = uptimeSeconds
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.hostname = hostname
        self.kernel = kernel
        self.sampledAt = sampledAt
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
    }

    /// Memory use as a fraction 0...1, or `nil` when the total is unknown (0).
    public var memUsedFraction: Double? {
        memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) : nil
    }

    /// Swap use as a fraction 0...1, or `nil` when swap is unknown or absent.
    public var swapUsedFraction: Double? {
        guard let swapTotalBytes, swapTotalBytes > 0, let swapUsedBytes else { return nil }
        return min(max(Double(swapUsedBytes) / Double(swapTotalBytes), 0), 1)
    }

    /// The disk mounted at `mount` (default `/`), if present.
    public func disk(mountedAt mount: String = "/") -> DiskUsage? {
        disks.first { $0.mount == mount }
    }
}

/// Usage of one mounted filesystem, from a `df -Pk` row.
public struct DiskUsage: Identifiable, Codable, Sendable, Hashable {
    /// Mount point, e.g. `/` or `/var/lib/docker`.
    public var mount: String
    /// Backing device, e.g. `/dev/sda1`; used for de-duplication.
    public var device: String
    /// Used bytes.
    public var usedBytes: Int64
    /// Total size in bytes.
    public var totalBytes: Int64
    /// Bytes available to unprivileged users (df's `Available`), if known. Smaller than
    /// `totalBytes - usedBytes` when the filesystem reserves blocks for root (ext4) or shares a
    /// container with other volumes (APFS).
    public var availableBytes: Int64?

    /// Identity is the mount point.
    public var id: String { mount }

    /// Creates a disk usage row.
    public init(mount: String, device: String, usedBytes: Int64, totalBytes: Int64, availableBytes: Int64? = nil) {
        self.mount = mount
        self.device = device
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// Used space as a fraction 0...1, or `nil` when unknown.
    ///
    /// With ``availableBytes`` this is used ÷ (used + available), the same basis as df's
    /// `Capacity` column; otherwise used ÷ total.
    public var usedFraction: Double? {
        if let availableBytes {
            let usable = Double(usedBytes) + Double(availableBytes)
            if usable > 0 { return min(max(Double(usedBytes) / usable, 0), 1) }
        }
        return totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : nil
    }
}
