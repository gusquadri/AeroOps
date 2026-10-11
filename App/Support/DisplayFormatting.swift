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
        case .readExec: "Agents can also run commands, each one shown to you for approval first."
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

    /// Load averages "1m 5m 15m", e.g. "0.42 0.38 0.30".
    static func load(_ metrics: MetricsSnapshot?) -> String {
        guard let metrics else { return missing }
        return [metrics.load1, metrics.load5, metrics.load15]
            .map { $0.formatted(.number.precision(.fractionLength(2))) }
            .joined(separator: " ")
    }
}
