import AeroCore
import AeroTheme
import Collectors
import SSHKit
import SwiftUI

/// Dashboard tab: one card per host matching the sidebar's search field, fed live by
/// ``MonitorService``, and the selected host's details in an inspector.
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
            .onChange(of: model.selection) { _, selection in
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
                    let hosts = model.searchedHosts
                    if hosts.isEmpty {
                        NoMatchingHostsView(search: model.hostSearch)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(hosts) { host in
                                card(for: host)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
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
