import AeroCore
import AeroTheme
import SwiftUI

/// The layout of a regular-width screen (an unfolded iPhone Duo, a Pro Max in landscape), like the
/// Mac app's window: the servers and their terminals in a sidebar, and the selected server's
/// Servers, Containers, Terminals or Files tab beside it, picked with the Mac's tab switcher.
/// Keys opens as a sheet from the sidebar. The sidebar sits beside the tab, as on the Mac, not
/// over it as an iPhone lays it by default.
///
/// It keeps its state in ``MobileNavigator``'s stacks, so folding back to the tabs shows the same
/// screens.
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
        case .servers: navigator.serverPath.first
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

/// The selected tab, each with the tab switcher in its navigation bar.
///
/// Every tab shown so far stays alive under the selected one, as a tab bar keeps its tabs:
/// switching back is instant and keeps the tab's place, where building a tab's screens anew
/// takes the main thread a tenth of a second. A hidden tab gets `isTabShown` false: it stops its
/// work, and its screens hide their toolbar items (``SwiftUI/View/tabToolbar(_:)``), which would
/// otherwise show in the selected tab's navigation bar. Not a `TabView` with its bar hidden: in
/// the split view's detail column, its tabs lose their navigation bars.
private struct SplitDetail: View {
    @Environment(MobileNavigator.self) private var navigator
    @State private var opened: Set<MobileSection> = []

    var body: some View {
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

    /// Keys is a sheet here, so it shows the Servers tab under it.
    private var shown: MobileSection {
        navigator.section == .keys ? .servers : navigator.section
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

/// Every server's card; picking one (here or in the sidebar) shows its details in their place,
/// and Back returns to the cards. It shows the Servers tab's stack, so folding keeps it.
///
/// Not the Mac's inspector beside the cards: beside the sidebar there is no room for both (an
/// iPhone's `.inspector` lays itself over the cards and dims them instead). And the details are
/// the stack's root rather than pushed onto it, like the other tabs' screens: picking a row in
/// the sidebar pops the detail column's stack, which would close them.
private struct SplitServers: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NavigationStack {
            if let id = navigator.serverPath.last {
                HostScreen(id: id)
                    .id(id)
                    .sectionSwitcher(back: { navigator.serverPath = [] })
            } else {
                DashboardContent(onSelect: { navigator.select(host: $0, terminal: nil) }, showsAppItems: false)
                    .sectionSwitcher()
            }
        }
    }
}

/// The selected server's containers and pods; their screens push here.
///
/// Hidden, the tab pops its screens, and pushes them again when shown: pushed screens sit in
/// the split view's detail column itself, over whichever tab is shown, not in the tab.
private struct SplitContainers: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.isTabShown) private var isTabShown

    var body: some View {
        if let id = navigator.containerPath.first?.hostID {
            NavigationStack(path: pushed) {
                HostWorkloadsScreen(containers: model.containers(for: id))
                    .sectionSwitcher()
                    .navigationDestination(for: ContainersRoute.self) { ContainersDestination(route: $0).sectionSwitcher() }
            }
            .transaction(value: isTabShown) { $0.disablesAnimations = true }
            .id(id)
            .containersStack(navigator.containerPath, model: model)
        } else {
            NavigationStack {
                SelectServerView()
                    .sectionSwitcher()
            }
        }
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
            if let id = navigator.filePath.first {
                FilesScreen(id: id)
                    .id(id)
                    .sectionSwitcher()
            } else {
                SelectServerView()
                    .sectionSwitcher()
            }
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
///
/// Back sits beside the switcher rather than in its own leading item: beside the sidebar, the
/// navigation bar has no room left for one and lays it below the bar, at the far edge.
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
                        TabSwitcher(tabs: MobileSection.switcherTabs, selection: selection)
                    }
                }
            }
    }

    private var selection: Binding<MobileSection> {
        Binding(
            get: { navigator.section == .keys ? .servers : navigator.section },
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
    /// False while the split layout keeps this tab alive but hidden under another one. Screens
    /// stop their work then, as a tab bar's hidden tab does when it disappears.
    @Entry var isTabShown = true
}

extension View {
    /// The screen's toolbar `items`, left out while its tab is hidden
    /// (``EnvironmentValues/isTabShown``): the split layout's tabs share one navigation bar.
    func tabToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(TabToolbar(items: items()))
    }

    /// `searchable`, left out while the screen's tab is hidden, as ``tabToolbar(_:)`` leaves out
    /// its items. It sits on a view behind the screen, so leaving it out keeps the screen as it is.
    func tabSearchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic) -> some View {
        modifier(TabSearchable(text: text, placement: placement))
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
    @Environment(\.isTabShown) private var isTabShown

    func body(content: Content) -> some View {
        content.background {
            if isTabShown {
                Color.clear.searchable(text: $text, placement: placement)
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
