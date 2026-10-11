import AeroCore
import Foundation
import Observation

/// Live, in-memory state of one host as shown by its sidebar orb and dashboard card. Never persisted.
///
/// ``AppModel`` keeps one instance per host, keyed by host id, so a view that reads one host's
/// state re-renders only when that host changes (20 hosts polling every 5 s must not redraw the
/// whole window). Phase 3's per-host `HostMonitor` actors push results through
/// ``AppModel/updateState(of:status:metrics:message:)``; views never poll.
@MainActor
@Observable
final class HostDisplayState {
    /// The host this state belongs to.
    let hostID: RemoteHost.ID
    /// Connection state behind the status orb. Starts as ``HostStatus/loading``.
    var status: HostStatus = .loading
    /// Latest metrics, or `nil` until the first successful poll (Phase 3). Gauges show a dash.
    var metrics: MetricsSnapshot?
    /// When ``status`` or ``metrics`` last changed.
    var lastUpdated: Date?
    /// Short explanation for the current status, e.g. the last poll error. `nil` when there is nothing to say.
    var message: String?

    init(hostID: RemoteHost.ID) {
        self.hostID = hostID
    }
}
