import AeroTheme
import SwiftUI

/// Activity tab. Phase 7 shows the MCP audit log here; Phase 8 adds pending approvals on top.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        AeroEmptyState(
            systemImage: "list.bullet.rectangle",
            title: "No agent activity yet",
            message: "When AI agents use AeroOps through MCP, commands waiting for your approval appear at the top and every call, allowed or denied, is logged below."
        ) {
            Button("MCP Settings…", systemImage: "point.3.connected.trianglepath.dotted") {
                model.settingsPane = .mcp
                openSettings()
            }
            .buttonStyle(.aqua)
        }
    }
}

#Preview("Activity") {
    ActivityView()
        .environment(AppModel.preview())
        .background { SkyBackground() }
        .frame(width: 800, height: 600)
}
