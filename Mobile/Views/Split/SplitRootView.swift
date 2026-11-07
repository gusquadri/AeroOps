import AeroCore
import AeroTheme
import SwiftUI

/// The regular-width layout (an unfolded iPhone Duo, a Pro Max in landscape), like the Mac app's
/// window: servers and their terminals in a sidebar, the selected server's tab beside it, and Keys
/// as a sheet. Its state lives in ``MobileNavigator``, shared with the tab layout.
struct SplitRootView: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SplitSidebar()
        } detail: {
            SplitDetail()
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .leading) {
            if columnVisibility == .all {
                SidebarResizeHandle()
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $navigator.isShowingKeys) {
            KeysScreen(onDone: { navigator.isShowingKeys = false })
        }
        .onAppear(perform: syncSelection)
        .onChange(of: hostInSection) { syncSelection() }
        .onChange(of: model.hosts.map(\.id)) { prune() }
        .onChange(of: model.terminals.map(\.id)) { prune() }
    }

    /// The server the current tab's stack shows.
    private var hostInSection: RemoteHost.ID? {
        switch navigator.section {
        case .servers: navigator.serverPath.last?.hostID
        case .files: navigator.filePath.first
        case .containers: navigator.containerPath.first?.hostID
        case .terminals: navigator.terminalPath.last.flatMap { model.terminal(id: $0)?.hostID }
        case .keys: nil
        }
    }

    /// Selects the server the tab shows, or the first server when nothing is selected yet.
    private func syncSelection() {
        if let id = hostInSection {
            navigator.selectedHost = id
        } else if navigator.selectedHost == nil, let first = model.hosts.first {
            navigator.selectedHost = first.id
            navigator.open(navigator.section, terminal: model.terminal(toShowOn: first.id, current: nil))
        }
    }

    private func prune() {
        navigator.prune(hosts: Set(model.hosts.map(\.id)), terminals: Set(model.terminals.map(\.id)))
        syncSelection()
    }
}

/// The selected tab, with every tab opened so far kept alive under it. A hidden tab gets
/// `isTabShown` false.
private struct SplitDetail: View {
    @Environment(MobileNavigator.self) private var navigator
    @State private var opened: Set<MobileSection> = []

    var body: some View {
        let shown = navigator.switcherSection
        ZStack {
            ForEach(MobileSection.switcherTabs.filter { opened.contains($0) || $0 == shown }) { section in
                let isShown = section == shown
                tab(section)
                    .opacity(isShown ? 1 : 0)
                    .allowsHitTesting(isShown)
                    .accessibilityHidden(!isShown)
                    .environment(\.isTabShown, isShown)
            }
        }
        .onChange(of: shown, initial: true) { opened.insert(shown) }
    }

    @ViewBuilder
    private func tab(_ section: MobileSection) -> some View {
        switch section {
        case .servers, .keys: SplitServers()
        case .containers: SplitContainers()
        case .terminals: SplitTerminal()
        case .files: SplitFiles()
        }
    }
}

/// Every server's card, or in their place the picked server's details or folder (the Servers
/// stack's last screen); Back returns to the screen before.
private struct SplitServers: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NavigationStack {
            switch navigator.serverPath.last {
            case .host(let id):
                HostScreen(id: id)
                    .id(id)
                    .sectionSwitcher(back: { navigator.serverPath.removeLast() })
            case .folder(let id):
                FolderScreen(id: id, onSelect: { navigator.push(host: $0) })
                    .id(id)
                    .sectionSwitcher(back: { navigator.serverPath.removeLast() })
            case nil:
                DashboardContent(onOpen: open, showsAppItems: false)
                    .sectionSwitcher()
            }
        }
    }

    private func open(_ route: ServerRoute) {
        switch route {
        case .host(let id): navigator.select(host: id, terminal: nil)
        case .folder: navigator.serverPath = [route]
        }
    }
}

/// The selected server's containers and pods, with their screens pushed over them while the
/// tab is shown.
private struct SplitContainers: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.isTabShown) private var isTabShown

    var body: some View {
        let id = navigator.containerPath.first?.hostID
        NavigationStack(path: pushed) {
            Group {
                if let id {
                    HostWorkloadsScreen(containers: model.containers(for: id))
                } else {
                    SelectServerView()
                }
            }
            .sectionSwitcher()
            .navigationDestination(for: ContainersRoute.self) { ContainersDestination(route: $0).sectionSwitcher() }
        }
        .transaction(value: isTabShown) { $0.disablesAnimations = true }
        .id(id)
        .containersStack(navigator.containerPath, model: model)
    }

    /// The Containers stack past its first screen, the server's workloads; none while hidden.
    private var pushed: Binding<[ContainersRoute]> {
        Binding(
            get: { isTabShown ? Array(navigator.containerPath.dropFirst()) : [] },
            set: { path in
                guard isTabShown else { return }
                navigator.containerPath = Array(navigator.containerPath.prefix(1)) + path
            }
        )
    }
}

