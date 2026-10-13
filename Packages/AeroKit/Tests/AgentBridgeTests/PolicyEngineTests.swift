import AeroCore
import BridgeProtocol
import Foundation
import Testing
@testable import AgentBridge

@Suite("Policy engine")
struct PolicyEngineTests {
    private let policy = PolicyEngine()

    private func host(_ tier: MCPTier) -> RemoteHost {
        RemoteHost(name: "box-\(tier.rawValue)", address: "10.1.1.1", user: "u", mcpTier: tier)
    }

    @Test(arguments: MCPTier.allCases, BridgeTool.allCases)
    func tierTable(tier: MCPTier, tool: BridgeTool) {
        let decision = policy.evaluate(tool: tool, host: host(tier))
        switch (tier, tool.access) {
        case (.off, _):
            #expect(decision == .reject(BridgeError(code: .hostNotShared, message: "Host \"box-off\" is not shared with agents.")))
        case (.read, .read), (.readExec, .read), (.readExec, .exec):
            #expect(decision == .allow)
        case (.read, .exec):
            guard case .reject(let error) = decision else {
                Issue.record("expected a rejection, got \(decision)")
                return
            }
            #expect(error.code == .execNotAllowed)
            #expect(error.message.contains("read tools only"))
        }
    }

    @Test func offHostsAreNotShared() {
        #expect(policy.evaluate(tool: .runCommand, host: host(.off)) == .reject(PolicyEngine.notShared(host(.off))))
    }
}
