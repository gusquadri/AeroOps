import AeroCore
import AeroTheme
import SwiftUI

/// The Files tab: every server, each opening its file browser where it was left.
struct FilesHostsScreen: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.filePath) {
            content
                .background { SkyBackground() }
                .navigationTitle("Files")
                .navigationDestination(for: RemoteHost.ID.self) { FilesScreen(id: $0) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
            NoServersView()
        } else {
            List(model.hosts) { host in
                NavigationLink(value: host.id) {
                    HostRow(host: host, status: model.displayState(for: host.id).status)
                }
                .listRowBackground(Aero.glass.fill)
            }
            .scrollContentBackground(.hidden)
        }
    }
}
