import AeroCore
import BridgeProtocol
import Foundation

/// What the policy says about one tool call.
public enum PolicyDecision: Sendable, Hashable {
    /// Run it (read tools on Read and Read+Exec hosts). The call is still audited.
    case allow
    /// Refuse without asking the user.
    case reject(BridgeError)
    /// Ask the user through ``ApprovalCenter``. With `alwaysAsk` reasons, an allow window does
    /// not apply.
    case requireApproval(alwaysAsk: [AlwaysAskReason])
}

/// The per-host MCP tier rules:
///
/// | Tier       | Read tools | `run_command`                              |
/// | ---------- | ---------- | ------------------------------------------ |
/// | Off        | rejected   | rejected                                   |
/// | Read       | allowed    | rejected, no prompt                        |
/// | Read+Exec  | allowed    | approval; `sudo` & co. always ask          |
///
/// Pure and synchronous; ``Bridge`` calls it for every request, after validation and before
/// any approval or remote work. Tests use it with hosts at the tiers they need.
public struct PolicyEngine: Sendable {
    public init() {}

    /// Decides `tool` on `host`. `command` is the `run_command` command, if any.
    public func evaluate(tool: BridgeTool, host: RemoteHost, command: String? = nil) -> PolicyDecision {
        switch host.mcpTier {
        case .off:
            return .reject(Self.notShared(host))
        case .read:
            guard tool.access == .read else {
                return .reject(BridgeError(
                    code: .execNotAllowed,
                    message: "Host \"\(host.name)\" allows read tools only; run_command needs the Read + Exec tier, which only the user can set in AeroOps."))
            }
            return .allow
        case .readExec:
            guard tool.access == .exec else { return .allow }
            return .requireApproval(alwaysAsk: CommandInspector.alwaysAskReasons(for: command ?? ""))
        }
    }

    /// The error for a host whose tier is Off.
    public static func notShared(_ host: RemoteHost) -> BridgeError {
        BridgeError(code: .hostNotShared, message: "Host \"\(host.name)\" is not shared with agents.")
    }
}
