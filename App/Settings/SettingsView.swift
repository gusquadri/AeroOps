import AeroTheme
import SwiftUI

/// The Settings window (⌘,): Hosts, Keys, MCP, Appearance and Updates. The selected pane lives in
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
                KeysSettingsPane()
            }
            Tab(SettingsPane.mcp.title, systemImage: SettingsPane.mcp.systemImage, value: .mcp) {
                MCPSettingsPane()
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
            Tab(SettingsPane.updates.title, systemImage: SettingsPane.updates.systemImage, value: .updates) {
                UpdatesSettingsPane()
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
