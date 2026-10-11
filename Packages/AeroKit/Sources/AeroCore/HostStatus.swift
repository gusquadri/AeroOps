/// Connection state of a host as shown by its card and sidebar orb.
///
/// Polling rules: an 8 s timeout marks a host ``stale``; three
/// failures in a row mark it ``offline``; no `/proc/stat` marks it ``unsupported``.
public enum HostStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// No result yet since launch or since the host was added.
    case loading
    /// The last poll succeeded.
    case online
    /// The last poll timed out or failed; older numbers are still shown.
    case stale
    /// Three or more polls in a row failed.
    case offline
    /// Reachable, but not a Linux host the metrics script understands.
    case unsupported
}
