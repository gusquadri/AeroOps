import Foundation

/// One Docker container, merged from `docker ps` and `docker stats`.
///
/// Data shape only; the parser lives in Collectors. Also the row type of the MCP
/// `list_containers` tool. Names and images are untrusted remote text.
public struct ContainerInfo: Identifiable, Codable, Sendable, Hashable {
    /// Full container ID (`docker ps --no-trunc`).
    public var id: String
    /// Container name without the leading slash.
    public var name: String
    /// Image reference, e.g. `nginx:1.27`.
    public var image: String
    /// Machine-readable state (`State` in `docker ps`).
    public var state: ContainerState
    /// Human-readable status, e.g. `Up 2 hours (healthy)` (`Status` in `docker ps`).
    public var status: String
    /// CPU % from `docker stats` (may exceed 100 on multi-core hosts). `nil` when not running or unknown.
    public var cpuPercent: Double?
    /// Memory in use, in bytes, from `docker stats`. `nil` when unknown.
    public var memUsedBytes: Int64?
    /// Memory limit, in bytes, from `docker stats`. `nil` when unknown.
    public var memLimitBytes: Int64?
    /// Creation time (`CreatedAt`), used for the age column. `nil` when unparsable.
    public var createdAt: Date?

    /// Creates a container row.
    public init(
        id: String,
        name: String,
        image: String,
        state: ContainerState,
        status: String,
        cpuPercent: Double? = nil,
        memUsedBytes: Int64? = nil,
        memLimitBytes: Int64? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.cpuPercent = cpuPercent
        self.memUsedBytes = memUsedBytes
        self.memLimitBytes = memLimitBytes
        self.createdAt = createdAt
    }
}

/// Docker container state. Raw values match Docker's `State` strings.
public enum ContainerState: String, Codable, Sendable, Hashable, CaseIterable {
    case created, running, paused, restarting, removing, exited, dead
    /// Any state string this app does not know.
    case unknown

    /// Maps a Docker state string (case-insensitive); unknown strings become ``unknown``.
    public init(dockerState: String) {
        self = ContainerState(rawValue: dockerState.lowercased()) ?? .unknown
    }

    /// Tolerant decoding: unknown strings become ``unknown``.
    public init(from decoder: any Decoder) throws {
        self.init(dockerState: try decoder.singleValueContainer().decode(String.self))
    }
}
