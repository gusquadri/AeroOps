import AeroCore
import AeroTheme
import SwiftUI

/// Containers tab. Phase 5 lists Docker containers and Phase 6 Kubernetes pods for the
/// selected host; until then it explains what will appear.
struct ContainersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hosts.isEmpty {
            AeroEmptyState(
                systemImage: "shippingbox",
                title: "Containers and pods",
                message: "Add a host to see its Docker containers and Kubernetes pods here, with status, restarts and age, and logs one click away."
            ) {
                AddHostButton()
            }
        } else if let host = model.selectedHost {
            AeroEmptyState(
                systemImage: "shippingbox",
                title: "Containers on \(host.name)",
                message: "Docker containers and Kubernetes pods on this host will be listed here with live CPU and memory, restart counts and a Logs button."
            ) {
                ComingSoonBadge()
            }
        } else {
            AeroEmptyState(
                systemImage: "sidebar.left",
                title: "Pick a host",
                message: "Choose a host in the sidebar to see its Docker containers and Kubernetes pods."
            )
        }
    }
}

#Preview("Containers · host selected") {
    let model = AppModel.preview()
    model.selection = SampleData.hosts[2].id
    return ContainersView()
        .environment(model)
        .background { SkyBackground() }
        .frame(width: 800, height: 600)
}

#Preview("Containers · no hosts") {
    ContainersView()
        .environment(AppModel.preview(hosts: []))
        .background { SkyBackground() }
        .frame(width: 800, height: 600)
}
