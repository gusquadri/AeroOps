import AeroCore
import Foundation

extension ContainerInfo {
    /// `true` when `docker stats` reported this container.
    var hasUsage: Bool { cpuPercent != nil || memUsedBytes != nil }

    /// `12.3 MB` (and the limit in the tooltip), or an em dash.
    var memoryText: String {
        guard let used = memUsedBytes else { return MetricText.missing }
        return used.formatted(.byteCount(style: .memory))
    }

    var memoryHelp: String? {
        guard let used = memUsedBytes, let limit = memLimitBytes, limit > 0 else { return nil }
        let percent = (Double(used) / Double(limit)).formatted(.percent.precision(.fractionLength(1)))
        return "\(used.formatted(.byteCount(style: .memory))) of \(limit.formatted(.byteCount(style: .memory))) (\(percent))"
    }

    var cpuText: String {
        guard let cpuPercent else { return MetricText.missing }
        return (cpuPercent / 100).formatted(.percent.precision(.fractionLength(1)))
    }

    /// `docker ps` ports without the IPv6 duplicates: `0.0.0.0:8080->80/tcp`.
    var portsText: String {
        guard let ports, !ports.isEmpty else { return "" }
        let parts = ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let ipv4 = parts.filter { !$0.hasPrefix("[::]") && !$0.hasPrefix(":::") }
        return (ipv4.isEmpty ? parts : ipv4).joined(separator: ", ")
    }
}

extension PodInfo {
    /// `true` when the metrics API reported this pod.
    var hasUsage: Bool { cpuMillicores != nil || memUsedBytes != nil }

    /// The Ready column's sort key: the share of containers ready, so `1/3` sorts before `1/1`.
    var readyFraction: Double {
        containerCount == 0 ? 0 : Double(readyCount) / Double(containerCount)
    }

    /// The Age column's sort key: larger for older pods; `nil` when the creation time is unknown.
    var ageSortKey: TimeInterval? {
        createdAt.map { -$0.timeIntervalSinceReferenceDate }
    }

    /// CPU as `docker stats` shows it, where 100% is one core (`250m` is `25.0%`), or an em dash.
    var cpuText: String {
        guard let cpuMillicores else { return MetricText.missing }
        return Self.corePercent(cpuMillicores)
    }

    /// `25.0% of one core, 50.0% of its 0.5-core limit`, or that there is no limit.
    var cpuHelp: String? {
        guard let cpuMillicores else { return nil }
        let used = "\(Self.corePercent(cpuMillicores)) of one core"
        guard let limit = cpuLimitMillicores, limit > 0 else { return "\(used), no CPU limit" }
        let share = (Double(cpuMillicores) / Double(limit)).formatted(.percent.precision(.fractionLength(1)))
        let cores = (Double(limit) / 1000).formatted(.number.precision(.fractionLength(0...3)))
        return "\(used), \(share) of its \(cores)-core limit"
    }

    /// Millicores as a share of one core: `250` is `25.0%`.
    private static func corePercent(_ millicores: Int) -> String {
        (Double(millicores) / 1000).formatted(.percent.precision(.fractionLength(1)))
    }

    /// `12.3 MB` (working set), or an em dash.
    var memoryText: String {
        MetricText.bytes(memUsedBytes)
    }

    /// `12.3 MB of 64 MB limit (19.2%)`, or that there is no limit.
    var memoryHelp: String? {
        guard let used = memUsedBytes else { return nil }
        let usedText = used.formatted(.byteCount(style: .memory))
        guard let limit = memLimitBytes, limit > 0 else { return "\(usedText), no memory limit" }
        let percent = (Double(used) / Double(limit)).formatted(.percent.precision(.fractionLength(1)))
        return "\(usedText) of \(limit.formatted(.byteCount(style: .memory))) limit (\(percent))"
    }
}
