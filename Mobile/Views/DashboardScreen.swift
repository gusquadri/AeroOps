import AeroCore
import AeroTheme
import SwiftUI

/// A screen pushed from the dashboard.
enum MobileRoute: Hashable {
    case host(RemoteHost.ID)
    case terminal(RemoteHost.ID)
    case files(RemoteHost.ID)
}

/// Every host's card; tap one for its details, and from there its terminal and files. Pull to
/// poll every host now.
struct DashboardScreen: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.showSampleServers) private var showSampleServers
    @State private var path: [MobileRoute] = []
    @State private var editor: HostEditorScreen.Request?
    /// Why turning a host's monitoring on or off could not be saved.
    @State private var monitoringFailure: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            content
                .background { SkyBackground() }
                .navigationTitle(isShowingSamples ? "Sample Servers" : "Servers")
                .toolbar {
                    if isShowingSamples, let showSampleServers {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Exit Samples") { showSampleServers(false) }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Host", systemImage: "plus") { editor = .new }
                    }
                }
                .navigationDestination(for: MobileRoute.self) { route in
                    switch route {
                    case .host(let id): HostScreen(id: id) { path.append($0) }
                    case .terminal(let id): TerminalScreen(id: id)
                    case .files(let id): FilesScreen(id: id)
                    }
                }
        }
        .onChange(of: path) { old, new in
            // A closed terminal screen ends its shell.
            for case .terminal(let id) in old where !new.contains(.terminal(id)) {
                model.closeTerminal(id)
            }
        }
        .sheet(item: $editor) { request in
            HostEditorScreen(request: request)
        }
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
        .alert(
            "Couldn’t save the server",
            isPresented: Binding(get: { monitoringFailure != nil }, set: { if !$0 { monitoringFailure = nil } }),
            presenting: monitoringFailure
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(model.hosts) { host in
                            card(for: host)
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { model.refreshAll() }
        }
    }

    /// Sample servers the user chose to try (not `-AeroOpsDemo` screenshots or previews).
    private var isShowingSamples: Bool {
        model.isPreview && showSampleServers != nil
    }

    private func openDebugScreen() {
        guard let first = model.hosts.first else { return }
        switch MobileDebugOptions.screen {
        case .host: path = [.host(first.id)]
        case .terminal: path = [.host(first.id), .terminal(first.id)]
        case .files: path = [.host(first.id), .files(first.id)]
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

    private func toggleMonitoring(_ host: RemoteHost) {
        do {
            try model.setMonitoring(!host.monitored, for: host.id)
        } catch {
            monitoringFailure = error.localizedDescription
        }
    }

    private func card(for host: RemoteHost) -> some View {
        HostCard(
            host: host,
            state: model.displayState(for: host.id),
            showsSessionActions: false,
            keyBlock: model.hostKeyBlock(for: host),
            onReviewKey: { path.append(.host(host.id)) },
            onTrustKey: { Task { await model.requestHostKeyTrust(for: host) } },
            isScanningKey: model.scanningHostIDs.contains(host.id),
            keyScanError: model.scanErrors[host.id],
            onToggleMonitoring: { toggleMonitoring(host) }
        )
        .equatable()
        .contentShape(.rect(cornerRadius: Aero.radius.card))
        .onTapGesture { path.append(.host(host.id)) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the server’s details")
    }
}

#Preview("Dashboard") {
    DashboardScreen()
        .environment(MobileModel.preview())
}

#Preview("Dashboard · empty") {
    DashboardScreen()
        .environment(MobileModel.preview(hosts: []))
        .environment(\.showSampleServers) { _ in }
}
