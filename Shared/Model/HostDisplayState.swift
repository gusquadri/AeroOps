import AeroCore
import Collectors
import Foundation
import Observation

/// Live, in-memory state of one host as shown by its sidebar orb, dashboard card and detail
/// panel. Never persisted.
///
/// ``AppModel`` keeps one instance per host, keyed by host id, so a view that reads one host's
/// state re-renders only when that host changes (20 hosts polling every 5 s must not redraw the
/// whole window). ``MonitorService`` copies each `HostMonitorUpdate` in with ``apply(_:)``,
/// assigning only the properties that changed; previews and demo launches use
/// ``AppModel/updateState(of:status:metrics:message:)``. Views never poll.
@MainActor
@Observable
final class HostDisplayState {
    /// The host this state belongs to.
    let hostID: RemoteHost.ID
    /// Connection state behind the status orb. Starts as ``HostStatus/loading``.
    var status: HostStatus = .loading
    /// Latest metrics, or `nil` until the first successful poll. Kept while the host is stale
    /// or offline, so the card can show the last numbers dimmed.
    var metrics: MetricsSnapshot?
    /// When ``status`` or ``metrics`` last changed.
    var lastUpdated: Date?
    /// Short explanation for the current status, e.g. the last poll error. `nil` when there is nothing to say.
    var message: String?
    /// When the host last answered a poll (successful or unsupported OS).
    var lastSuccessAt: Date?
    /// Set while polling is held because of the host key: the card offers the trust sheet
    /// (``HostKeyIssue/unknown``) or shows the red banner (``HostKeyIssue/changed(_:)``).
    var hostKeyIssue: HostKeyIssue?
    /// Why the last poll failed, in full; `nil` after a success.
    var lastError: String?
    /// Polls in a row that failed.
    var consecutiveFailures = 0
    /// `uname -srm` of a host whose OS is unsupported.
    var unsupportedSystem: String?

    init(hostID: RemoteHost.ID) {
        self.hostID = hostID
    }

    /// Copies a monitor update in. Only changed properties are assigned, so views observing an
    /// unchanged property (e.g. the sidebar orb while the numbers move) are not invalidated.
    func apply(_ update: HostMonitorUpdate) {
        var changed = false
        func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<HostDisplayState, Value>, _ value: Value) {
            guard self[keyPath: keyPath] != value else { return }
            self[keyPath: keyPath] = value
            changed = true
        }
        set(\.status, update.status)
        set(\.metrics, update.snapshot)
        set(\.message, update.message)
        set(\.lastSuccessAt, update.lastSuccessAt)
        set(\.hostKeyIssue, update.hostKeyIssue)
        set(\.lastError, update.lastError.map { $0.errorDescription ?? String(describing: $0) })
        set(\.consecutiveFailures, update.consecutiveFailures)
        set(\.unsupportedSystem, update.unsupportedSystem)
        if changed { lastUpdated = .now }
    }

    /// Clears everything back to "waiting for data" (e.g. the host left monitoring).
    func reset(status: HostStatus = .loading, message: String? = nil) {
        if self.status != status { self.status = status }
        if metrics != nil { metrics = nil }
        if self.message != message { self.message = message }
        if lastSuccessAt != nil { lastSuccessAt = nil }
        if hostKeyIssue != nil { hostKeyIssue = nil }
        if lastError != nil { lastError = nil }
        if consecutiveFailures != 0 { consecutiveFailures = 0 }
        if unsupportedSystem != nil { unsupportedSystem = nil }
    }

    /// The numbers on screen are old: the host is stale or offline but an earlier sample is kept.
    var showsOldNumbers: Bool {
        metrics != nil && (status == .stale || status == .offline)
    }

    /// Polling waits for the user to trust the host's first key.
    var needsHostKeyTrust: Bool {
        hostKeyIssue == .unknown
    }
}
