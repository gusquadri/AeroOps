import AeroCore
import Collectors
import Foundation

/// The editable form of a ``RemoteHost`` used by the host editor, with validation.
///
/// Port and tags are kept as typed text so invalid input can be shown and fixed rather than
/// silently coerced. ``validate(otherHostNames:)`` and ``makeHost()`` are pure.
///
/// Validation is also a safety boundary: address, user and kubectl prefix end up in the generated
/// ssh_config and in remote command lines, so line breaks, spaces and a leading "-" (which ssh
/// would read as an option) are rejected here. SSHKit still validates its own inputs.
struct HostDraft: Hashable, Sendable {
    var id: RemoteHost.ID
    var name: String
    var address: String
    var port: String
    var user: String
    var keyId: String?
    /// Comma-separated, e.g. "prod, web, eu-west".
    var tags: String
    /// Empty means plain `kubectl`.
    var kubectlPrefix: String
    var dockerSudo: Bool
    var mcpTier: MCPTier

    /// A blank draft for a new host: port 22, default MCP tier.
    init(id: RemoteHost.ID = UUID()) {
        self.id = id
        name = ""
        address = ""
        port = String(RemoteHost.defaultPort)
        user = ""
        keyId = nil
        tags = ""
        kubectlPrefix = ""
        dockerSudo = false
        mcpTier = .default
    }

    /// A draft that edits `host`.
    init(host: RemoteHost) {
        id = host.id
        name = host.name
        address = host.address
        port = String(host.port)
        user = host.user
        keyId = host.keyId
        tags = host.tags.joined(separator: ", ")
        kubectlPrefix = host.kubectlPrefix ?? ""
        dockerSudo = host.dockerSudo
        mcpTier = host.mcpTier
    }

    // MARK: - Limits

    static let maxNameLength = 64
    static let maxAddressLength = 253
    static let maxUserLength = 64
    static let maxTagLength = 32

    // MARK: - Parsed values

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedKubectlPrefix: String { kubectlPrefix.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The port as a number, if it is one in `1...65535`.
    var parsedPort: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }

    /// Tags split on commas, trimmed, empty entries dropped, de-duplicated case-insensitively
    /// (first spelling wins), in input order.
    var parsedTags: [String] {
        var seen = Set<String>()
        return tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The host this draft describes, normalised (trimmed text, parsed tags, empty prefix → `nil`,
    /// prefix words joined by single spaces). Check ``validate(otherHostNames:)`` first; an
    /// unparsable port falls back to 22.
    func makeHost() -> RemoteHost {
        let trimmed = trimmedKubectlPrefix
        let prefix = trimmed.isEmpty ? "" : (try? KubectlPrefix.normalized(trimmed)) ?? trimmed
        return RemoteHost(
            id: id,
            name: trimmedName,
            address: trimmedAddress,
            port: parsedPort ?? RemoteHost.defaultPort,
            user: trimmedUser,
            keyId: keyId,
            tags: parsedTags,
            kubectlPrefix: prefix.isEmpty ? nil : prefix,
            dockerSudo: dockerSudo,
            mcpTier: mcpTier
        )
    }

    // MARK: - Validation

    /// Fields that can carry a validation message.
    enum Field: Hashable, CaseIterable, Sendable {
        case name, address, port, user, tags, kubectlPrefix
    }

    /// Validation messages by field.
    struct Validation: Hashable, Sendable {
        var issues: [Field: String] = [:]

        var isValid: Bool { issues.isEmpty }

        func message(for field: Field) -> String? { issues[field] }

        /// Address, port and user are valid, so a connection test makes sense.
        var canTestConnection: Bool {
            issues[.address] == nil && issues[.port] == nil && issues[.user] == nil
        }
    }

    /// The draft's current text for `field`, for "has this field been edited" checks.
    func text(for field: Field) -> String {
        switch field {
        case .name: name
        case .address: address
        case .port: port
        case .user: user
        case .tags: tags
        case .kubectlPrefix: kubectlPrefix
        }
    }

    /// Validates every field. `otherHostNames` are the names of the *other* hosts; names must be
    /// unique ignoring case.
    func validate(otherHostNames: some Sequence<String>) -> Validation {
        var v = Validation()
        v.issues[.name] = Self.nameIssue(trimmedName, otherHostNames: otherHostNames)
        v.issues[.address] = Self.addressIssue(trimmedAddress)
        v.issues[.port] = parsedPort == nil ? "Enter a port from 1 to 65535." : nil
        v.issues[.user] = Self.userIssue(trimmedUser)
        v.issues[.tags] = Self.tagsIssue(parsedTags)
        v.issues[.kubectlPrefix] = Self.kubectlPrefixIssue(trimmedKubectlPrefix)
        return v
    }

    private static let addressCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
    /// The same set SSHKit's config writer accepts (no `$`: ssh_config would expand it).
    private static let userCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")
    private static let tagCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/"))

    private static func only(_ text: String, in allowed: CharacterSet) -> Bool {
        text.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: CharacterSet.controlCharacters.union(.newlines).contains)
    }

    static func nameIssue(_ name: String, otherHostNames: some Sequence<String>) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name.count > maxNameLength { return "Use \(maxNameLength) characters or fewer." }
        if hasControlCharacters(name) { return "Names can't contain line breaks or control characters." }
        let folded = name.lowercased()
        if otherHostNames.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == folded }) {
            return "Another host is already called “\(name)”."
        }
        return nil
    }

    static func addressIssue(_ address: String) -> String? {
        if address.isEmpty { return "Enter a host name or IP address." }
        if address.hasPrefix("-") { return "An address can't start with “-”." }
        if address.hasPrefix(".") { return "An address can't start with “.”." }
        if address.count > maxAddressLength { return "Use \(maxAddressLength) characters or fewer." }
        if !only(address, in: addressCharacters) {
            return "Use a host name or IP address: letters, digits, “.”, “-”, “_”, “:” or “%”, no spaces."
        }
        return nil
    }

    static func userIssue(_ user: String) -> String? {
        if user.isEmpty { return "Enter the SSH login user." }
        if user.hasPrefix("-") { return "A user name can't start with “-”." }
        if user.count > maxUserLength { return "Use \(maxUserLength) characters or fewer." }
        if !only(user, in: userCharacters) {
            return "Use letters, digits, “.”, “_”, “-” or “@”, no spaces."
        }
        return nil
    }

    static func tagsIssue(_ tags: [String]) -> String? {
        for tag in tags {
            if tag.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
                return "“\(tag)” contains a space. Separate tags with commas."
            }
            if tag.count > maxTagLength { return "Keep each tag to \(maxTagLength) characters or fewer." }
            if !only(tag, in: tagCharacters) {
                return "Tags use letters, digits, “-”, “_”, “.”, “:” or “/”."
            }
        }
        return nil
    }

    /// The collectors' rule (``KubectlPrefix``): plain words such as `sudo -n k3s kubectl`, with
    /// no quotes, `$`, `;`, pipes or redirections, because the prefix is inserted unquoted at the
    /// head of every kubectl command line.
    static func kubectlPrefixIssue(_ prefix: String) -> String? {
        if prefix.isEmpty { return nil }
        do {
            _ = try KubectlPrefix.normalized(prefix)
            return nil
        } catch {
            if case .invalidKubectlPrefix(_, let reason) = error {
                return "Not usable: \(reason) Use plain words, e.g. “sudo -n k3s kubectl”."
            }
            return error.localizedDescription
        }
    }
}
