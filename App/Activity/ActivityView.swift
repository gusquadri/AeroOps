import AeroTheme
import AgentBridge
import SwiftUI

/// Activity tab (Phases 7 and 8): what AI agents do through AeroOps' MCP bridge.
///
/// Running and recent `run_command` calls with live output (Cancel stops one). AeroOps does not
/// ask before a command runs; agents are told to ask the user in their own conversation. Text
/// from agents and hosts is shown as plain text only.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let agents = model.agents
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ActivityHeader(openMCPSettings: openMCPSettings)
                if agents.liveCommands.isEmpty {
                    emptyCard
                } else {
                    CommandsSection()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyCard: some View {
        AeroCard(padding: 24) {
            VStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(Aero.font(size: 40, weight: .light))
                    .foregroundStyle(Aero.aqua)
                    .accessibilityHidden(true)
                Text("No agent activity yet")
                    .font(Aero.font(.title3, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                Text("When AI agents run commands through AeroOps' MCP server, they appear here with their live output, and you can cancel them. Agents are told to ask you in the conversation before each command. Connect an agent in Settings › MCP.")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                Button("MCP Settings…", systemImage: "point.3.connected.trianglepath.dotted", action: openMCPSettings)
                    .buttonStyle(.aqua)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func openMCPSettings() {
        model.settingsPane = .mcp
        openSettings()
    }
}

// MARK: - Header

/// Bridge status, connected agents and the way to MCP settings.
private struct ActivityHeader: View {
    @Environment(AppModel.self) private var model
    let openMCPSettings: () -> Void

    var body: some View {
        let agents = model.agents
        HStack(spacing: 10) {
            StatusOrb(tone: agents.status.tone, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(agents.status.title)
                    .font(Aero.font(.headline, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                Text(agents.peersSummary)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
            }
            Spacer(minLength: 12)
            Button("MCP Settings…", systemImage: "point.3.connected.trianglepath.dotted", action: openMCPSettings)
                .buttonStyle(.aquaSecondary)
        }
    }
}

extension BridgeService.Status {
    var tone: OrbTone {
        switch self {
        case .listening: .healthy
        case .stopped: .neutral
        case .failed: .error
        }
    }

    var title: String {
        switch self {
        case .listening: "MCP bridge listening"
        case .stopped: "MCP bridge stopped"
        case .failed(let reason): "MCP bridge not running: \(reason)"
        }
    }
}

extension BridgeService {
    /// "No agent connected", "1 agent connected", …
    var peersSummary: String {
        switch peers.count {
        case 0: "No agent connected"
        case 1: "1 agent connected"
        default: "\(peers.count) agents connected"
        }
    }
}

#Preview("Activity") {
    let model = AppModel.preview()
    ActivityView()
        .environment(model)
        .background { SkyBackground() }
        .frame(width: 1000, height: 800)
        .task { model.agents.applySampleState(hosts: model.hosts) }
}
