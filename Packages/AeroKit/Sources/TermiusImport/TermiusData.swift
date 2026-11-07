import Foundation

/// A host from Termius, with the settings it inherits from its groups resolved.
public struct TermiusHost: Sendable, Identifiable, Hashable {
    /// Termius's local id for the row.
    public var id: Int64
    /// The label shown in Termius; may be empty.
    public var label: String
    public var address: String
    /// `nil` when neither the host nor its groups set one (Termius then uses 22).
    public var port: Int?
    /// `nil` when neither the host nor its groups set one.
    public var username: String?
    public var password: TermiusSecret?
    /// The key the host logs in with, from ``TermiusData/keys``.
    public var keyID: TermiusKey.ID?
    /// Group labels from the top-level group down.
    public var groups: [String]
    /// Termius tag labels.
    public var tags: [String]
    /// Why AeroOps can't connect to the host the way Termius does, if so.
    public var unsupported: Unsupported?

    public init(
        id: Int64, label: String, address: String, port: Int? = nil, username: String? = nil, password: TermiusSecret? = nil,
        keyID: TermiusKey.ID? = nil, groups: [String] = [], tags: [String] = [], unsupported: Unsupported? = nil
    ) {
        self.id = id
        self.label = label
        self.address = address
        self.port = port
        self.username = username
        self.password = password
        self.keyID = keyID
        self.groups = groups
        self.tags = tags
        self.unsupported = unsupported
    }

    public enum Unsupported: Sendable, Hashable {
        /// Telnet only, no SSH settings.
        case telnet
        /// Connects through other hosts (a Termius host chain).
        case hostChain
        /// Connects through a SOCKS or HTTP proxy, or a proxy command.
        case proxy
        /// Uses a hardware security key or Termius's own key service, which can't be exported.
        case hardwareKey
    }

    /// The name to give the host: its label, or its address when it has none.
    public var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }
}

/// A private key from Termius.
public struct TermiusKey: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var label: String
    /// The key file's text, as Termius stores it: OpenSSH, PEM or PuTTY format.
    public var privateKey: TermiusSecret
    /// The passphrase Termius saved for an encrypted key, if any.
    public var passphrase: TermiusSecret?

    public init(id: Int64, label: String, privateKey: TermiusSecret, passphrase: TermiusSecret? = nil) {
        self.id = id
        self.label = label
        self.privateKey = privateKey
        self.passphrase = passphrase
    }
}

/// Everything AeroOps imports from Termius, decrypted.
public struct TermiusData: Sendable {
    public var hosts: [TermiusHost]
    public var keys: [TermiusKey.ID: TermiusKey]
    /// Rows that could not be decoded and were skipped.
    public var skippedRows: Int

    public init(hosts: [TermiusHost], keys: [TermiusKey], skippedRows: Int = 0) {
        self.hosts = hosts
        self.keys = Dictionary(keys.map { ($0.id, $0) }) { first, _ in first }
        self.skippedRows = skippedRows
    }

    /// Termius's database names (each holds one object store of the same name).
    enum Table: String, CaseIterable {
        case hosts, groups, tags, keys, proxies
        case tagHosts = "tag_hosts"
        case sshConfigs = "ssh_configs"
        case sshIdentities = "ssh_identities"
        case sshConfigIdentities = "ssh_config_identities"
        case hostChains = "host_chains"
    }

    /// Links decrypted rows. `rows` maps each ``Table`` to its rows; missing tables are empty.
    init(rows: [Table: [JSValue]], cipher: TermiusFieldCipher, skippedRows: Int = 0) throws(TermiusImportError) {
        let linker = try Linker(rows: rows, cipher: cipher)
        self.keys = linker.keys
        self.hosts = try linker.hosts()
        self.skippedRows = skippedRows
    }
}

extension TermiusData {
    /// Trims the address. Termius sometimes stores an IPv4 address as its 32-bit number.
    static func normalizedAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 10, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let packed = UInt64(trimmed), packed <= UInt64(UInt32.max), packed > 255 else { return trimmed }
        return [24, 16, 8, 0].map { String((packed >> UInt64($0)) & 0xFF) }.joined(separator: ".")
    }
}

/// One table's live rows, findable by server id or local id.
private struct RowIndex {
    var rows: [Row] = []
    private var byID: [Int64: Int] = [:]
    private var byLocalID: [Int64: Int] = [:]

