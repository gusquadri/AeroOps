import Foundation
import Observation

/// The host inventory, kept in the Keychain the Mac and iOS apps share and observable from SwiftUI.
///
/// Each host is one item that iCloud Keychain carries to the user's other devices. The MCP tier
/// is not part of it: every device keeps its own tiers in items that never sync, so raising a
/// host's tier on one Mac never lets agents run commands through another. A host that arrives from
/// another device starts at ``MCPTier/off`` there.
///
/// Hosts can be grouped in ``folders`` and put in any order. Each host's folder and position are
/// part of its synced item (and each folder is an item of its own), so moving a host writes only
/// that host. Editing a host with ``update(_:)`` keeps where it is.
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
    /// All hosts in the user's order: the order of ``hosts(inFolder:)`` within each folder and
    /// outside them. Hosts never moved are oldest first.
    public private(set) var hosts: [RemoteHost] = []
    /// The folders, in the user's order.
    public private(set) var folders: [HostFolder] = []
    /// Set when the last ``reload()`` could not read the Keychain; `nil` otherwise.
    public private(set) var loadError: HostStoreError?

    @ObservationIgnored private let keychain: any KeychainStore
    @ObservationIgnored private let tiers: any KeychainStore
    @ObservationIgnored private var addedAt: [RemoteHost.ID: Date] = [:]
    /// Each host's folder and position.
    private var placements: [RemoteHost.ID: HostPlacement] = [:]
    @ObservationIgnored private var folderPositions: [HostFolder.ID: Double] = [:]

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

    /// The folder with `id`, if any.
    public func folder(id: HostFolder.ID) -> HostFolder? {
        folders.first { $0.id == id }
    }

    /// The folder the host with `id` is in, or `nil` when it is in none (or its folder was
    /// deleted on another device).
    public func folderID(ofHost id: RemoteHost.ID) -> HostFolder.ID? {
        guard let folderID = placements[id]?.folderID, folder(id: folderID) != nil else { return nil }
        return folderID
    }

    /// The hosts in the folder with `folderID`, or with `nil` the hosts in no folder, in order.
    public func hosts(inFolder folderID: HostFolder.ID?) -> [RemoteHost] {
        let existing = Set(folders.map(\.id))
        return hosts.filter { host in
            let stored = placements[host.id]?.folderID
            return (stored.flatMap { existing.contains($0) ? $0 : nil }) == folderID
        }
    }

    /// Appends `host` (to the folder with `folderID`, if given) and saves. Throws
    /// ``HostStoreError/duplicateID(_:)`` if the id exists, ``HostStoreError/notFound(_:)`` if the
    /// folder does not.
    public func add(_ host: RemoteHost, toFolder folderID: HostFolder.ID? = nil) throws(HostStoreError) {
        guard self.host(id: host.id) == nil else { throw .duplicateID(host.id) }
        if let folderID, folder(id: folderID) == nil { throw .notFound(folderID) }
        let added = Date.now
        let placement = HostPlacement(folderID: folderID, position: nextHostPosition())
        try write(host, addedAt: added, placement: placement)
        addedAt[host.id] = added
        placements[host.id] = placement
        hosts.append(host)
    }

    /// Replaces the host with the same id and saves, keeping its folder and position. Throws
    /// ``HostStoreError/notFound(_:)`` if absent.
    public func update(_ host: RemoteHost) throws(HostStoreError) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { throw .notFound(host.id) }
        try write(host, addedAt: addedAt[host.id] ?? .now, placement: placement(of: host.id))
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
        placements[id] = nil
    }

    /// Moves the host with `id` into the folder with `folderID` (`nil`: out of every folder),
    /// just before the host `next` there, or last when `next` is `nil` or not in that folder.
    public func moveHost(
        _ id: RemoteHost.ID, toFolder folderID: HostFolder.ID?, before next: RemoteHost.ID? = nil
    ) throws(HostStoreError) {
        guard host(id: id) != nil else { throw .notFound(id) }
        if let folderID, folder(id: folderID) == nil { throw .notFound(folderID) }
        defer { sortHosts() }
        let others = hosts(inFolder: folderID).filter { $0.id != id }.map { (id: $0.id, position: placement(of: $0.id).position) }
        let index = next.flatMap { next in others.firstIndex { $0.id == next } } ?? others.endIndex
        for (changed, position) in Self.slot(id, at: index, in: others, empty: nextHostPosition()) {
            var placement = placement(of: changed)
            placement.position = position
            if changed == id { placement.folderID = folderID }
            guard placement != placements[changed], let host = host(id: changed) else { continue }
            try write(host, addedAt: addedAt[changed] ?? .now, placement: placement)
            placements[changed] = placement
        }
    }

    /// Drops the host with `id` where `target` is, in `target`'s folder: after it when `id` was
    /// before it in that folder (so a host can reach the end), before it otherwise. This is what
    /// dragging one host onto another does.
    public func moveHost(_ id: RemoteHost.ID, onto target: RemoteHost.ID) throws(HostStoreError) {
        guard id != target else { return }
        guard host(id: target) != nil else { throw .notFound(target) }
        let folderID = folderID(ofHost: target)
        let scope = hosts(inFolder: folderID).map(\.id)
        try moveHost(id, toFolder: folderID, before: Self.neighbour(for: id, onto: target, in: scope))
    }

    /// Adds a folder named `name` (trimmed) after the others and saves. Throws
    /// ``HostStoreError/invalidFolderName`` for a blank or overlong name.
    @discardableResult
    public func addFolder(named name: String) throws(HostStoreError) -> HostFolder {
        guard let name = HostFolder.normalizedName(name) else { throw .invalidFolderName }
        let folder = HostFolder(name: name)
        let position = (folderPositions.values.max() ?? 0) + 1
        try write(folder, position: position)
        folderPositions[folder.id] = position
        folders.append(folder)
        return folder
    }

    /// Renames the folder with `id` and saves.
    public func renameFolder(id: HostFolder.ID, to name: String) throws(HostStoreError) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
        guard let name = HostFolder.normalizedName(name) else { throw .invalidFolderName }
        var folder = folders[index]
        folder.name = name
        try write(folder, position: folderPositions[id] ?? 0)
        folders[index] = folder
    }

    /// Deletes the folder with `id` here and on the user's other devices. Its hosts are kept:
    /// they move, in order, to the end of the hosts in no folder.
    public func deleteFolder(id: HostFolder.ID) throws(HostStoreError) {
        guard folder(id: id) != nil else { throw .notFound(id) }
        for host in hosts(inFolder: id) {
            try moveHost(host.id, toFolder: nil)
        }
        do {
            try keychain.delete(FolderRecord.account(for: id))
        } catch {
            throw .writeFailed(reason: error.localizedDescription)
        }
        folders.removeAll { $0.id == id }
        folderPositions[id] = nil
    }

    /// Moves the folder with `id` just before the folder `next`, or last when `next` is `nil`.
    public func moveFolder(_ id: HostFolder.ID, before next: HostFolder.ID?) throws(HostStoreError) {
        guard folder(id: id) != nil else { throw .notFound(id) }
        defer { sortFolders() }
        let others = folders.filter { $0.id != id }.map { (id: $0.id, position: folderPositions[$0.id] ?? 0) }
        let index = next.flatMap { next in others.firstIndex { $0.id == next } } ?? others.endIndex
        for (changed, position) in Self.slot(id, at: index, in: others, empty: 1) {
            guard folderPositions[changed] != position, let folder = folder(id: changed) else { continue }
            try write(folder, position: position)
            folderPositions[changed] = position
        }
    }

    /// Drops the folder with `id` where `target` is; see ``moveHost(_:onto:)``.
    public func moveFolder(_ id: HostFolder.ID, onto target: HostFolder.ID) throws(HostStoreError) {
        guard id != target else { return }
        guard folder(id: target) != nil else { throw .notFound(target) }
        try moveFolder(id, before: Self.neighbour(for: id, onto: target, in: folders.map(\.id)))
    }

    /// Re-reads the Keychain, including hosts added, changed or removed on the user's other
    /// devices. When it cannot be read, ``hosts`` keeps what it had. Returns whether ``hosts`` changed.
    @discardableResult
    public func reload() -> Bool {
        let previous = (hosts, folders, placements)
        loadError = nil
        do { try loadItems() } catch { loadError = error }
        return hosts != previous.0 || folders != previous.1 || placements != previous.2
    }

    private func loadItems() throws(HostStoreError) {
        let items = try items(of: keychain)
        let records = items.compactMap(HostRecord.init).sorted(by: HostRecord.isOlder)
        let folderRecords = items.compactMap(FolderRecord.init)
        let tiers = try localTiers()
        hosts = records.map { $0.host(tier: tiers[$0.host.id] ?? .off) }
        addedAt = Dictionary(records.map { ($0.host.id, $0.addedAt) }) { first, _ in first }
        placements = Dictionary(records.map { ($0.host.id, $0.placement) }) { first, _ in first }
        folders = folderRecords.map(\.folder)
        folderPositions = Dictionary(folderRecords.map { ($0.folder.id, $0.position) }) { first, _ in first }
        sortHosts()
        sortFolders()
    }

    private func placement(of id: RemoteHost.ID) -> HostPlacement {
        placements[id] ?? HostPlacement(folderID: nil, position: (addedAt[id] ?? .now).timeIntervalSinceReferenceDate)
    }

    /// After every host, and no earlier than now, so hosts added on two devices stay in order.
    private func nextHostPosition() -> Double {
        let last = placements.values.map(\.position).max() ?? -.infinity
        return max(Date.now.timeIntervalSinceReferenceDate, last + 1)
    }

    private func sortHosts() {
        let positions = hosts.map { (id: $0.id, position: placement(of: $0.id).position) }
        let order = Dictionary(uniqueKeysWithValues: positions.sorted(by: Self.isBefore).enumerated().map { ($1.id, $0) })
        hosts.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
    }

    private func sortFolders() {
        let positions = folders.map { (id: $0.id, position: folderPositions[$0.id] ?? 0) }
        let order = Dictionary(uniqueKeysWithValues: positions.sorted(by: Self.isBefore).enumerated().map { ($1.id, $0) })
        folders.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
    }

    private static func isBefore(_ a: (id: UUID, position: Double), _ b: (id: UUID, position: Double)) -> Bool {
        (a.position, a.id.uuidString) < (b.position, b.id.uuidString)
    }

    /// The new position for `id` put at `index` of `others` (in order, without `id`): between its
    /// neighbours, so only `id` is written. When no number fits between them, every item in the
    /// list gets a new position. `empty` is the position in an empty list.
    static func slot(
        _ id: UUID, at index: Int, in others: [(id: UUID, position: Double)], empty: Double
    ) -> [(UUID, Double)] {
        let previous = index > others.startIndex ? others[index - 1].position : nil
        let next = index < others.endIndex ? others[index].position : nil
        if let position = between(previous, next, empty: empty) { return [(id, position)] }
        var ids = others.map(\.id)
        ids.insert(id, at: index)
        let base = others[0].position
        return ids.enumerated().map { ($1, base + Double($0)) }
    }

    private static func between(_ previous: Double?, _ next: Double?, empty: Double) -> Double? {
        switch (previous, next) {
        case (nil, nil): empty
        case (let previous?, nil): previous + 1
        case (nil, let next?): next - 1
        case (let previous?, let next?): midpoint(previous, next)
        }
    }

    private static func midpoint(_ previous: Double, _ next: Double) -> Double? {
        let middle = previous / 2 + next / 2
        return previous < middle && middle < next ? middle : nil
    }

    /// What dropping `id` onto `target` in `scope` puts it before: the item after `target` when
    /// `id` comes before `target` in `scope`, else `target` itself. `nil` means last.
    static func neighbour(for id: UUID, onto target: UUID, in scope: [UUID]) -> UUID? {
        guard let to = scope.firstIndex(of: target) else { return nil }
        guard let from = scope.firstIndex(of: id), from < to else { return target }
        let after = scope.index(after: to)
        return after < scope.endIndex ? scope[after] : nil
    }

    private func localTiers() throws(HostStoreError) -> [RemoteHost.ID: MCPTier] {
        let pairs = try items(of: tiers).compactMap { item -> (RemoteHost.ID, MCPTier)? in
            guard let id = UUID(uuidString: item.account),
                  let tier = MCPTier(rawValue: String(decoding: item.record, as: UTF8.self)) else { return nil }
            return (id, tier)
        }
        return Dictionary(pairs) { first, _ in first }
    }

    private func write(_ host: RemoteHost, addedAt: Date, placement: HostPlacement) throws(HostStoreError) {
        let tier = KeychainItem(account: host.id.uuidString, record: Data(host.mcpTier.rawValue.utf8), syncs: false)
        do {
            try tiers.save(tier, secret: Data())
            try keychain.save(try HostRecord(host: host, addedAt: addedAt, placement: placement).item(), secret: Data())
        } catch {
            throw .writeFailed(reason: error.localizedDescription)
        }
    }

    private func write(_ folder: HostFolder, position: Double) throws(HostStoreError) {
        do {
            try keychain.save(try FolderRecord(folder: folder, position: position).item(), secret: Data())
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

/// Where a host is: its folder, and its position among the hosts there (smaller first).
private struct HostPlacement: Hashable {
    var folderID: HostFolder.ID?
    var position: Double
}

/// One host's synced Keychain record: the host, whose tier is always ``MCPTier/off`` there (each
/// device applies its own), when it was added, and its folder and position. Records from before
/// folders have neither: no folder, ordered by when they were added.
private struct HostRecord: Codable {
    var host: RemoteHost
    var addedAt: Date
    var folderID: HostFolder.ID?
    var position: Double?

    init(host: RemoteHost, addedAt: Date, placement: HostPlacement) {
        self.host = host
        self.host.mcpTier = .off
        self.addedAt = addedAt
        folderID = placement.folderID
        position = placement.position
    }

    var placement: HostPlacement {
        HostPlacement(folderID: folderID, position: position ?? addedAt.timeIntervalSinceReferenceDate)
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

/// One folder's synced Keychain record, in the hosts' service under `folder.<id>` (which no host
/// record decodes as, so versions without folders skip it).
private struct FolderRecord: Codable {
    var folder: HostFolder
    var position: Double

    static func account(for id: HostFolder.ID) -> String { "folder." + id.uuidString }

    init(folder: HostFolder, position: Double) {
        self.folder = folder
        self.position = position
    }

    init?(_ item: KeychainItem) {
        guard item.account.hasPrefix("folder."),
              let record = try? JSONDecoder().decode(FolderRecord.self, from: item.record),
              Self.account(for: record.folder.id) == item.account else { return nil }
        self = record
    }

    func item() throws -> KeychainItem {
        KeychainItem(account: Self.account(for: folder.id), record: try JSONEncoder().encode(self), syncs: true)
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
    /// No host (or folder) has this id.
    case notFound(UUID)
    /// A folder name was blank or longer than ``HostFolder/maxNameLength``.
    case invalidFolderName

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "The hosts could not be read from the Keychain: \(reason)"
        case .writeFailed(let reason): "Saving hosts failed: \(reason)"
        case .duplicateID(let id): "A host with id \(id) already exists."
        case .notFound(let id): "No host or folder with id \(id)."
        case .invalidFolderName: "A folder needs a name of 1 to \(HostFolder.maxNameLength) characters."
        }
    }
}
