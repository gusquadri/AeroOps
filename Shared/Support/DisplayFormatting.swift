import AeroCore
import Foundation

extension MCPTier {
    /// Picker label.
    var title: String {
        switch self {
        case .off: "Off"
        case .read: "Read"
        case .readExec: "Read + Exec"
        }
    }

    /// One-line explanation under the picker.
    var explanation: String {
        switch self {
        case .off: "AI agents can't see this host."
        case .read: "Agents can read metrics, containers, pods and logs. Every call is logged."
        case .readExec: "Agents can also run commands. They are told to ask you in the conversation first; AeroOps itself does not ask."
        }
    }
}

extension RemoteHost {
    /// `user@address`, plus `:port` when it is not 22.
    var connectionSummary: String {
        port == RemoteHost.defaultPort ? "\(user)@\(address)" : "\(user)@\(address):\(port)"
    }
}

/// Text for metric values on cards. A missing value is an em dash, matching `GlossyGauge`.
enum MetricText {
    static let missing = "—"

    /// Uptime as its two largest units, e.g. "12d 4h", "3h 12m", "45m".
    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return missing }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// How long ago `date` was, for "updated 12s ago": "12s", "4m", "2h", "3d".
    static func age(of date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    /// A byte count, e.g. "3.1 GB".
    static func bytes(_ count: Int64?) -> String {
        guard let count, count >= 0 else { return missing }
        return count.formatted(.byteCount(style: .memory))
    }

    /// "1.5 GB of 3.1 GB".
    static func usage(_ used: Int64?, of total: Int64?) -> String {
        guard let used, let total, total > 0 else { return missing }
        return "\(bytes(used)) of \(bytes(total))"
    }

    /// A fraction as a whole percentage, e.g. "42%".
    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return missing }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
    /// Load averages "1m · 5m · 15m", e.g. "0.42 · 0.38 · 0.30" (dots, not spaces, so decimal commas read clearly).
    /// Load averages "1m 5m 15m", e.g. "0.42 0.38 0.30".
    static func load(_ metrics: MetricsSnapshot?) -> String {
        guard let metrics else { return missing }
        return load(averages: [metrics.load1, metrics.load5, metrics.load15])
    }

    /// Load averages with two decimals, e.g. "1.42 · 0.98 · 0.71".
    static func load(averages: [Double]) -> String {
        averages
            .map { $0.formatted(.number.precision(.fractionLength(2))) }
            .joined(separator: " · ")
    }
}
