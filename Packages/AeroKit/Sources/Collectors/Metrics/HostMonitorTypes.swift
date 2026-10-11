import AeroCore
import Foundation
import SSHKit

/// How often a ``HostMonitor`` polls, set by the app.
public enum MonitorActivity: String, Sendable, Hashable, CaseIterable {
    /// A window showing the host is visible: poll every 5 s.
    case visible
    /// No window shows it: poll every 30 s.
    case background
    /// No polls at all (the Mac is asleep, or the app asked). ``HostMonitor/refresh()`` still polls once.
    case paused
}

/// Timing and limits for a ``HostMonitor``.
public struct HostMonitorConfiguration: Sendable, Hashable {
    /// Poll interval while ``MonitorActivity/visible``.
    public var visibleInterval: Duration
    /// Poll interval while ``MonitorActivity/background``, and for hosts with an unsupported OS.
    public var backgroundInterval: Duration
    /// Deadline for one poll; a poll that takes longer is killed and the host turns stale.
    public var timeout: Duration
    /// Failures in a row that turn a host offline.
    public var offlineThreshold: Int
    /// Upper bound of the exponential backoff between polls of an offline host.
    public var maxBackoff: Duration
    /// Least time between the end of one poll and the start of the next, so a host whose polls
    /// run longer than the interval is not polled back to back.
    public var minimumGap: Duration
    /// A previous sample older than this is not used for CPU %, so the first poll after a long
    /// pause or outage shows a dash instead of an average over the whole gap.
    public var maxCPUSampleAge: Duration
    /// Bytes of stdout kept per poll; more means the output was cut off and the poll failed.
    public var outputLimit: Int

    public init(
        visibleInterval: Duration = .seconds(5),
        backgroundInterval: Duration = .seconds(30),
        timeout: Duration = .seconds(8),
        offlineThreshold: Int = 3,
        maxBackoff: Duration = .seconds(60),
        minimumGap: Duration = .seconds(1),
        maxCPUSampleAge: Duration = .seconds(120),
        outputLimit: Int = 256 * 1024
    ) {
        self.visibleInterval = visibleInterval
        self.backgroundInterval = backgroundInterval
        self.timeout = timeout
        self.offlineThreshold = max(1, offlineThreshold)
        self.maxBackoff = maxBackoff
        self.minimumGap = minimumGap
        self.maxCPUSampleAge = maxCPUSampleAge
        self.outputLimit = outputLimit
    }

    /// 5 s visible, 30 s background, 8 s timeout, offline after 3 failures, backoff up to 60 s.
    public static let standard = HostMonitorConfiguration()

    /// The poll interval for `activity`; `nil` while paused.
    public func interval(for activity: MonitorActivity) -> Duration? {
        switch activity {
        case .visible: visibleInterval
        case .background: backgroundInterval
        case .paused: nil
        }
    }
}

/// Why a monitor stopped polling until the user acts. While set, ``HostMonitorUpdate/status``
/// is ``HostStatus/offline``; after the user trusts or replaces the key, call
/// ``HostMonitor/refresh()`` (or ``MonitorCoordinator/refresh(_:)``) to resume.
public enum HostKeyIssue: Sendable, Hashable {
    /// No key is pinned for the host: show the fingerprint sheet (`HostKeyStore.verify`, then `trust`).
    case unknown
    /// The server's key differs from the pinned one and `HostKeyStore` blocks the host: show the
    /// red banner. Carries the store's block (pinned and offered keys) when it has one.
    case changed(HostKeyBlock?)

    /// A one-line explanation for the card.
    public var message: String {
        switch self {
        case .unknown: "The host key is not trusted yet. Confirm its fingerprint to start monitoring."
        case .changed: "The host key has changed. Monitoring is blocked until you review it."
        }
    }
}

/// Everything a host card needs, published by ``HostMonitor`` after every change.
public struct HostMonitorUpdate: Sendable, Hashable {
    /// The host this update is about.
    public var hostID: RemoteHost.ID
    /// Card and orb state. ``HostStatus/offline`` while ``hostKeyIssue`` is set.
    public var status: HostStatus
    /// Set when polling stopped because of the host key; the app shows the sheet or banner.
    public var hostKeyIssue: HostKeyIssue?
    /// The latest successful poll, kept (and shown as stale) while later polls fail; `nil` before
    /// the first success and for unsupported hosts. Its `cpuPercent` is `nil` (a dash) on the
    /// first poll and whenever the previous sample is missing or too old.
    public var snapshot: MetricsSnapshot?
    /// Why the last poll failed; `nil` once a poll succeeds.
    public var lastError: SSHError?
    /// When the host last answered (a successful or unsupported-OS poll).
    public var lastSuccessAt: Date?
    /// Polls in a row that failed.
    public var consecutiveFailures: Int
    /// The monitor's polling mode when this update was published.
    public var activity: MonitorActivity
    /// `uname -srm` of a host whose OS is unsupported, e.g. `Darwin 25.0.0 arm64`.
    public var unsupportedSystem: String?

    public init(
        hostID: RemoteHost.ID,
        status: HostStatus = .loading,
        hostKeyIssue: HostKeyIssue? = nil,
        snapshot: MetricsSnapshot? = nil,
        lastError: SSHError? = nil,
        lastSuccessAt: Date? = nil,
        consecutiveFailures: Int = 0,
        activity: MonitorActivity = .visible,
        unsupportedSystem: String? = nil
    ) {
        self.hostID = hostID
        self.status = status
        self.hostKeyIssue = hostKeyIssue
        self.snapshot = snapshot
        self.lastError = lastError
        self.lastSuccessAt = lastSuccessAt
        self.consecutiveFailures = consecutiveFailures
        self.activity = activity
        self.unsupportedSystem = unsupportedSystem
    }

    /// A short explanation for the card (`AppModel.updateState(message:)`), or `nil` when
    /// there is nothing to say.
    public var message: String? {
        if let hostKeyIssue { return hostKeyIssue.message }
        switch status {
        case .unsupported:
            if let unsupportedSystem, !unsupportedSystem.isEmpty { return "Unsupported OS: \(unsupportedSystem)" }
            return "Unsupported OS: the host has no /proc/stat."
        case .stale, .offline:
            return lastError.map { $0.errorDescription ?? String(describing: $0) }
        case .loading, .online:
            return nil
        }
    }
}
