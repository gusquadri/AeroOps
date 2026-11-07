import AeroCore
import AeroTheme
import Collectors
import SSHKit
import SwiftUI

/// Dashboard tab: one card per host matching the sidebar's search field, fed live by
/// ``MonitorService``, and the selected host's details in an inspector.
///
/// Without a search, folders come first as tiles, then the hosts in no folder; clicking a tile
/// shows that folder's hosts. Drag a card onto another to reorder, onto a tile to move it into
/// that folder, or onto "All Hosts" to take it out; drag tiles to reorder folders.
///
/// Each card observes only its own ``HostDisplayState``, so a poll result redraws one card.
/// Selecting a host in the sidebar or double-clicking a card opens ``HostDetailView``;
/// Refresh (⌘R) polls every host now.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showsDetail = false
    /// Set by a single click on a card, so that selection does not open the inspector.
    @State private var selectedFromCard = false
    /// Why turning a host's monitoring on or off could not be saved.
    @State private var monitoringFailure: HostStoreError?
    @State private var deletionCandidate: RemoteHost?

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20, alignment: .top)]

    var body: some View {
        @Bindable var monitoring = model.monitoring
        content
            .inspector(isPresented: $showsDetail) {
                detail
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshAll() }
                        .keyboardShortcut("r")
                        .help("Poll every host now (⌘R)")
                        .disabled(model.hosts.isEmpty)
                    Button("Details", systemImage: "sidebar.trailing") { showsDetail.toggle() }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(showsDetail ? "Hide host details (⌥⌘I)" : "Show the selected host's details (⌥⌘I)")
                        .disabled(model.hosts.isEmpty)
                }
            }
            .hostDeletionConfirmation($deletionCandidate)
            .onChange(of: model.selection) { _, selection in
                if let selection { model.showFolder(ofHost: selection) }
                if selectedFromCard {
                    selectedFromCard = false
                } else if selection != nil {
                    showsDetail = true
                }
            }
            .sheet(item: $monitoring.trustRequest) { request in
                HostKeyTrustSheet(
                    host: request.host,
                    offered: request.offered,
                    onTrust: { try await model.monitoring.trust(request) },
                    onCancel: { model.monitoring.trustRequest = nil }
                )
            }
            .alert(
                "Couldn’t save the host",
                isPresented: Binding(get: { monitoringFailure != nil }, set: { if !$0 { monitoringFailure = nil } }),
                presenting: monitoringFailure
            ) { _ in
                Button("OK") {}
            } message: { error in
                Text(error.localizedDescription)
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
            AeroEmptyState(
                systemImage: "square.grid.2x2",
                title: "Your servers will appear here",
                message: "Add a host to see its CPU, memory, disk, uptime and load at a glance, refreshed every few seconds over SSH."
            ) {
                AddHostButton()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HostStatusSummary(counts: model.statusCounts())
                    hostsSection
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private var hostsSection: some View {
        if !model.hostSearch.isEmpty {
            searchResults
        } else if let folder = model.openFolder {
            folderContents(folder)
        } else {
            topLevel
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let hosts = model.searchedHosts
        if hosts.isEmpty {
            NoMatchingHostsView(search: model.hostSearch)
        } else {
            grid(hosts, in: nil, isArranging: false)
        }
    }

    private var topLevel: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.folders.isEmpty {
                HostFolderShelf(
                    folders: model.folders,
                    statuses: { id in model.hosts(inFolder: id).map { model.displayState(for: $0.id).status } },
                    onOpen: { model.openFolderID = $0.id },
                    onRename: { model.folderRequest = .rename($0) },
                    onDelete: { model.folderDeletion = $0 },
                    onDrop: model.arrange
                )
            }
            grid(model.hosts(inFolder: nil), in: nil)
        }
    }

    private func folderContents(_ folder: HostFolder) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            FolderHeader(folder: folder, onBack: { model.openFolderID = nil }, onDrop: model.arrange)
            let hosts = model.hosts(inFolder: folder.id)
            if hosts.isEmpty {
                EmptyFolderView()
                    .hostArranging(nil, target: .end(folder: folder.id), onDrop: model.arrange)
            } else {
                grid(hosts, in: folder.id)
            }
        }
    }

    private func grid(_ hosts: [RemoteHost], in folder: HostFolder.ID?, isArranging: Bool = true) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(hosts) { host in
                card(for: host)
                    .contextMenu { HostMenu(host: host) { deletionCandidate = host } }
                    .hostArranging(.host(host.id), target: .item(.host(host.id)), isEnabled: isArranging, onDrop: model.arrange)
            }
        }
        .hostArranging(nil, target: .end(folder: folder), isEnabled: isArranging, onDrop: model.arrange)
    }

    private func card(for host: RemoteHost) -> some View {
        HostCard(
            host: host,
            state: model.displayState(for: host.id),
            isSelected: model.selection == host.id,
            canOpenSSH: model.canOpenSSH(host.id),
            onOpenSSH: { model.openSSH(host.id) },
            onBrowseFiles: { model.browseFiles(host.id) },
            keyBlock: model.hostKeyBlock(for: host.id),
            onReviewKey: { model.requestEdit(host.id) },
            onTrustKey: { Task { await model.monitoring.requestHostKeyTrust(for: host) } },
            isScanningKey: model.monitoring.scanningHostIDs.contains(host.id),
            keyScanError: model.monitoring.scanErrors[host.id],
            onToggleMonitoring: { toggleMonitoring(host) }
        )
        // Closures make cards unequal to SwiftUI, so without this every card would redraw
        // whenever the Dashboard does, e.g. for each new selection.
        .equatable()
        // Two gestures that recognise together: the first click selects at once instead of
        // waiting out the double-click interval, and the second also opens the inspector.
        .gesture(
            TapGesture(count: 1)
                .onEnded { select(host.id, fromCard: true) }
                .simultaneously(with: TapGesture(count: 2).onEnded { showsDetail = true })
        )
    }

    private func toggleMonitoring(_ host: RemoteHost) {
        do {
            try model.setMonitoring(!host.monitored, for: host.id)
        } catch {
            monitoringFailure = error
        }
    }

    private func select(_ id: RemoteHost.ID, fromCard: Bool) {
        guard model.selection != id else { return }
        selectedFromCard = fromCard
        model.selection = id
    }

    @ViewBuilder
    private var detail: some View {
        if let host = model.selectedHost {
            HostDetailView(host: host, state: model.displayState(for: host.id), keyBlock: model.hostKeyBlock(for: host.id), model: model)
        } else {
            ContentUnavailableView("No Host Selected", systemImage: "server.rack", description: Text("Select a host in the sidebar or double-click a card."))
                .font(Aero.font(.body))
                .foregroundStyle(Aero.text.secondary)
        }
    }
}

