import AeroCore
import AeroTheme
import SwiftUI

/// The Files tab: every server matching the search field, each opening its file browser where it was left.
struct FilesHostsScreen: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    @State private var search = ""

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.filePath) {
            content
                .background { SkyBackground() }
                .searchable(text: $search, prompt: "Name or address")
                .navigationTitle("Files")
                .navigationDestination(for: RemoteHost.ID.self) { FilesScreen(id: $0) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
            NoServersView()
        } else {
            let hosts = model.hosts.matching(search: search)
            List(hosts) { host in
                NavigationLink(value: host.id) {
                    HostRow(host: host, status: model.displayState(for: host.id).status)
                }
                .listRowBackground(Aero.glass.fill)
            }
            .scrollContentBackground(.hidden)
            .overlay { if hosts.isEmpty { NoMatchingHostsView(search: search).padding(16) } }
        }
    }
}
