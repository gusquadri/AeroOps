import AeroCore
import AeroTheme
import EmbeddedTerminal
import SwiftUI

/// A shell on one host in a libghostty surface, with libghostty's key bar above the keyboard.
/// It connects when first shown and stays open after the screen is closed, until End Session. A
/// connection that drops (the network changed, iOS suspended the app too long) leaves the screen
/// and scrollback up with Reconnect; coming back to the app reconnects by itself.
struct TerminalScreen: View {
    let id: MobileTerminal.ID
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if let terminal = model.terminal(id: id), let host = model.host(id: terminal.hostID) {
            TerminalSessionView(host: host, session: terminal.session, onEnd: end)
                .navigationTitle(model.title(of: terminal))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(.hidden, for: .tabBar)
        } else {
            AeroEmptyState(systemImage: "terminal", title: "Session ended", message: "This terminal is closed.")
        }
    }

    private func end() {
        navigator.terminalPath.removeAll { $0 == id }
        model.closeTerminal(id)
    }
}

private struct TerminalSessionView: View {
    let host: RemoteHost
    let session: EmbeddedTerminalSession
    let onEnd: () -> Void

    var body: some View {
        EmbeddedTerminalView(session: session)
            .clipShape(.rect(cornerRadius: Aero.radius.inner))
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .overlay { overlay }
            .background { SkyBackground() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Session", systemImage: "ellipsis.circle") {
                        Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                            .disabled(session.state == .connecting || session.state == .reconnecting)
                        Button("End Session", systemImage: "xmark", role: .destructive, action: onEnd)
                    }
                }
            }
            .task {
                if session.connection == 0 { session.connect() }
            }
            .onChange(of: session.state, initial: true) { _, state in
                if state == .running { session.focus() }
            }
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .connecting:
            progress("Connecting to \(host.name)…")
        case .reconnecting:
            progress("Reconnecting to \(host.name)…")
        case .running:
            EmptyView()
        case .ended(let status):
            notice(
                systemImage: "checkmark.circle.fill",
                tint: status == 0 || status == nil ? Aero.leaf : Aero.sun,
                title: "Session ended",
                message: status.map { "The shell exited with status \($0)." } ?? "The shell ended."
            )
        case .disconnected:
            notice(
                systemImage: "bolt.horizontal.circle.fill",
                tint: Aero.sun,
                title: "Disconnected",
                message: "The connection to \(host.name) closed. The screen stays; Reconnect opens a new shell below it."
            )
        case .failed(let error):
            SessionIssueView(host: host, error: error, retryTitle: "Reconnect") { session.reconnect() }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Aero.glass.fill, in: .capsule)
    }

    private func notice(systemImage: String, tint: Color, title: String, message: String) -> some View {
        AeroWell(tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(title)
                        .font(Aero.font(.headline, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }
                Text(message)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                    .buttonStyle(.aqua)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}
