import AeroCore
import AeroTheme
import EmbeddedTerminal
import SwiftUI

/// The split layout's sidebar, like the Mac's: every server with its status, its open terminals
/// under it (tap one to show it in Terminals), Add Host and Keys at the bottom, and a context
/// menu per server.
struct SplitSidebar: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.showSampleServers) private var showSampleServers
    @State private var editor: HostEditorScreen.Request?

    var body: some View {
        List(selection: selection) {
            Section("Servers") {
                ForEach(model.hosts) { host in
                    HostRow(host: host, status: model.displayState(for: host.id).status)
                        .tag(SidebarItem.host(host.id))
                        .contextMenu { menu(for: host) }
                    ForEach(model.terminals.filter { $0.hostID == host.id }) { terminal in
                        SidebarTerminalRow(title: model.title(of: terminal), state: terminal.session.state)
                            .tag(SidebarItem.terminal(terminal.id))
                            .swipeActions {
                                Button("End", systemImage: "xmark", role: .destructive) { model.closeTerminal(terminal.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.hosts.isEmpty {
                Text("No servers yet")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Button("Add Host", systemImage: "plus") { editor = .new }
                    .buttonStyle(.aqua)
                Button("Keys", systemImage: "key.horizontal") { navigator.isShowingKeys = true }
                    .buttonStyle(.aquaSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding([.horizontal, .top], 12)
        }
        .ignoresSafeArea(.keyboard)
        .navigationTitle(model.isShowingSamples(canExit: showSampleServers != nil) ? "Sample Servers" : "AeroOps")
        .toolbar {
            AppToolbarItems(exitSamples: model.isShowingSamples(canExit: showSampleServers != nil) ? showSampleServers : nil)
        }
        .resizableSidebar()
        .sheet(item: $editor) { request in
            HostEditorScreen(request: request)
        }
    }

    @ViewBuilder
    private func menu(for host: RemoteHost) -> some View {
        Button("New Terminal", systemImage: "terminal") {
            navigator.show(terminal: model.openTerminal(on: host.id).id)
        }
        .disabled(!model.canOpenSession(on: host))
        Button("Browse Files", systemImage: "folder") { navigator.showFiles(of: host.id) }
        Button("Edit", systemImage: "pencil") { editor = .edit(host.id) }
    }

    /// On Terminals, the terminal shown; otherwise the selected server. Picking a server on
    /// Terminals shows its newest terminal.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if navigator.section == .terminals, let id = navigator.terminalPath.last {
                    return .terminal(id)
                }
                return navigator.selectedHost.map(SidebarItem.host)
            },
            set: { item in
                switch item {
                case .host(let id):
                    navigator.select(host: id, terminal: model.terminal(toShowOn: id, current: navigator.terminalPath.last))
                case .terminal(let id):
                    navigator.show(terminal: id)
                case nil:
                    break
                }
            }
        )
    }
}

/// The sidebar's width, which the user sets by dragging its edge (``SidebarResizeHandle``). It is
/// kept across launches.
private enum SidebarWidth {
    static let key = "splitSidebarWidth"
    static let range = 280.0...340.0
    static let initial = 280.0
}

/// Sizes the sidebar column to the width it was dragged to.
private struct ResizableSidebar: ViewModifier {
    @AppStorage(SidebarWidth.key) private var width = SidebarWidth.initial

    func body(content: Content) -> some View {
        content.navigationSplitViewColumnWidth(width.clamped(to: SidebarWidth.range))
    }
}

private extension View {
    func resizableSidebar() -> some View {
        modifier(ResizableSidebar())
    }
}

/// A strip astride the sidebar's trailing edge, over both columns and the navigation bar, that
/// resizes the sidebar when dragged.
struct SidebarResizeHandle: View {
    private static let reach = 12.0
    @AppStorage(SidebarWidth.key) private var width = SidebarWidth.initial
    @State private var dragStart: Double?

    var body: some View {
        Color.clear
            .frame(width: Self.reach * 2)
            .contentShape(Rectangle())
            .highPriorityGesture(drag)
            .offset(x: width.clamped(to: SidebarWidth.range) - Self.reach)
            .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? width.clamped(to: SidebarWidth.range)
                dragStart = start
                width = (start + value.translation.width).clamped(to: SidebarWidth.range)
            }
            .onEnded { _ in dragStart = nil }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private enum SidebarItem: Hashable {
    case host(RemoteHost.ID)
    case terminal(MobileTerminal.ID)
}

/// A terminal under its server in the sidebar: its title over its state, its orb in line with
/// the server's name.
private struct SidebarTerminalRow: View {
    let title: String
    let state: EmbeddedTerminalSession.State

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(tone: state.orbTone, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Aero.font(.subheadline, weight: .medium))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                Text(state.title)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 22)
        .accessibilityElement(children: .combine)
    }
}