/// The terminal picked in the sidebar, or a button to open one on the selected server.
private struct SplitTerminal: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NavigationStack {
            content
                .sectionSwitcher()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let id = navigator.terminalPath.last {
            TerminalScreen(id: id)
                .id(id)
        } else if let id = navigator.selectedHost, let host = model.host(id: id) {
            AeroEmptyState(
                systemImage: "terminal",
                title: "No terminal open",
                message: "Open a shell on \(host.name). It stays open while you use the rest of the app."
            ) {
                Button("New Terminal", systemImage: "plus") {
                    navigator.show(terminal: model.openTerminal(on: id).id)
                }
                .buttonStyle(.aqua)
                .disabled(!model.canOpenSession(on: host))
            }
            .background { SkyBackground() }
        } else {
            SelectServerView()
        }
    }
}

/// The selected server's files.
private struct SplitFiles: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NavigationStack {
            Group {
                if let id = navigator.filePath.first {
                    FilesScreen(id: id)
                        .id(id)
                } else {
                    SelectServerView()
                }
            }
            .sectionSwitcher()
        }
    }
}

/// A tab with no server to show.
private struct SelectServerView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        Group {
            if model.hosts.isEmpty {
                AeroEmptyState(systemImage: "server.rack", title: "No servers yet", message: "Add a server in the sidebar.")
            } else {
                AeroEmptyState(systemImage: "sidebar.leading", title: "No server selected", message: "Pick a server in the sidebar.")
            }
        }
        .background { SkyBackground() }
    }
}

/// The tab switcher in place of the title, after a Back button to the cards when `back` is set.
/// Where the bar has no room for every tab's title, only the selected tab shows its title.
private struct SectionSwitcher: ViewModifier {
    let back: (() -> Void)?
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .tabToolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        if let back {
                            Button("Servers", systemImage: "chevron.backward", action: back)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.aquaSecondary)
                        }
                        ViewThatFits(in: .horizontal) {
                            TabSwitcher(tabs: MobileSection.switcherTabs, selection: selection)
                            TabSwitcher(tabs: MobileSection.switcherTabs, selection: selection, isCompact: true)
                        }
                    }
                }
            }
    }

    private var selection: Binding<MobileSection> {
        Binding(
            get: { navigator.switcherSection },
            set: { section in
                let terminal = navigator.selectedHost.flatMap {
                    model.terminal(toShowOn: $0, current: navigator.terminalPath.last)
                }
                navigator.open(section, terminal: terminal)
            }
        )
    }
}

private extension View {
    func sectionSwitcher(back: (() -> Void)? = nil) -> some View {
        modifier(SectionSwitcher(back: back))
    }
}

extension EnvironmentValues {
    /// False while the split layout keeps this tab alive but hidden under another one.
    @Entry var isTabShown = true
}

extension View {
    /// The screen's toolbar `items`, left out while its tab is hidden (``EnvironmentValues/isTabShown``).
    func tabToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(TabToolbar(items: items()))
    }

    /// `searchable`, left out while the screen's tab is hidden.
    func tabSearchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringKey? = nil) -> some View {
        modifier(TabSearchable(text: text, placement: placement, prompt: prompt))
    }
}

private struct TabToolbar<Items: ToolbarContent>: ViewModifier {
    let items: Items
    @Environment(\.isTabShown) private var isTabShown

    func body(content: Content) -> some View {
        content.toolbar { if isTabShown { items } }
    }
}

private struct TabSearchable: ViewModifier {
    @Binding var text: String
    let placement: SearchFieldPlacement
    let prompt: LocalizedStringKey?
    @Environment(\.isTabShown) private var isTabShown

    func body(content: Content) -> some View {
        content.background {
            if isTabShown {
                Color.clear.searchable(text: $text, placement: placement, prompt: prompt.map { Text($0) })
            }
        }
    }
}

extension MobileModel {
    /// The terminal the split layout shows for server `id`: `current` if it is one of the
    /// server's, otherwise the server's newest; nil when it has none open.
    func terminal(toShowOn id: RemoteHost.ID, current: MobileTerminal.ID?) -> MobileTerminal.ID? {
        if let current, terminal(id: current)?.hostID == id { return current }
        return terminals.last { $0.hostID == id }?.id
    }
}

#Preview("Split") {
    SplitRootView()
        .environment(MobileModel.preview())
        .environment(MobileNavigator())
}
