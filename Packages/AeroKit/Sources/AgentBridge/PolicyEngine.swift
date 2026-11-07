import AeroCore
import BridgeProtocol
import Foundation

/// What the policy says about one tool call.
public enum PolicyDecision: Sendable, Hashable {
    /// Run it.
    case allow
    /// Refuse it.
    case reject(BridgeError)
}

/// The per-host MCP tier rules:
///
/// | Tier       | Read tools | `run_command`       |
/// | ---------- | ---------- | ------------------- |
/// | Off        | rejected   | rejected            |
/// | Read       | allowed    | rejected            |
/// | Read+Exec  | allowed    | allowed             |
///
/// AeroOps does not ask the user before `run_command`; the agent is told to ask in its own
/// conversation (``ToolCatalog/serverInstructions``).
///
/// Pure and synchronous; ``Bridge`` calls it for every request, after validation and before
/// any remote work. Tests use it with hosts at the tiers they need.
public struct PolicyEngine: Sendable {
    public init() {}

    /// Decides `tool` on `host`.
    public func evaluate(tool: BridgeTool, host: RemoteHost) -> PolicyDecision {
        switch host.mcpTier {
        case .off:
            return .reject(Self.notShared(host))
        case .read:
            guard tool.access == .read else {
                return .reject(BridgeError(
                    code: .execNotAllowed,
                    message: "Host \"\(host.name)\" allows read tools only; \(tool.rawValue) needs the Read + Exec tier, which only the user can set in AeroOps."))
            }
            return .allow
        case .readExec:
            return .allow
        }
    }

    /// The error for a host whose tier is Off.
    public static func notShared(_ host: RemoteHost) -> BridgeError {
        BridgeError(code: .hostNotShared, message: "Host \"\(host.name)\" is not shared with agents.")
    }
}
