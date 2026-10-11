import Foundation
import Observation

/// The host inventory, persisted as `hosts.json` and observable from SwiftUI.
///
/// Lives on the main actor: the UI owns it, and other actors (pollers, the MCP bridge) receive
/// `RemoteHost` values from it. The file is tiny, so reads and atomic writes happen synchronously.
///
/// - Every mutation writes the whole file atomically first and only then updates ``hosts``; if
///   the write fails, memory is unchanged and the error is thrown.
/// - A file that cannot be decoded is moved aside to `hosts.corrupt-<timestamp>.json` so it is
///   never overwritten, the store starts empty, and ``loadError`` says what happened. If it
///   cannot be moved (or cannot be read at all), writes stay blocked until ``reload()`` succeeds.
///
/// ```swift
/// @State private var store = HostStore()           // ~/Library/Application Support/AeroOps
/// let testStore = HostStore(directory: tempDir)     // tests
/// ```
@MainActor
@Observable
public final class HostStore {
    /// File name inside the store directory.
    nonisolated public static let fileName = "hosts.json"

    /// All hosts, in insertion order.
    public private(set) var hosts: [RemoteHost] = []
    /// Set when the last ``reload()`` found a corrupt or unreadable file; `nil` otherwise.
    public private(set) var loadError: HostStoreError?
    /// Full path of `hosts.json`.
    public let fileURL: URL

    @ObservationIgnored private var writesBlocked = false

    /// Opens the store in `directory` (created on first save) and loads it.
    public init(directory: URL = AeroPaths.standard.applicationSupport) {
        fileURL = directory.appending(path: Self.fileName)
        reload()
    }

    /// The host with `id`, if any.
    public func host(id: RemoteHost.ID) -> RemoteHost? {
        hosts.first { $0.id == id }
    }

    /// Appends `host` and saves. Throws ``HostStoreError/duplicateID(_:)`` if the id exists.
    public func add(_ host: RemoteHost) throws(HostStoreError) {
        guard self.host(id: host.id) == nil else { throw .duplicateID(host.id) }
        try commit(hosts + [host])
    }

    /// Replaces the host with the same id and saves. Throws ``HostStoreError/notFound(_:)`` if absent.
    public func update(_ host: RemoteHost) throws(HostStoreError) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { throw .notFound(host.id) }
        var next = hosts
        next[index] = host
        try commit(next)
    }

    /// Removes the host with `id` and saves. Throws ``HostStoreError/notFound(_:)`` if absent.
    public func delete(id: RemoteHost.ID) throws(HostStoreError) {
        guard self.host(id: id) != nil else { throw .notFound(id) }
        try commit(hosts.filter { $0.id != id })
    }

    /// Re-reads `hosts.json`. A missing file means an empty inventory.
    public func reload() {
        loadError = nil
        writesBlocked = false
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            hosts = []
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            hosts = []
            writesBlocked = true
            loadError = .unreadable(reason: error.localizedDescription)
            return
        }
        do {
            hosts = try HostsFile.decode(data)
        } catch {
            hosts = []
            let reason = String(describing: error)
            let backup = backupURL()
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                loadError = .corruptFile(backupURL: backup, reason: reason)
            } catch {
                writesBlocked = true
                loadError = .corruptFile(backupURL: nil, reason: reason)
            }
        }
    }

    private func commit(_ next: [RemoteHost]) throws(HostStoreError) {
        guard !writesBlocked else { throw .writesBlocked }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HostsFile.encode(next).write(to: fileURL, options: .atomic)
        } catch {
            throw .writeFailed(reason: error.localizedDescription)
        }
        hosts = next
    }

    private func backupURL() -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacing(":", with: "")
        return fileURL.deletingLastPathComponent().appending(path: "hosts.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
    }
}

/// Errors from ``HostStore``.
public enum HostStoreError: Error, Sendable, Hashable, LocalizedError {
    /// `hosts.json` could not be decoded. It was moved to `backupURL`; if that is `nil` the move
    /// failed and writes are blocked so the original is not overwritten.
    case corruptFile(backupURL: URL?, reason: String)
    /// `hosts.json` exists but could not be read (e.g. permissions). Writes are blocked.
    case unreadable(reason: String)
    /// Saving failed; the in-memory hosts were left unchanged.
    case writeFailed(reason: String)
    /// A mutation was refused because the existing file could not be loaded safely.
    case writesBlocked
    /// ``HostStore/add(_:)`` was given an id that already exists.
    case duplicateID(UUID)
    /// No host has this id.
    case notFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .corruptFile(let backup?, _):
            "hosts.json was unreadable and has been moved to \(backup.lastPathComponent)."
        case .corruptFile(nil, let reason):
            "hosts.json is unreadable and could not be moved aside: \(reason)"
        case .unreadable(let reason): "hosts.json could not be read: \(reason)"
        case .writeFailed(let reason): "Saving hosts failed: \(reason)"
        case .writesBlocked: "Hosts cannot be saved until hosts.json can be loaded."
        case .duplicateID(let id): "A host with id \(id) already exists."
        case .notFound(let id): "No host with id \(id)."
        }
    }
}

/// On-disk envelope of `hosts.json`: `{ "version": 1, "hosts": [...] }`.
/// A bare `[...]` array is also accepted when reading.
struct HostsFile: Codable {
    static let currentVersion = 1

    var version: Int
    var hosts: [RemoteHost]

    init(version: Int, hosts: [RemoteHost]) {
        self.version = version
        self.hosts = hosts
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        hosts = try c.decode([RemoteHost].self, forKey: .hosts)
    }

    static func decode(_ data: Data) throws -> [RemoteHost] {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(HostsFile.self, from: data).hosts
        } catch {
            // Also accept a bare array; otherwise report the envelope error (the format we write).
            if let hosts = try? decoder.decode([RemoteHost].self, from: data) { return hosts }
            throw error
        }
    }

    static func encode(_ hosts: [RemoteHost]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(HostsFile(version: currentVersion, hosts: hosts))
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
