import Foundation

/// A server the app monitors, as stored in `hosts.json`.
///
/// Decoding is tolerant: unknown keys are ignored, and every field except `id`, `name`,
/// `address` and `user` falls back to its default when missing, so older or hand-edited files
/// still load. Secrets never live here; `keyId` only names a key held by KeyAgent.
///
/// Named `RemoteHost` (the plan says "Host") because `Foundation.Host` (NSHost) makes a bare
/// `Host` ambiguous in every file that imports both Foundation/SwiftUI and AeroCore.
public struct RemoteHost: Identifiable, Codable, Sendable, Hashable {
    /// Stable identity; also used in the generated ssh_config alias `aero-<id>`.
    public var id: UUID
    /// Display name shown on cards and in the sidebar.
    public var name: String
    /// DNS name or IP address passed to ssh as `HostName`.
    public var address: String
    /// SSH port. Defaults to 22.
    public var port: Int
    /// Remote login user.
    public var user: String
    /// Identifier of the KeyAgent key used for this host, or `nil` for none chosen yet.
    public var keyId: String?
    /// Free-form tags for grouping and filtering (`list_hosts tag:`).
    public var tags: [String]
    /// Command prefix replacing `kubectl`, e.g. `sudo -n k3s kubectl`. `nil` means plain `kubectl`.
    public var kubectlPrefix: String?
    /// Run docker commands as `sudo -n docker`.
    public var dockerSudo: Bool
    /// What AI agents may do on this host through MCP. Defaults to ``MCPTier/read``.
    public var mcpTier: MCPTier

    /// The default SSH port.
    public static let defaultPort = 22

    /// Creates a host. Only `name`, `address` and `user` are required.
    public init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: Int = RemoteHost.defaultPort,
        user: String,
        keyId: String? = nil,
        tags: [String] = [],
        kubectlPrefix: String? = nil,
        dockerSudo: Bool = false,
        mcpTier: MCPTier = .default
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.keyId = keyId
        self.tags = tags
        self.kubectlPrefix = kubectlPrefix
        self.dockerSudo = dockerSudo
        self.mcpTier = mcpTier
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, user, keyId, tags, kubectlPrefix, dockerSudo, mcpTier
    }

    /// Tolerant decoding: required `id`, `name`, `address`, `user`; everything else defaulted.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        user = try c.decode(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? RemoteHost.defaultPort
        keyId = try c.decodeIfPresent(String.self, forKey: .keyId)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        kubectlPrefix = try c.decodeIfPresent(String.self, forKey: .kubectlPrefix)
        dockerSudo = try c.decodeIfPresent(Bool.self, forKey: .dockerSudo) ?? false
        mcpTier = try c.decodeIfPresent(MCPTier.self, forKey: .mcpTier) ?? .default
    }
}

/// Per-host MCP access tier.
public enum MCPTier: String, Codable, Sendable, Hashable, CaseIterable {
    /// No MCP tools; calls fail with "host not shared with agents".
    case off
    /// Read tools only: hosts, metrics, containers, pods, logs.
    case read
    /// Read tools plus `run_command`, each call approved by the user.
    case readExec

    /// The tier given to new hosts.
    public static let `default`: MCPTier = .read

    /// Decodes a raw value; an unrecognised value (e.g. a tier from a newer app version or a
    /// typo) fails closed to ``off`` rather than granting access.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MCPTier(rawValue: raw) ?? .off
    }
}
