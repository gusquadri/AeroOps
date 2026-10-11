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
}
