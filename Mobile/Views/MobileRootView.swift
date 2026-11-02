import SwiftUI

/// The app's tabs, and the host key sheet any of them can ask for.
struct MobileRootView: View {
    @Environment(MobileModel.self) private var model
    @State private var navigator = MobileNavigator(section: Self.initialSection)

    private static var initialSection: MobileSection {
        switch MobileDebugOptions.screen {
        case .keys, .newKey, .key: .keys
        default: .servers
        }
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var navigator = navigator
        TabView(selection: $navigator.section) {
            Tab("Servers", systemImage: "server.rack", value: .servers) { DashboardScreen() }
            Tab("Terminals", systemImage: "terminal", value: .terminals) { TerminalsScreen() }
            Tab("Files", systemImage: "folder", value: .files) { FilesHostsScreen() }
            Tab("Containers", systemImage: "shippingbox", value: .containers) { ContainersScreen() }
            Tab("Keys", systemImage: "key.horizontal", value: .keys) { KeysScreen() }
        }
        .environment(navigator)
        .task(openDebugScreen)
        .sheet(item: $model.trustRequest) { request in
            NavigationStack {
                HostKeyTrustSheet(
                    host: request.host,
                    offered: request.offered,
                    onTrust: { try await model.trust(request) },
                    onCancel: { model.trustRequest = nil }
                )
            }
            .presentationDetents([.large])
        }
    }

    private func openDebugScreen() {
        guard let first = model.hosts.first else { return }
        switch MobileDebugOptions.screen {
        case .terminal: navigator.show(terminal: model.currentTerminal(on: first.id).id)
        case .files: navigator.showFiles(of: first.id)
        default: break
        }
    }
}

#Preview {
    MobileRootView()
        .environment(MobileModel.preview())
}
