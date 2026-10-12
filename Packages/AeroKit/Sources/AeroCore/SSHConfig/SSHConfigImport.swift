import Foundation

/// One `Host` from an SSH config, ready to show in the import sheet.
public struct SSHConfigImportCandidate: Identifiable, Sendable, Hashable {
    /// Whether and how the host can be imported.
    public enum Status: Sendable, Hashable {
        /// Can be imported; checked by default.
        case ready
        /// An inventory host already has the same address, port and user. Unchecked by default.
        case alreadyAdded(existingName: String)
        /// An earlier entry in the config has the same address, port and user. Unchecked by default.
        case sameAsEarlier(alias: String)
        /// Can't be imported, for `reason` (a jump host, an invalid address, ...).
        case unsupported(reason: String)
    }

    /// The `Host` name in the config. Unique within one import.
    public var alias: String
    /// The host that would be added: a fresh id, no key, default MCP tier.
    public var host: RemoteHost
    public var status: Status
    /// `IdentityFile`s that applied, as written. AeroOps never reads them; the user imports the
    /// key in Settings › Keys.
    public var identityFiles: [String]
    /// The config had no `User`, so ``host`` uses the local account name, as ssh would.
    public var usesLocalUser: Bool

    public var id: String { alias }

    /// Unsupported hosts can't be checked.
    public var isSelectable: Bool {
        if case .unsupported = status { false } else { true }
    }

    /// Only ``Status/ready`` hosts start checked.
    public var isSelectedByDefault: Bool { status == .ready }

    /// The name differs from the alias because an inventory host (or an earlier entry) already
    /// uses it.
    public var isRenamed: Bool { host.name != alias }
}

/// Turns a parsed ``SSHClientConfig`` into ``SSHConfigImportCandidate``s.
///
/// - The address is `HostName` (with `%h` and `%%` expanded, as OpenSSH does) or the alias.
/// - The user is `User`, or `localUser` when the config has none.
/// - Hosts reached through `ProxyJump` or `ProxyCommand` are unsupported: ``RemoteHost`` has no
///   jump host, and dropping it would point AeroOps at an address it can't reach.
/// - Address, user and port are checked with the same character rules as the host editor and
///   SSHKit's config writer, so hostile values (`-oProxyCommand=…`, `$(…)`, control
///   characters) are refused here, not just later.
/// - Hosts with the same address (ignoring case), port and user as an inventory host, or as an
///   earlier entry, are marked as duplicates.
/// - Names are kept unique ignoring case against the inventory and each other: a clash gets
///   " 2", " 3", ...
public enum SSHConfigImport {
    /// Names longer than this are shortened (the host editor allows 64 characters).
    static let maxNameLength = 60
    static let maxAddressLength = 253
    static let maxUserLength = 64

    public static func candidates(
        from config: SSHClientConfig,
        existingHosts: [RemoteHost],
        localUser: String,
        makeID: () -> UUID = UUID.init
    ) -> [SSHConfigImportCandidate] {
        candidates(from: config.resolvedHosts(), existingHosts: existingHosts, localUser: localUser, makeID: makeID)
    }

    public static func candidates(
        from hosts: [SSHConfigHost],
        existingHosts: [RemoteHost],
        localUser: String,
        makeID: () -> UUID = UUID.init
    ) -> [SSHConfigImportCandidate] {
        var takenNames = Set(existingHosts.map { folded($0.name) })
        var earlier: [(alias: String, host: RemoteHost)] = []
        var result: [SSHConfigImportCandidate] = []
        for resolved in hosts {
            let host = RemoteHost(
                id: makeID(),
                name: resolved.alias,
                address: expandHostName(resolved.hostName, alias: resolved.alias) ?? resolved.hostName ?? resolved.alias,
                port: resolved.port.flatMap(parsePort) ?? RemoteHost.defaultPort,
                user: resolved.user ?? localUser
            )
            var status = SSHConfigImportCandidate.Status.ready
            if let reason = unsupportedReason(resolved, host: host) {
                status = .unsupported(reason: reason)
            } else if let existing = existingHosts.first(where: { isSameTarget($0, host) }) {
                status = .alreadyAdded(existingName: existing.name)
            } else if let previous = earlier.first(where: { isSameTarget($0.host, host) }) {
                status = .sameAsEarlier(alias: previous.alias)
            }
            var candidate = SSHConfigImportCandidate(
                alias: resolved.alias,
                host: host,
                status: status,
                identityFiles: resolved.identityFiles,
                usesLocalUser: resolved.user == nil
            )
            // Unsupported hosts are never added, so they neither take a name nor count as earlier.
            if candidate.isSelectable {
                candidate.host.name = uniqueName(for: resolved.alias, taken: &takenNames)
                earlier.append((resolved.alias, candidate.host))
            }
            result.append(candidate)
        }
        return result
    }