/// Above an open folder's cards: back to every host (drop a card here to take it out of the
/// folder), and the folder's name.
private struct FolderHeader: View {
    let folder: HostFolder
    let onBack: () -> Void
    let onDrop: (HostLayoutItem, HostLayoutTarget) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("All Hosts", systemImage: "chevron.left", action: onBack)
                .buttonStyle(.aquaSecondary)
                .hostArranging(nil, target: .end(folder: nil), cornerRadius: 100, onDrop: onDrop)
                .help("Back to every host. Drop a host here to take it out of the folder.")
            FolderGel(size: 32)
            Text(folder.name)
                .font(Aero.font(.title2, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
                .lineLimit(1)
        }
    }
}

/// An open folder with no hosts yet.
private struct EmptyFolderView: View {
    var body: some View {
        AeroCard {
            Text("Drag hosts here, or add one with Add › Add Host… while this folder is open.")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }
}

#Preview("Dashboard · every status") {
    DashboardView()
        .environment(AppModel.preview(withMetrics: true))
        .background { SkyBackground() }
        .frame(width: 1000, height: 700)
}

#Preview("Dashboard · empty") {
    DashboardView()
        .environment(AppModel.preview(hosts: []))
        .background { SkyBackground() }
        .frame(width: 800, height: 600)
}
