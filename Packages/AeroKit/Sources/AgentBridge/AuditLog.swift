import AeroCore
import BridgeProtocol
import Darwin
import Foundation

/// How the policy and the user treated a call.
public enum AuditDecision: String, Codable, Sendable, Hashable, CaseIterable {
    /// A read tool on a Read or Read+Exec host.
    case allowed
    /// The user allowed this one call.
    case approvedOnce
    /// The user allowed the host for 15 minutes from this call.
    case approvedHostWindow
    /// An open allow window covered the call.
    case allowedByWindow
    case denied
    /// Nobody answered the approval in time.
    case approvalTimedOut
    /// The policy refused it without asking (Off host, exec on a Read host, unknown host).
    case rejected
    /// The arguments failed validation, or the tool is unknown.
    case invalid
    /// The agent cancelled while the approval was pending.
    case cancelled
}

/// What happened after the decision.
public enum AuditOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    /// The tool returned a result (for `run_command`, whatever the exit code).
    case succeeded
    case failed
    case cancelledByAgent
    case cancelledByUser
    /// Not executed (rejected, denied, invalid).
    case notRun
}

/// One line of `audit.jsonl`. Never contains command output, log text, keys or socket paths.
public struct AuditEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var time: Date
    /// The MCP client's self-reported name and version.
    public var client: String?
    public var toolUseId: String?
    public var tool: String
    /// The resolved host's name, or the agent's `host` argument when it did not resolve.
    public var host: String?
    public var hostId: UUID?
    /// The validated arguments (or the raw ones for invalid calls); long strings are clipped.
    public var arguments: [String: JSONValue]
    public var decision: AuditDecision
    public var outcome: AuditOutcome
    /// Bridge error code for failed or refused calls.
    public var error: String?
    /// `run_command` exit status.
    public var exitCode: Int32?
    /// From receiving the request to replying, including approval wait.
    public var durationMs: Int
    /// Bytes of content returned to the agent.
    public var outputBytes: Int?

    public init(id: UUID = UUID(), time: Date, client: String?, toolUseId: String?, tool: String, host: String?,
                hostId: UUID?, arguments: [String: JSONValue], decision: AuditDecision, outcome: AuditOutcome,
                error: String? = nil, exitCode: Int32? = nil, durationMs: Int, outputBytes: Int? = nil) {
        self.id = id
        self.time = time
        self.client = client
        self.toolUseId = toolUseId
        self.tool = tool
        self.host = host
        self.hostId = hostId
        self.arguments = arguments
        self.decision = decision
        self.outcome = outcome
        self.error = error
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.outputBytes = outputBytes
    }
}

