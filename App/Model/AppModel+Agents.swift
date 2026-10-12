import Foundation

/// Phases 7 and 8: AI agents over MCP. ``AppModel/agents`` (``BridgeService``) runs the bridge
/// on `~/.aeroops/bridge.sock`; the read tools answer from the model's hosts and live state.
extension AppModel {
    /// Gives ``agents`` the hosts and live state the read tools report. Called once from `init`.
    func bindAgents() {
        agents.bind(model: self)
    }
}
