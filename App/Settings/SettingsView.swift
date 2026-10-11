import AeroTheme
import SwiftUI

/// The Settings window (⌘,): Hosts, Keys, MCP and Appearance. The selected pane lives in
/// ``AppModel/settingsPane`` so other screens can deep-link to a pane.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsPane) {
            Tab(SettingsPane.hosts.title, systemImage: SettingsPane.hosts.systemImage, value: .hosts) {
                HostsSettingsPane()
            }
            Tab(SettingsPane.keys.title, systemImage: SettingsPane.keys.systemImage, value: .keys) {
                SettingsPlaceholderPane(
                    systemImage: "key.horizontal",
                    title: "SSH keys",
                    message: "Generate Ed25519 or Secure Enclave keys, or import existing OpenSSH keys. Private keys stay in the Keychain and are served only by AeroOps’ own ssh-agent.",
                    plans: [
                        "Generate, import, export and delete keys",
                        "Touch ID policy per key",
                        "Copy a key’s authorized_keys line",
                    ]
                )
            }
            Tab(SettingsPane.mcp.title, systemImage: SettingsPane.mcp.systemImage, value: .mcp) {
                SettingsPlaceholderPane(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: "AI agents (MCP)",
                    message: "Let Claude Code, Codex and other MCP clients read your servers through AeroOps. Agents never see your keys, and commands always wait for your approval.",
                    plans: [
                        "Access per host: Off, Read, or Read + Exec",
                        "Copy-config buttons for Claude Code, Codex and JSON clients",
                        "Approval and audit settings",
                    ]
                )
            }
            Tab(SettingsPane.appearance.title, systemImage: SettingsPane.appearance.systemImage, value: .appearance) {
                SettingsPlaceholderPane(
                    systemImage: "paintpalette",
                    title: "Appearance",
                    message: "AeroOps uses the Frutiger Aero theme. Reduce Transparency in System Settings › Accessibility switches cards to solid fills.",
                    plans: [
                        "“Aero Night” dark variant",
                        "Dashboard density and pinned disk per host",
                    ]
                )
            }
        }
        .frame(width: 780, height: 600)
    }
}

/// A Settings pane that is not built yet: what it will do, over the sky background.
struct SettingsPlaceholderPane: View {
    let systemImage: String
    let title: String
    let message: String
    let plans: [String]

    var body: some View {
        AeroEmptyState(systemImage: systemImage, title: title, message: message) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plans, id: \.self) { plan in
                    Label {
                        Text(plan).foregroundStyle(Aero.text.primary)
                    } icon: {
                        Image(systemName: "sparkle").foregroundStyle(Aero.aqua)
                    }
                    .font(Aero.font(.callout))
                }
            }
            ComingSoonBadge()
                .padding(.top, 6)
        }
        .background { SkyBackground() }
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(AppModel.preview())
}