/// Append-only JSON-lines audit trail of every MCP call (`~/Library/Application Support/AeroOps/audit.jsonl`).
///
/// - The file is created `0600` (and fixed to `0600` if it is not), its directory `0700`;
///   symlinks are refused.
/// - Writes are serialized by the actor; each entry is one `write(2)` of one line.
/// - When the file would exceed ``maxBytes`` it is rotated to `audit.1.jsonl` … `audit.N.jsonl`.
/// - ``recent()`` and ``updates()`` feed the app's Activity tab.
public actor AuditLog {
    public static let defaultMaxBytes = 5 << 20
    public static let defaultGenerations = 3
    /// Longest string argument kept in an entry.
    public static let maxArgumentLength = 16 * 1024

    public nonisolated let fileURL: URL
    public let maxBytes: Int
    public let generations: Int
    private let recentCapacity: Int
    private var recentEntries: [AuditEntry] = []
    /// The last write failure, for a warning in Settings; `nil` after a successful write.
    public private(set) var lastError: String?
    private nonisolated let broadcaster = Broadcaster<AuditEntry>(bufferSize: 256)

    public init(fileURL: URL = AeroPaths.standard.auditLog, maxBytes: Int = AuditLog.defaultMaxBytes,
                generations: Int = AuditLog.defaultGenerations, recentCapacity: Int = 500) {
        self.fileURL = fileURL
        self.maxBytes = max(1024, maxBytes)
        self.generations = max(1, generations)
        self.recentCapacity = max(1, recentCapacity)
    }

    /// Appends `entry` to the file and the recent feed.
    public func record(_ entry: AuditEntry) {
        var entry = entry
        entry.arguments = Self.clipped(entry.arguments)
        recentEntries.append(entry)
        if recentEntries.count > recentCapacity { recentEntries.removeFirst(recentEntries.count - recentCapacity) }
        broadcaster.yield(entry)
        do {
            var line = try BridgeWire.makeEncoder().encode(entry)
            line.append(UInt8(ascii: "\n"))
            try append(line)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// The newest entries, oldest first (this session plus anything ``loadRecent()`` read).
    public func recent() -> [AuditEntry] {
        recentEntries
    }

    /// New entries as they are recorded.
    public nonisolated func updates() -> AsyncStream<AuditEntry> {
        broadcaster.subscribe()
    }

    /// Seeds ``recent()`` from the file (e.g. at launch).
    public func loadRecent() {
        let existing = Self.read(from: fileURL, limit: recentCapacity)
        recentEntries = Array((existing + recentEntries).suffix(recentCapacity))
    }

    /// Reads entries from an audit file, oldest first, skipping malformed lines. `limit` keeps the newest.
    public static func read(from url: URL, limit: Int? = nil) -> [AuditEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = BridgeWire.makeDecoder()
        var entries: [AuditEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(AuditEntry.self, from: Data(line)) { entries.append(entry) }
        }
        if let limit { return Array(entries.suffix(max(0, limit))) }
        return entries
    }

    /// `audit.jsonl` → `audit.<n>.jsonl`.
    public nonisolated func rotatedURL(_ generation: Int) -> URL {
        let ext = fileURL.pathExtension
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem).\(generation)" : "\(stem).\(generation).\(ext)"
        return fileURL.deletingLastPathComponent().appending(path: name)
    }

    // MARK: File I/O

    private struct IOError: Error, CustomStringConvertible {
        var operation: String
        var code: Int32
        var description: String { "\(operation): \(String(cString: strerror(code)))" }
    }

    private func append(_ line: Data) throws {
        let path = fileURL.path(percentEncoded: false)
        try ensureDirectory()
        var info = stat()
        if lstat(path, &info) == 0, info.st_size > 0, Int(info.st_size) + line.count > maxBytes {
            rotate()
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IOError(operation: "open audit log", code: errno) }
        defer { close(fd) }
        if fstat(fd, &info) == 0, info.st_mode & 0o777 != 0o600 {
            _ = fchmod(fd, 0o600)
        }
        var offset = 0
        try line.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw IOError(operation: "write audit log", code: errno)
                }
            }
        }
    }

    private func ensureDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        let path = directory.path(percentEncoded: false)
        var info = stat()
        if stat(path, &info) == 0 { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func rotate() {
        let manager = FileManager.default
        try? manager.removeItem(at: rotatedURL(generations))
        if generations > 1 {
            for generation in stride(from: generations - 1, through: 1, by: -1) {
                let from = rotatedURL(generation)
                if manager.fileExists(atPath: from.path(percentEncoded: false)) {
                    try? manager.moveItem(at: from, to: rotatedURL(generation + 1))
                }
            }
        }
        try? manager.moveItem(at: fileURL, to: rotatedURL(1))
    }

    static func clipped(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        arguments.mapValues(clip)
    }

    private static func clip(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text) where text.utf8.count > maxArgumentLength:
            var bytes = Array(text.utf8.prefix(maxArgumentLength))
            // Drop a trailing partial (or complete) multi-byte character rather than split it.
            while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
            if let last = bytes.last, last >= 0xC0 { bytes.removeLast() }
            return .string(String(decoding: bytes, as: UTF8.self) + "…")
        case .array(let items): return .array(items.prefix(64).map(clip))
        case .object(let members): return .object(members.mapValues(clip))
        default: return value
        }
    }
}