    /// Same address (ignoring case), port and user.
    public static func isSameTarget(_ a: RemoteHost, _ b: RemoteHost) -> Bool {
        a.port == b.port && a.user == b.user && folded(a.address) == folded(b.address)
    }

    // MARK: - Rules

    private static func unsupportedReason(_ resolved: SSHConfigHost, host: RemoteHost) -> String? {
        if let issue = nameIssue(resolved.alias) { return issue }
        switch resolved.proxy {
        case .jump(let jump)?:
            return "Connects through ProxyJump \(quoted(jump)). AeroOps can't use jump hosts yet."
        case .command?:
            return "Connects through a ProxyCommand. AeroOps can't use proxy commands yet."
        case nil:
            break
        }
        if let hostName = resolved.hostName, expandHostName(hostName, alias: resolved.alias) == nil {
            return "HostName \(quoted(hostName)) uses a % token AeroOps can't expand."
        }
        if let issue = addressIssue(host.address) { return issue }
        if let port = resolved.port, parsePort(port) == nil {
            return "Port \(quoted(port)) isn't a number from 1 to 65535."
        }
        if let issue = userIssue(host.user, fromConfig: resolved.user != nil) { return issue }
        return nil
    }

    /// `%h` → the alias, `%%` → `%`; any other token → `nil` (OpenSSH expands only these two in
    /// `HostName`).
    static func expandHostName(_ hostName: String?, alias: String) -> String? {
        guard let hostName else { return nil }
        guard hostName.contains("%") else { return hostName }
        var result = ""
        var iterator = hostName.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "h": result += alias
            case "%": result += "%"
            default: return nil
            }
        }
        return result
    }

    static func parsePort(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 5, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }

    static func nameIssue(_ alias: String) -> String? {
        if alias.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            return "The name \(quoted(alias)) contains control characters."
        }
        return nil
    }

    /// The host editor's and SSHKit's rule: DNS names, IPv4, IPv6 with an optional `%zone`.
    static func addressIssue(_ address: String) -> String? {
        if address.isEmpty { return "The address is empty." }
        if address.hasPrefix("-") || address.hasPrefix(".") || address.utf8.count > maxAddressLength
            || !address.utf8.allSatisfy({ isAlphanumeric($0) || "._-:%".utf8.contains($0) }) {
            return "The address \(quoted(address)) isn't a plain host name or IP address."
        }
        return nil
    }

    /// The host editor's and SSHKit's rule: letters, digits, `.`, `_`, `-`, `@`; no leading `-`.
    static func userIssue(_ user: String, fromConfig: Bool) -> String? {
        let valid = !user.isEmpty && !user.hasPrefix("-") && user.utf8.count <= maxUserLength
            && user.utf8.allSatisfy { isAlphanumeric($0) || "._-@".utf8.contains($0) }
        if valid { return nil }
        return fromConfig
            ? "The user \(quoted(user)) isn't a plain user name."
            : "The config has no User, and your account name \(quoted(user)) can't be used."
    }

    private static func uniqueName(for alias: String, taken: inout Set<String>) -> String {
        let base = alias.count > maxNameLength ? String(alias.prefix(maxNameLength)) : alias
        var name = base
        var number = 2
        while taken.contains(folded(name)) {
            name = "\(base) \(number)"
            number += 1
        }
        taken.insert(folded(name))
        return name
    }

    private static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }

    /// “value”, with control characters replaced and long values shortened, for messages.
    static func quoted(_ value: String) -> String {
        "“\(displaySafe(value, limit: 60))”"
    }

    /// `value` with control characters shown as U+FFFD and at most `limit` characters (then "…").
    public static func displaySafe(_ value: String, limit: Int = 120) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let unsafe = CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
            scalars.append(unsafe ? "\u{FFFD}" : scalar)
        }
        let safe = String(scalars)
        return safe.count > limit ? String(safe.prefix(limit)) + "…" : safe
    }
}
