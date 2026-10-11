import AeroCore
import AeroTheme
import SwiftUI

/// The main window: host sidebar, tab content over the sky background, and the toolbar tab switcher.
struct RootView: View {
    @Environment(AppModel.self) private var model
    /// The host list is the main navigation, so every launch starts with it showing (the user
    /// can still hide it for the session).
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HostSidebar()
        } detail: {
            TabContent(tab: model.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { HostLoadErrorBanner() }
                .background { SkyBackground() }
        }
        .navigationTitle("AeroOps")
        .toolbar {
            ToolbarItem(placement: .principal) {
                TabSwitcher(selection: $model.selectedTab)
            }
        }
        .sheet(item: $model.editorRequest) { request in
            HostEditorSheet(request: request)
        }
    }
}

/// The segmented tab control in the toolbar. ⌘1–⌘4 live in the View menu (``AppCommands``).
struct TabSwitcher: View {
    @Binding var selection: AppTab

    var body: some View {
        Picker("Section", selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .help("\(tab.title) (⌘\(String(tab.shortcutDigit)))")
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .labelsHidden()
        .fixedSize()
    }
}

/// The content of one main-window tab.
struct TabContent: View {
    let tab: AppTab

    var body: some View {
        switch tab {
        case .dashboard: DashboardView()
        case .containers: ContainersView()
        case .terminals: TerminalsView()
        case .activity: ActivityView()
        }
    }
}

#Preview("Window · empty") {
    RootView()
        .environment(AppModel.preview(hosts: []))
        .frame(width: 1100, height: 700)
}

#Preview("Window · one host") {
    RootView()
        .environment(AppModel.preview(hosts: [SampleData.hosts[0]], statuses: [.online]))
        .frame(width: 1100, height: 700)
}

#Preview("Window · many hosts, every status") {
    RootView()
        .environment(AppModel.preview(withMetrics: true))
        .frame(width: 1100, height: 700)
}