    init(_ values: [JSValue], cipher: TermiusFieldCipher) throws(TermiusImportError) {
        for value in values where value.isObject {
            let row = try Row(value, cipher: cipher)
            if !row.isDeleted { rows.append(row) }
        }
        rows.sort { ($0.localID ?? .max, $0.id ?? .max) < ($1.localID ?? .max, $1.id ?? .max) }
        byID = Self.positions(of: rows) { $0.id }
        byLocalID = Self.positions(of: rows) { $0.localID }
    }

    private static func positions(of rows: [Row], by key: (Row) -> Int64?) -> [Int64: Int] {
        var positions: [Int64: Int] = [:]
        for (position, row) in rows.enumerated() {
            if let id = key(row) { positions[id] = position }
        }
        return positions
    }

    /// Resolves a reference: `{id, local_id}` (server id first) or a bare number.
    subscript(reference: JSValue?) -> Row? {
        switch reference {
        case .object?: lookup(id: Row.integer(reference?["id"]), localID: Row.integer(reference?["local_id"]))
        case .number?: lookup(id: Row.integer(reference), localID: Row.integer(reference))
        default: nil
        }
    }

    private func lookup(id: Int64?, localID: Int64?) -> Row? {
        let position = id.flatMap { byID[$0] } ?? localID.flatMap { byLocalID[$0] }
        return position.map { rows[$0] }
    }
}

/// A row with its encrypted fields readable. Termius also keeps an encrypted `content` JSON
/// copy of a row's fields; it fills fields the row itself lacks.
private struct Row {
    var value: JSValue
    var content: [String: Any] = [:]
    let cipher: TermiusFieldCipher

    init(_ value: JSValue, cipher: TermiusFieldCipher) throws(TermiusImportError) {
        self.value = value
        self.cipher = cipher
        if let raw = value["content"]?.string, !raw.isEmpty {
            let json = try cipher.decrypt(raw)
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                content = object
            }
        }
    }

    var id: Int64? { Self.integer(value["id"]) }
    var localID: Int64? { Self.integer(value["local_id"]) }

    /// Rows Termius has deleted but not yet synced away.
    var isDeleted: Bool {
        (value["status"]?.string ?? "").uppercased().contains("DELETE")
    }

    /// A reference field (`ssh_config`, `group`, …) or `nil` when null.
    func reference(_ name: String) -> JSValue? {
        guard let field = value[name], !field.isNullish else { return nil }
        return field
    }

    /// A string field, decrypted. Empty strings read as `nil`.
    func string(_ name: String) throws(TermiusImportError) -> String? {
        let text: String
        if let field = value[name]?.string {
            text = try cipher.decrypt(field)
        } else if let field = content[name] as? String {
            text = field
        } else {
            return nil
        }
        return text.isEmpty ? nil : text
    }

    func number(_ name: String) -> Int64? {
        Self.integer(value[name]) ?? (content[name] as? NSNumber).flatMap { Self.integer(.number($0.doubleValue)) }
    }

    static func integer(_ value: JSValue?) -> Int64? {
        guard let number = value?.number, number.isFinite, number.rounded() == number, abs(number) < 9e15 else { return nil }
        return Int64(number)
    }
}

/// Resolves hosts' settings through their configs, identities and groups.
private struct Linker {
    let tables: [TermiusData.Table: RowIndex]
    private(set) var keys: [TermiusKey.ID: TermiusKey] = [:]
    /// ssh_config row id (local) → identity reference, from `ssh_config_identities`.
    private var linkedIdentities: [Int64: JSValue] = [:]

    init(rows: [TermiusData.Table: [JSValue]], cipher: TermiusFieldCipher) throws(TermiusImportError) {
        var tables: [TermiusData.Table: RowIndex] = [:]
        for table in TermiusData.Table.allCases {
            tables[table] = try RowIndex(rows[table] ?? [], cipher: cipher)
        }
        self.tables = tables
        for link in tables[.sshConfigIdentities]!.rows {
            guard let config = tables[.sshConfigs]![link.reference("ssh_config")], let local = config.localID,
                  let identity = link.reference("identity") else { continue }
            linkedIdentities[local] = identity
        }
        for row in tables[.keys]!.rows {
            guard let local = row.localID, let privateKey = try row.string("private_key") else { continue }
            keys[local] = TermiusKey(
                id: local,
                label: try row.string("label") ?? "",
                privateKey: TermiusSecret(privateKey),
                passphrase: try row.string("passphrase").map(TermiusSecret.init))
        }
    }

