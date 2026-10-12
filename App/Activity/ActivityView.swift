import AeroTheme
import AgentBridge
import SwiftUI

/// Activity tab (Phases 7 and 8): what AI agents do through AeroOps' MCP bridge.
///
/// Top to bottom: approvals waiting for the user, open 15-minute allow windows, running and
/// recent `run_command` calls with live output (Cancel stops one), the audit log (filterable,
/// newest first) and connection and signing events. Text from agents and hosts is shown as
/// plain text only.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let agents = model.agents
        let isEmpty = agents.pending.isEmpty && agents.windows.isEmpty && agents.liveCommands.isEmpty
            && agents.auditEntries.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ActivityHeader(openMCPSettings: openMCPSettings)
                if !agents.pending.isEmpty {
                    PendingApprovalsSection()
                }
                if !agents.windows.isEmpty {
                    AllowWindowsSection()
                }
                if !agents.liveCommands.isEmpty {
                    CommandsSection()
                }
                if isEmpty {
                    emptyCard
                } else {
                    AuditLogSection()
                }
                ConnectionEventsSection()
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
                Text("When AI agents use AeroOps through MCP, commands waiting for your approval appear at the top and every call, allowed or denied, is logged here. Connect an agent in Settings › MCP.")
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
            Button("Reveal Audit Log", systemImage: "doc.text.magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([agents.auditLogURL])
            }
            .buttonStyle(.aquaSecondary)
            .disabled(!FileManager.default.fileExists(atPath: agents.auditLogURL.path(percentEncoded: false)))
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

// MARK: - Pending approvals

/// Approvals waiting for the user, oldest first, each with its own controls.
private struct PendingApprovalsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        GlassSection("Waiting for your approval", systemImage: "hand.raised") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(agents.pending.enumerated()), id: \.element.id) { index, approval in
                    if index > 0 { Divider() }
                    ApprovalRequestView(
                        approval: approval,
                        position: (index + 1, agents.pending.count),
                        requiresTouchID: agents.requiresTouchID
                    ) { decision in
                        await agents.decide(approval.id, decision)
                    }
                    .id(approval.id)
                }
            }
        } accessory: {
            Button("Show Panel", systemImage: "macwindow.on.rectangle") { agents.showApprovalPanel() }
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
        }
    }
}

// MARK: - Allow windows

/// Hosts whose commands currently run without asking (sudo and similar still ask).
private struct AllowWindowsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        GlassSection("Hosts allowed without asking", systemImage: "clock.badge.checkmark") {
            AllowWindowList(windows: agents.windows) { hostID in
                Task { await agents.revokeWindow(for: hostID) }
            }
        } accessory: {
            if agents.windows.count > 1 {
                Button("Revoke All", role: .destructive) { Task { await agents.revokeAllWindows() } }
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
            }
        }
    }
}

/// Allow windows with the time left and a Revoke button. Shared with Settings › MCP.
struct AllowWindowList: View {
    let windows: [AllowWindow]
    let onRevoke: (UUID) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(windows, id: \.hostID) { window in
                    HStack(spacing: 10) {
                        StatusOrb(tone: .warning, size: 10)
                        Text(verbatim: window.hostName)
                            .font(Aero.font(.callout, weight: .semibold))
                            .foregroundStyle(Aero.text.primary)
                        Text(Self.remaining(until: window.expiresAt, now: context.date))
                            .font(Aero.font(.callout))
                            .monospacedDigit()
                            .foregroundStyle(Aero.text.secondary)
                        Spacer()
                        Button("Revoke", role: .destructive) { onRevoke(window.hostID) }
                            .buttonStyle(.aquaSecondary)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    static func remaining(until expiry: Date, now: Date) -> String {
        let seconds = max(Int(expiry.timeIntervalSince(now).rounded(.up)), 0)
        return "until \(expiry.formatted(date: .omitted, time: .shortened)) · \(seconds / 60):\(String(format: "%02d", seconds % 60)) left"
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
