import AeroCore
import AeroTheme
import SwiftUI

/// Terminals tab. Phase 4 shows one libghostty tab per SSH session here.
struct TerminalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AeroEmptyState(
            systemImage: "terminal",
            title: "No terminal tabs",
            message: "Open SSH from a host card or the sidebar to start a terminal tab here. Each tab runs OpenSSH against the host, signed by AeroOps’ own key agent."
        ) {
            if model.hosts.isEmpty {
                AddHostButton()
            } else if let host = model.selectedHost {
                Button("Open SSH to \(host.name)", systemImage: "terminal") { model.openSSH(host.id) }
                    .buttonStyle(.aqua)
                    .disabled(!model.canOpenSSH(host.id))
                    .help("Terminal tabs are coming in a later version")
            } else {
                ComingSoonBadge()
            }
        }
    }
}

#Preview("Terminals") {
    TerminalsView()
        .environment(AppModel.preview())
        .background { SkyBackground() }
        .frame(width: 800, height: 600)
}
