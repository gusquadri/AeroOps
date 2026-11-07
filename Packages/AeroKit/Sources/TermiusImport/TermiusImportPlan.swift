import AeroCore
import Foundation

/// One Termius host, ready to show in the import sheet.
public struct TermiusImportCandidate: Identifiable, Sendable, Hashable {
    /// The host as AeroOps would add it, with the same status rules as an ssh_config import.
    /// ``SSHConfigImportCandidate/alias`` is the Termius label, made unique within the import.
    public var candidate: SSHConfigImportCandidate
    /// The Termius host's local id.
    public var termiusID: Int64
    /// Termius's group path, top-level first.
    public var groups: [String]
    /// The Termius key to import and attach, if the host logs in with one.
    public var keyID: TermiusKey.ID?
    /// The password to save in the Keychain, if the host logs in with one and no key.
    public var password: TermiusSecret?
    /// Short remarks for the row: what is imported along with the host.
    public var notes: [String]

    public var id: String { candidate.id }
}

/// Turns ``TermiusData`` into ``TermiusImportCandidate``s.
///
/// Each host goes through ``SSHConfigImport/candidates(from:existingHosts:localUser:makeID:)``,
/// so addresses, users and ports are checked, names kept unique and duplicates of inventory
/// hosts found exactly as for `~/.ssh/config`. On top of that:
/// - Termius groups and tags become tags (`Group/Subgroup`, then each tag), cleaned up to the
///   host editor's tag rules.
/// - A host with a key logs in with it (the key is imported into the in-app agent on import);
///   otherwise one with a password saves it to the Keychain; otherwise it uses the agent's keys.
/// - Telnet hosts, host chains, proxies and hardware keys are unsupported.
public enum TermiusImport {
    public static func candidates(
        from data: TermiusData,
        existingHosts: [RemoteHost],
        localUser: String,
        makeID: () -> UUID = UUID.init
    ) -> [TermiusImportCandidate] {
        var aliases = Set<String>()
        let configHosts = data.hosts.map { configHost($0, aliases: &aliases) }
        let planned = SSHConfigImport.candidates(from: configHosts, existingHosts: existingHosts, localUser: localUser, makeID: makeID)
        return zip(data.hosts, planned).map { candidate(for: $0, planned: $1, keys: data.keys) }
    }

    /// The host as an ssh_config entry. Its `%` are doubled, since the planner expands `%` tokens
    /// as ssh_config does and Termius addresses are literal. An unsupported host gets a stand-in
    /// proxy, so the planner marks it unsupported before giving it a name;
    /// ``candidate(for:planned:keys:)`` then puts in the real reason.
    private static func configHost(_ host: TermiusHost, aliases: inout Set<String>) -> SSHConfigHost {
        SSHConfigHost(
            alias: uniqueAlias(SSHConfigImport.displaySafe(host.displayName, limit: 60), taken: &aliases),
            hostName: host.address.replacingOccurrences(of: "%", with: "%%"),
            user: host.username,
            port: host.port.map(String.init),
            proxy: host.unsupported.map { _ in .command("termius") }
        )
    }

    private static func candidate(
        for host: TermiusHost, planned: SSHConfigImportCandidate, keys: [TermiusKey.ID: TermiusKey]
    ) -> TermiusImportCandidate {
        var candidate = planned
        if let unsupported = host.unsupported {
            candidate.status = .unsupported(reason: reason(unsupported))
        }
        candidate.host.tags = tags(groups: host.groups, tags: host.tags)
        let key = host.keyID.flatMap { keys[$0] }
        let login = login(key: key, password: host.password)
        candidate.host.auth = login.auth
        return TermiusImportCandidate(
            candidate: candidate,
            termiusID: host.id,
            groups: host.groups,
            keyID: key?.id,
            password: login.password,
            notes: login.notes
        )
    }

    /// The key if there is one, else the password, else the agent's keys.
    private static func login(
        key: TermiusKey?, password: TermiusSecret?
    ) -> (auth: HostAuthMethod, password: TermiusSecret?, notes: [String]) {
        if let key {
            let label = key.label.isEmpty ? "unnamed" : SSHConfigImport.displaySafe(key.label, limit: 40)
            let notes = ["Key “\(label)” is imported into AeroOps’s agent."]
            return (.key, nil, password == nil ? notes : notes + ["Termius also saved a password; AeroOps uses the key."])
        }
        if password != nil { return (.password, password, ["The password is saved to your Keychain."]) }
        return (.key, nil, [])
    }

    static func reason(_ unsupported: TermiusHost.Unsupported) -> String {
        switch unsupported {
        case .telnet: "A Telnet host. AeroOps connects over SSH only."
        case .hostChain: "Connects through a host chain. AeroOps can't use jump hosts yet."
        case .proxy: "Connects through a proxy. AeroOps can't use proxies yet."
        case .hardwareKey: "Logs in with a hardware key, which can't be exported from Termius."
        }
    }

    /// The group path, then each tag, cleaned to the host editor's rules (letters, digits and
    /// `-_.:/`, at most 32 characters), without duplicates.
    static func tags(groups: [String], tags: [String]) -> [String] {
        let groupTag = groups.map { $0.replacingOccurrences(of: "/", with: "-") }.joined(separator: "/")
        var seen = Set<String>()
        var result: [String] = []
        for raw in [groupTag] + tags {
            guard let tag = cleanTag(raw), seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    private static let tagCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/"))

    static func cleanTag(_ raw: String) -> String? {
        let tag = String(dashJoined(raw).prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        return tag.isEmpty ? nil : tag
    }

    /// The tag characters of `text`, with whitespace between them turned into one dash.
    private static func dashJoined(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingDash = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingDash = true
            } else if tagCharacters.contains(scalar) {
                if pendingDash, !scalars.isEmpty { scalars.append("-") }
                pendingDash = false
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// `alias`, or `alias 2`, `alias 3`, … when another Termius host already has it (ignoring case).
    private static func uniqueAlias(_ alias: String, taken: inout Set<String>) -> String {
        var name = alias
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(alias) \(number)"
            number += 1
        }
        taken.insert(name.lowercased())
        return name
    }
}