    private func table(_ table: TermiusData.Table) -> RowIndex { tables[table]! }

    func hosts() throws(TermiusImportError) -> [TermiusHost] {
        let tags = try tagsByHost()
        let chained = Set(table(.hostChains).rows.compactMap { table(.sshConfigs)[$0.reference("ssh_config")]?.localID })
        var result: [TermiusHost] = []
        for row in table(.hosts).rows {
            let settings = settings(of: row)
            guard var host = try host(from: row, settings) else { continue }
            host.tags = tags[host.id] ?? []
            host.unsupported = unsupported(host, row: row, settings: settings, chainedConfigs: chained)
            result.append(host)
        }
        return result
    }

    private func tagsByHost() throws(TermiusImportError) -> [Int64: [String]] {
        var tags: [Int64: [String]] = [:]
        for link in table(.tagHosts).rows {
            guard let host = table(.hosts)[link.reference("host")], let local = host.localID,
                  let tag = table(.tags)[link.reference("tag")], let label = try tag.string("label") else { continue }
            tags[local, default: []].append(label)
        }
        return tags
    }

    private struct Settings {
        var groups: [Row]
        /// The host's own config first, then each group's, nearest group first.
        var configs: [Row]
        var identities: [Row]
    }

    private func settings(of row: Row) -> Settings {
        let groups = groupChain(of: row)
        let configs = ([row] + groups).compactMap { table(.sshConfigs)[$0.reference("ssh_config")] }
        return Settings(groups: groups, configs: configs, identities: configs.compactMap { identity(of: $0) })
    }

    private func host(from row: Row, _ settings: Settings) throws(TermiusImportError) -> TermiusHost? {
        guard let local = row.localID, let address = try row.string("address") else { return nil }
        let identities = settings.identities
        return TermiusHost(
            id: local,
            label: try row.string("label") ?? "",
            address: TermiusData.normalizedAddress(address),
            port: settings.configs.lazy.compactMap { $0.number("port") }.first { (1...65535).contains($0) }.map(Int.init),
            username: try Self.first(identities) { identity throws(TermiusImportError) in try identity.string("username") },
            password: try Self.first(identities) { identity throws(TermiusImportError) in try identity.string("password") }.map(TermiusSecret.init),
            keyID: identities.lazy.compactMap { self.table(.keys)[$0.reference("ssh_key")]?.localID }.first,
            groups: try groupLabels(settings.groups),
            tags: [])
    }

    /// Group labels from the top-level group down.
    private func groupLabels(_ chain: [Row]) throws(TermiusImportError) -> [String] {
        var labels: [String] = []
        for group in chain.reversed() {
            if let label = try group.string("label") { labels.append(label) }
        }
        return labels
    }

    private func unsupported(
        _ host: TermiusHost, row: Row, settings: Settings, chainedConfigs: Set<Int64>
    ) -> TermiusHost.Unsupported? {
        if row.reference("ssh_config") == nil, row.reference("telnet_config") != nil { return .telnet }
        if settings.configs.contains(where: { $0.localID.map { chainedConfigs.contains($0) } == true }) { return .hostChain }
        if settings.configs.contains(where: { $0.reference("proxycommand") != nil }) { return .proxy }
        guard host.keyID == nil, host.password == nil else { return nil }
        return settings.identities.contains { $0.reference("hardware_key") != nil } ? .hardwareKey : nil
    }

    /// The host's group, its parent, and so on up to the top. Stops at a cycle.
    private func groupChain(of row: Row) -> [Row] {
        var chain: [Row] = []
        var seen: Set<Int64> = []
        var next = table(.groups)[row.reference("group")]
        while let group = next, let local = group.localID, seen.insert(local).inserted, chain.count < 32 {
            chain.append(group)
            next = table(.groups)[group.reference("parent_group")]
        }
        return chain
    }

    private func identity(of config: Row) -> Row? {
        if let identity = table(.sshIdentities)[config.reference("identity")] { return identity }
        guard let local = config.localID else { return nil }
        return table(.sshIdentities)[linkedIdentities[local]]
    }

    private static func first(_ rows: [Row], _ field: (Row) throws(TermiusImportError) -> String?) throws(TermiusImportError) -> String? {
        for row in rows {
            if let value = try field(row) { return value }
        }
        return nil
    }
}
