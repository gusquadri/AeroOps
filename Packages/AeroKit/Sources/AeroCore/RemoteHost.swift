import Foundation

/// A server the app monitors, as stored by ``HostStore``.
///
/// Decoding is tolerant: unknown keys are ignored, and every field except `id`, `name`,
/// `address` and `user` falls back to its default when missing, so records from older or newer
/// versions still load. Secrets never live here: `keyId` only names a key held by KeyAgent, and a
/// password host's password lives in the Keychain under the host's `id`.
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
    /// Ignored while ``auth`` is ``HostAuthMethod/password``, but kept for switching back.
    public var keyId: String?
    /// How ssh logs in. Defaults to ``HostAuthMethod/key``.
    public var auth: HostAuthMethod
    /// Free-form tags for grouping and filtering (`list_hosts tag:`).
    public var tags: [String]
    /// Command prefix replacing `kubectl`, e.g. `sudo -n k3s kubectl`. `nil` means plain `kubectl`.
    public var kubectlPrefix: String?
    /// Run docker commands as `sudo -n docker`.
    public var dockerSudo: Bool
    /// What AI agents may do on this host through MCP. Defaults to ``MCPTier/read``. Each device
    /// keeps its own: ``HostStore`` never syncs it.
    public var mcpTier: MCPTier
    /// Poll the host's metrics for its card. `false` keeps the host for terminals, files and
    /// containers without polling it. Defaults to `true`.
    public var monitored: Bool

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
        auth: HostAuthMethod = .key,
        tags: [String] = [],
        kubectlPrefix: String? = nil,
        dockerSudo: Bool = false,
        mcpTier: MCPTier = .default,
        monitored: Bool = true
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.keyId = keyId
        self.auth = auth
        self.tags = tags
        self.kubectlPrefix = kubectlPrefix
        self.dockerSudo = dockerSudo
        self.mcpTier = mcpTier
        self.monitored = monitored
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, user, keyId, auth, tags, kubectlPrefix, dockerSudo, mcpTier, monitored
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
        auth = try c.decodeIfPresent(HostAuthMethod.self, forKey: .auth) ?? .key
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        kubectlPrefix = try c.decodeIfPresent(String.self, forKey: .kubectlPrefix)
        dockerSudo = try c.decodeIfPresent(Bool.self, forKey: .dockerSudo) ?? false
        mcpTier = try c.decodeIfPresent(MCPTier.self, forKey: .mcpTier) ?? .default
        monitored = try c.decodeIfPresent(Bool.self, forKey: .monitored) ?? true
    }
}

/// How ssh logs in to a host.
public enum HostAuthMethod: String, Codable, Sendable, Hashable, CaseIterable {
    /// Public key: the host's KeyAgent key through the in-app agent, or the system agent's keys.
    case key
    /// A password kept in the Keychain, handed to ssh by the `aeroops-askpass` helper.
    case password

    /// Decodes a raw value; an unrecognised value falls back to ``key``, which never sends a
    /// password anywhere.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HostAuthMethod(rawValue: raw) ?? .key
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
