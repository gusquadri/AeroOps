import AeroCore
import AeroTheme
import Collectors
import SwiftUI

/// The logs opened on `containers`, following while the container runs. Stops in the background,
/// where iOS drops the connection, and while its tab is hidden, and reads again on return.
struct LogsScreen: View {
    let containers: HostContainersModel

    var body: some View {
        if let viewer = containers.logs {
            LogsView(viewer: viewer)
        } else {
            AeroEmptyState(systemImage: "text.alignleft", title: "Logs closed", message: "Open them again from the container.")
                .background { SkyBackground() }
        }
    }
}

private struct LogsView: View {
    @Bindable var viewer: LogViewerModel
    @Environment(MobileModel.self) private var model
    @Environment(\.isTabShown) private var isTabShown

    var body: some View {
        VStack(spacing: 0) {
            banners
            LogTextView(controller: viewer.text)
                .overlay {
                    if viewer.status == .loading, viewer.lineCount == 0 { ProgressView() }
                }
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .background { SkyBackground() }
        .navigationTitle(viewer.title)
        .navigationSubtitle(statusText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .tabSearchable(text: $viewer.searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .tabToolbar { toolbar }
        .onAppear { viewer.start() }
        .onDisappear { viewer.stop() }
        .onChange(of: model.activity) { resume() }
        .onChange(of: isTabShown) { resume() }
        .task(id: viewer.searchText) { await search() }
    }

    @ViewBuilder
    private var banners: some View {
        if let issue = viewer.issue {
            LogsBanner(text: [issue.title, issue.hint].compactMap(\.self).joined(separator: "\n"), tint: Aero.coral)
        }
        if let notice = viewer.notice {
            LogsBanner(text: notice, tint: Aero.sun)
        }
    }

    private var statusText: String {
        switch viewer.status {
        case .following: "Following"
        case .loading: "Loading"
        case .paused: viewer.previous ? "Previous instance" : "Snapshot"
        case .ended: "Ended"
        case .failed: "Failed"
        case .idle: ""
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { LogsMenu(viewer: viewer) }
        if viewer.matchCount > 0 {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Previous Match", systemImage: "chevron.up") { viewer.previousMatch() }
                Text("\((viewer.currentMatch ?? 0) + 1) of \(viewer.matchCount)")
                    .font(Aero.font(.caption))
                    .monospacedDigit()
                Button("Next Match", systemImage: "chevron.down") { viewer.nextMatch() }
            }
        }
    }

    private func resume() {
        if model.activity == .paused || !isTabShown {
            viewer.stop()
        } else if viewer.follow {
            viewer.reload()
        }
    }

    /// Waits for typing to pause: highlighting thousands of lines per keystroke would stutter.
    private func search() async {
        let query = viewer.searchText
        if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
        guard !Task.isCancelled else { return }
        viewer.search(query)
    }
}

private struct LogsMenu: View {
    @Bindable var viewer: LogViewerModel

    var body: some View {
        Menu("Options", systemImage: "ellipsis.circle") {
            Toggle("Follow", systemImage: "dot.radiowaves.left.and.right", isOn: Binding(get: { viewer.follow }, set: { viewer.setFollow($0) }))
                .disabled(viewer.previous)
            Toggle("Timestamps", systemImage: "clock", isOn: $viewer.showTimestamps)
            if viewer.isPod { podItems }
            Divider()
            Button("Copy All", systemImage: "doc.on.doc") { viewer.copyAll() }
        }
    }

    @ViewBuilder
    private var podItems: some View {
        Toggle("Before Last Restart", systemImage: "clock.arrow.circlepath", isOn: Binding(get: { viewer.previous }, set: { viewer.setPrevious($0) }))
            .disabled(!viewer.canShowPrevious && !viewer.previous)
        if viewer.podContainers.count > 1 {
            Picker("Container", selection: Binding(get: { viewer.container ?? "" }, set: { viewer.setContainer($0) })) {
                ForEach(viewer.podContainers, id: \.name) { Text($0.name).tag($0.name) }
            }
        }
    }
}

private struct LogsBanner: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Aero.font(.caption))
            .foregroundStyle(Aero.text.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(tint.opacity(0.18))
    }
}
