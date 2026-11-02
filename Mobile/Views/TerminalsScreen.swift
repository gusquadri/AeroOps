import AeroCore
import AeroTheme
import EmbeddedTerminal
import SwiftUI

/// The Terminals tab: the open sessions, tap one to go back to it, swipe to end it. Leaving a
/// terminal keeps it open.
struct TerminalsScreen: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    @State private var isPickingHost = false

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.terminalPath) {
            content
                .background { SkyBackground() }
                .navigationTitle("Terminals")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Terminal", systemImage: "plus") { isPickingHost = true }
                    }
                }
                .navigationDestination(for: MobileTerminal.ID.self) { TerminalScreen(id: $0) }
        }
        .sheet(isPresented: $isPickingHost) {
            NewTerminalSheet { navigator.terminalPath.append(model.openTerminal(on: $0).id) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.terminals.isEmpty {
            AeroEmptyState(
                systemImage: "terminal",
                title: "No terminals open",
                message: "Open a shell on one of your servers. It stays open while you use the rest of the app."
            ) {
                Button("New Terminal", systemImage: "plus") { isPickingHost = true }
                    .buttonStyle(.aqua)
            }
        } else {
            List(model.terminals) { terminal in
                NavigationLink(value: terminal.id) {
                    TerminalRow(title: model.title(of: terminal), summary: model.host(id: terminal.hostID)?.connectionSummary, state: terminal.session.state)
                }
                .swipeActions {
                    Button("End", systemImage: "xmark", role: .destructive) { model.closeTerminal(terminal.id) }
                }
                .listRowBackground(Aero.glass.fill)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct TerminalRow: View {
    let title: String
    let summary: String?
    let state: EmbeddedTerminalSession.State

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(tone: state.orbTone, size: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Aero.font(.headline))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                if let summary {
                    Text(summary)
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(state.title)
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Picks the server of a new terminal.
private struct NewTerminalSheet: View {
    let onPick: (RemoteHost.ID) -> Void
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .background { SkyBackground() }
                .navigationTitle("New Terminal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
            NoServersView()
        } else {
            List(model.hosts) { host in
                Button {
                    onPick(host.id)
                    dismiss()
                } label: {
                    HostRow(host: host, status: model.displayState(for: host.id).status)
                }
                .disabled(!model.canOpenSession(on: host))
                .listRowBackground(Aero.glass.fill)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

extension MobileModel {
    /// The server's name, numbered from a host's second terminal on.
    func title(of terminal: MobileTerminal) -> String {
        let name = host(id: terminal.hostID)?.name ?? "Server removed"
        return terminal.number > 1 ? "\(name) (\(terminal.number))" : name
    }
}

private extension EmbeddedTerminalSession.State {
    var title: String {
        switch self {
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .running: "Connected"
        case .ended: "Ended"
        case .disconnected: "Disconnected"
        case .failed: "Failed"
        }
    }

    var orbTone: OrbTone {
        switch self {
        case .running: .healthy
        case .connecting, .reconnecting, .ended: .neutral
        case .disconnected: .warning
        case .failed: .error
        }
    }
}
