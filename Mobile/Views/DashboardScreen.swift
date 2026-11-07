import AeroCore
import AeroTheme
import SwiftUI

/// The Servers tab: the dashboard, with a host's details or a folder pushed over it.
struct DashboardScreen: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.serverPath) {
            DashboardContent(onOpen: { navigator.serverPath.append($0) })
                .navigationDestination(for: ServerRoute.self, destination: screen)
        }
        .onChange(of: model.folders.map(\.id)) { _, ids in navigator.closeFolders(notIn: Set(ids)) }
    }

    @ViewBuilder
    private func screen(for route: ServerRoute) -> some View {
        switch route {
        case .host(let id): HostScreen(id: id)
        case .folder(let id): FolderScreen(id: id, onSelect: { navigator.serverPath.append(.host($0)) })
        }
    }
}

/// The host folders, then every host in none; tap a folder to open it, a card for its details, or its buttons for its files and terminal.
/// Long-press a card to drag it into place or onto a folder. The search field (name or address) lists every matching host instead. Pull
/// to poll every host now. The + menu adds a host or a folder; the info menu links to the privacy policy and the source code.
///
/// It sits in the Servers tab's stack or the split layout's detail; `onOpen` shows a host's details or a folder.
struct DashboardContent: View {
    let onOpen: (ServerRoute) -> Void
    /// Add, Exit Samples and About in the toolbar; the split layout has them in its sidebar.
    var showsAppItems = true
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.showSampleServers) private var showSampleServers
    @State private var editor: HostEditorScreen.Request?
    @State private var search = ""
    @State private var folderRequest: FolderNameRequest?
    @State private var folderDeletion: HostFolder?

    var body: some View {
        content
            .background { SkyBackground() }
            .tabSearchable(text: $search, prompt: "Name or address")
            .navigationTitle(isShowingSamples ? "Sample Servers" : "Servers")
            .toolbar {
                if showsAppItems {
                    AppToolbarItems(exitSamples: isShowingSamples ? showSampleServers : nil)
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Add", systemImage: "plus") {
                            Button("New Host", systemImage: "server.rack") { editor = .new }
                            Button("New Folder", systemImage: "folder") { folderRequest = .new(moving: nil) }
                        }
                    }
                }
            }
            .sheet(item: $editor) { request in
                HostEditorScreen(request: request)
            }
            .folderNameSheet($folderRequest) { try model.saveFolder($0, name: $1) }
            .folderDeletionConfirmation($folderDeletion) { model.deleteFolder($0) }
            .task(openDebugScreen)
            .alert(
                "Couldn’t save the change",
                isPresented: Binding(get: { model.layoutError != nil }, set: { if !$0 { model.layoutError = nil } }),
                presenting: model.layoutError
            ) { _ in
                Button("OK") {}
            } message: { error in
                Text(error.localizedDescription)
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty, model.folders.isEmpty {
            AeroEmptyState(
                systemImage: "server.rack",
                title: "No servers yet",
                message: "Add a server to see its CPU, memory and disks. AeroOps signs in with a key from the Keys tab or a password kept in the Keychain."
            ) {
                Button("Add Host", systemImage: "plus") { editor = .new }
                    .buttonStyle(.aqua)
                if let showSampleServers {
                    Button("Try Sample Servers", systemImage: "sparkles") { showSampleServers(true) }
                        .buttonStyle(.aquaSecondary)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    problems
                    HostStatusSummary(counts: model.statusCounts())
                    hostsSection
                }
                .padding(16)
            }
            .refreshable { model.refreshAll() }
        }
    }

    @ViewBuilder
    private var hostsSection: some View {
        if search.isEmpty {
            HostFolderShelf(
                folders: model.folders,
                statuses: { id in model.hosts(inFolder: id).map { model.displayState(for: $0.id).status } },
                onOpen: { onOpen(.folder($0.id)) },
                onRename: { folderRequest = .rename($0) },
                onDelete: { folderDeletion = $0 },
                onDrop: { model.arrange($0, on: $1) }
            )
            grid(model.hosts(inFolder: nil), isArranging: true)
        } else {
            let hosts = model.hosts.matching(search: search)
            if hosts.isEmpty {
                NoMatchingHostsView(search: search)
            } else {
                grid(hosts, isArranging: false)
            }
        }
    }

    private func grid(_ hosts: [RemoteHost], isArranging: Bool) -> some View {
        HostCardGrid(
            hosts: hosts,
            folder: nil,
            isArranging: isArranging,
            onSelect: { onOpen(.host($0)) },
            onNewFolder: { folderRequest = .new(moving: $0) }
        )
    }

    private var isShowingSamples: Bool {
        model.isShowingSamples(canExit: showSampleServers != nil)
    }

    private func openDebugScreen() {
        guard let first = model.hosts.first else { return }
        switch MobileDebugOptions.screen {
        case .host: navigator.serverPath = [.host(first.id)]
        case .add: editor = .new
        case .edit: editor = .edit(first.id)
        default: break
        }
    }

    @ViewBuilder
    private var problems: some View {
        if let error = model.keyStoreError {
            ValidationMessage(text: "Keys are unavailable: \(error)")
        }
        if let error = model.hostsError {
            ValidationMessage(text: "Could not load your servers: \(error)")
        }
        if let error = model.hostKeyError {
            ValidationMessage(text: error)
        }
    }
}

/// Exit Samples (when `exitSamples` is set) and the About menu, at the leading edge of the
/// Servers tab or the split layout's sidebar.
struct AppToolbarItems: ToolbarContent {
    let exitSamples: (@MainActor (Bool) -> Void)?

    var body: some ToolbarContent {
        if let exitSamples {
            ToolbarItem(placement: .topBarLeading) {
                Button("Exit Samples") { exitSamples(false) }
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu("About AeroOps", systemImage: "info.circle") {
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                Link("Source Code", destination: AppLinks.sourceCode)
            }
        }
    }
}

extension MobileModel {
    /// Sample servers the user chose to try (not `-AeroOpsDemo` screenshots or previews, where
    /// there is no way out: `canExit` is false).
    func isShowingSamples(canExit: Bool) -> Bool {
        isPreview && canExit
    }
}

#Preview("Dashboard") {
    DashboardScreen()
        .environment(MobileModel.preview())
        .environment(MobileNavigator())
}

#Preview("Dashboard · empty") {
    DashboardScreen()
        .environment(MobileModel.preview(hosts: []))
        .environment(MobileNavigator())
        .environment(\.showSampleServers) { _ in }
}
