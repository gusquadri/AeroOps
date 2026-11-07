import AeroCore
import AeroTheme
import SwiftUI

/// The main window: host sidebar, tab content over the sky background, the toolbar tab switcher
/// and a Settings button.
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
                .environment(\.sidebarVisibility, $columnVisibility)
        }
        .searchable(text: $model.hostSearch, placement: .sidebar, prompt: "Name or address")
        .navigationTitle("AeroOps")
        .toolbar {
            ToolbarItem(placement: .principal) {
                TabSwitcher(selection: $model.selectedTab)
            }
            // On every tab; on the Dashboard it sits left of Refresh and Details.
            ToolbarItem(placement: .primaryAction) {
                SettingsToolbarButton()
            }
        }
        .sheet(item: $model.editorRequest) { request in
            HostEditorSheet(request: request)
        }
        .sshConfigImportSheet(isPresented: $model.isImportingSSHConfig) { ids in
            if let first = ids.first { model.selection = first }
        }
            if let first = ids.first { model.selection = first }
        }
        // Closing the sheet any other way than its own buttons still counts as skipped.
        .sheet(isPresented: $model.onboarding.isPresented, onDismiss: { model.onboarding.complete() }) {
            OnboardingView()
        }
    }
}

extension EnvironmentValues {
    /// The main window's sidebar visibility, for content that needs to make room (the
    /// Containers inspector in a narrow window).
    @Entry var sidebarVisibility: Binding<NavigationSplitViewVisibility> = .constant(.all)
}

/// The tab switcher in the toolbar: one segment per tab, each with its SF Symbol and title.
/// ⌘1–⌘5 live in the View menu (``AppCommands``).
///
/// Custom rather than a segmented `Picker`: on macOS a segmented control shows a `Label`'s
/// title or its icon, never both.
struct TabSwitcher: View {
    @Binding var selection: AppTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                segment(tab)
            }
        }
        .padding(2)
        .fixedSize()
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section")
    }

    private func segment(_ tab: AppTab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            Label(tab.title, systemImage: tab.systemImage)
                .labelStyle(.titleAndIcon)
                .font(Aero.font(.body, weight: .medium))
                .foregroundStyle(isSelected ? Aero.text.onAccent : Aero.text.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    // The selected tab is a lit gel pill (aqua by day, violet by night) that slides between tabs.
                    if isSelected {
                        AquaGel()
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(tab.title) (⌘\(String(tab.shortcutDigit)))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Opens the Settings window at the pane it last showed.
private struct SettingsToolbarButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings", systemImage: "gearshape") { openSettings() }
            .help("Open Settings (⌘,)")
    }
}

/// The content of one main-window tab.
struct TabContent: View {
    let tab: AppTab

    var body: some View {
        content
            // Dashboard and Activity scroll under the toolbar and need the system's scroll edge
            // blur there. The other tabs never do, and without a scroll view at the top macOS
            // paints a pale backdrop behind the toolbar instead of the sky.
            .toolbarBackgroundVisibility(scrollsUnderToolbar ? .automatic : .hidden, for: .windowToolbar)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .dashboard: DashboardView()
        case .containers: ContainersView()
        case .terminals: TerminalsView()
        case .files: FilesView()
        case .activity: ActivityView()
        }
    }

    private var scrollsUnderToolbar: Bool {
        switch tab {
        case .dashboard, .activity: true
        case .containers, .terminals, .files: false
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
