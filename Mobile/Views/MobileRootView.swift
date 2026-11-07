import SwiftUI

/// The tab bar, or ``SplitRootView`` on a regular-width screen, and the host key sheet any
/// screen can ask for.
struct MobileRootView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var navigator = MobileNavigator(section: Self.initialSection)

    private static var initialSection: MobileSection {
        switch MobileDebugOptions.screen {
        case .keys, .newKey, .key: .keys
        default: .servers
        }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if isSplit {
                SplitRootView()
            } else {
                tabs
            }
        }
        .environment(navigator)
        .onChange(of: isSplit, initial: true) { navigator.layoutChanged(isSplit: isSplit) }
        .onChange(of: model.folders.map(\.id)) { _, ids in navigator.closeFolders(notIn: Set(ids)) }
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

    private var isSplit: Bool { sizeClass == .regular }

    private var tabs: some View {
        @Bindable var navigator = navigator
        return TabView(selection: $navigator.section) {
            tab(.servers) { DashboardScreen() }
            tab(.terminals) { TerminalsScreen() }
            tab(.files) { FilesHostsScreen() }
            tab(.containers) { ContainersScreen() }
            tab(.keys) { KeysScreen() }
        }
    }

    private func tab(_ section: MobileSection, @ViewBuilder content: () -> some View) -> some TabContent<MobileSection> {
        Tab(section.title, systemImage: section.systemImage, value: section, content: content)
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
