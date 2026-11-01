import Foundation
import Observation

/// The host inventory, kept in the Keychain the Mac and iOS apps share and observable from SwiftUI.
///
/// Each host is one item that iCloud Keychain carries to the user's other devices. The MCP tier
/// is not part of it: every device keeps its own tiers in items that never sync, so raising a
/// host's tier on one Mac never lets agents run commands through another. A host that arrives from
/// another device starts at ``MCPTier/off`` there.
///
/// Lives on the main actor: the UI owns it, and other actors (pollers, the MCP bridge) receive
/// `RemoteHost` values from it.
///
/// - Every mutation writes the Keychain first and only then updates ``hosts``; if the write
///   fails, memory is unchanged and the error is thrown.
///
/// ```swift
/// let store = HostStore.system()            // the apps
/// let testStore = HostStore.inMemory()      // tests, previews
/// ```
@MainActor
@Observable
public final class HostStore {
    /// All hosts, oldest first.
    public private(set) var hosts: [RemoteHost] = []
    /// Set when the last ``reload()`` could not read the Keychain; `nil` otherwise.
    public private(set) var loadError: HostStoreError?

    @ObservationIgnored private let keychain: any KeychainStore
    @ObservationIgnored private let tiers: any KeychainStore
    @ObservationIgnored private var addedAt: [RemoteHost.ID: Date] = [:]

    /// Hosts in `keychain` (synced items), this device's MCP tiers in `tiers` (local items).
    public init(keychain: any KeychainStore, tiers: any KeychainStore) {
        self.keychain = keychain
        self.tiers = tiers
        reload()
    }

    /// The apps' store, in ``SystemKeychain``.
    public static func system(service: String = "app.aeroops.hosts") -> HostStore {
        HostStore(
            keychain: SystemKeychain(service: service, label: "AeroOps host"),
            tiers: SystemKeychain(service: service + ".mcp-tiers", label: "AeroOps AI agent access"))
    }

    /// A store in memory, for tests, previews and demos.
    public static func inMemory() -> HostStore {
        HostStore(keychain: InMemoryKeychain(), tiers: InMemoryKeychain())
    }

    /// The host with `id`, if any.
    public func host(id: RemoteHost.ID) -> RemoteHost? {
        hosts.first { $0.id == id }
    }

    /// Appends `host` and saves. Throws ``HostStoreError/duplicateID(_:)`` if the id exists.
    public func add(_ host: RemoteHost) throws(HostStoreError) {
        guard self.host(id: host.id) == nil else { throw .duplicateID(host.id) }
        let added = Date.now
        try write(host, addedAt: added)
        addedAt[host.id] = added
        hosts.append(host)
    }

    /// Replaces the host with the same id and saves. Throws ``HostStoreError/notFound(_:)`` if absent.
    public func update(_ host: RemoteHost) throws(HostStoreError) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { throw .notFound(host.id) }
        try write(host, addedAt: addedAt[host.id] ?? .now)
        hosts[index] = host
    }

    /// Removes the host with `id` here and on the user's other devices. Throws
    /// ``HostStoreError/notFound(_:)`` if absent.
    public func delete(id: RemoteHost.ID) throws(HostStoreError) {
        guard self.host(id: id) != nil else { throw .notFound(id) }
        do {
            try keychain.delete(id.uuidString)
            try tiers.delete(id.uuidString)
        } catch {
            throw .writeFailed(reason: error.localizedDescription)
        }
        hosts.removeAll { $0.id == id }
        addedAt[id] = nil
    }

    /// Re-reads the Keychain, including hosts added, changed or removed on the user's other
    /// devices. When it cannot be read, ``hosts`` keeps what it had. Returns whether ``hosts`` changed.
    @discardableResult
    public func reload() -> Bool {
        let previous = hosts
        loadError = nil
        do { try loadItems() } catch { loadError = error }
        return hosts != previous
    }

    private func loadItems() throws(HostStoreError) {
        let records = try items(of: keychain).compactMap(HostRecord.init).sorted(by: HostRecord.isOlder)
        let tiers = try localTiers()
        hosts = records.map { $0.host(tier: tiers[$0.host.id] ?? .off) }
        addedAt = Dictionary(records.map { ($0.host.id, $0.addedAt) }) { first, _ in first }
    }

    private func localTiers() throws(HostStoreError) -> [RemoteHost.ID: MCPTier] {
        let pairs = try items(of: tiers).compactMap { item -> (RemoteHost.ID, MCPTier)? in
            guard let id = UUID(uuidString: item.account),
                  let tier = MCPTier(rawValue: String(decoding: item.record, as: UTF8.self)) else { return nil }
            return (id, tier)
        }
        return Dictionary(pairs) { first, _ in first }
    }

    private func write(_ host: RemoteHost, addedAt: Date) throws(HostStoreError) {
        let tier = KeychainItem(account: host.id.uuidString, record: Data(host.mcpTier.rawValue.utf8), syncs: false)
        do {
            try tiers.save(tier, secret: Data())
            try keychain.save(try HostRecord(host: host, addedAt: addedAt).item(), secret: Data())
        } catch {
            throw .writeFailed(reason: error.localizedDescription)
        }
    }

    private func items(of store: any KeychainStore) throws(HostStoreError) -> [KeychainItem] {
        do {
            return try store.items()
        } catch {
            throw .unreadable(reason: error.localizedDescription)
        }
    }
}

/// One host's synced Keychain record: the host, whose tier is always ``MCPTier/off`` there (each
/// device applies its own), and when it was added, which orders the inventory.
private struct HostRecord: Codable {
    var host: RemoteHost
    var addedAt: Date

    init(host: RemoteHost, addedAt: Date) {
        self.host = host
        self.host.mcpTier = .off
        self.addedAt = addedAt
    }

    init?(_ item: KeychainItem) {
        guard let record = try? JSONDecoder().decode(HostRecord.self, from: item.record),
              record.host.id.uuidString == item.account else { return nil }
        self = record
    }

    func item() throws -> KeychainItem {
        KeychainItem(account: host.id.uuidString, record: try JSONEncoder().encode(self), syncs: true)
    }

    func host(tier: MCPTier) -> RemoteHost {
        var host = host
        host.mcpTier = tier
        return host
    }

    static func isOlder(_ a: HostRecord, _ b: HostRecord) -> Bool {
        (a.addedAt, a.host.id.uuidString) < (b.addedAt, b.host.id.uuidString)
    }
}

/// Errors from ``HostStore``.
public enum HostStoreError: Error, Sendable, Hashable, LocalizedError {
    /// The Keychain could not list the hosts.
    case unreadable(reason: String)
    /// Saving failed; the in-memory hosts were left unchanged.
    case writeFailed(reason: String)
    /// ``HostStore/add(_:)`` was given an id that already exists.
    case duplicateID(UUID)
    /// No host has this id.
    case notFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "The hosts could not be read from the Keychain: \(reason)"
        case .writeFailed(let reason): "Saving hosts failed: \(reason)"
        case .duplicateID(let id): "A host with id \(id) already exists."
        case .notFound(let id): "No host with id \(id)."
        }
    }
}
