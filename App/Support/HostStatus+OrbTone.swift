import AeroCore
import AeroTheme

extension HostStatus {
    /// The status orb tone for this host state. AeroTheme does not depend on AeroCore,
    /// so the app owns this mapping.
    var orbTone: OrbTone {
        switch self {
        case .online: .healthy
        case .stale: .warning
        case .offline: .error
        case .loading, .unsupported: .neutral
        }
    }

    /// Short label shown next to the orb.
    var title: String {
        switch self {
        case .loading: "Waiting for data"
        case .online: "Online"
        case .stale: "Stale"
        case .offline: "Offline"
        case .unsupported: "Unsupported OS"
        }
    }

    /// Mid-sentence form for counts such as "2 online · 1 unsupported OS".
    var summaryLabel: String {
        switch self {
        case .loading: "waiting for data"
        case .online: "online"
        case .stale: "stale"
        case .offline: "offline"
        case .unsupported: "unsupported OS"
        }
    }
}
