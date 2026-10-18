import AeroCore
import AeroTheme
import EmbeddedTerminal
import SwiftUI

/// A shell on one host in a libghostty surface, with libghostty's key bar above the keyboard.
/// It connects when shown and ends when the screen is closed. A connection that drops (the app
/// went to the background, the network changed) leaves the last screen up with Reconnect.
struct TerminalScreen: View {
    let id: RemoteHost.ID
    @Environment(MobileModel.self) private var model

    var body: some View {
        if let host = model.host(id: id) {
            TerminalSessionView(host: host, session: model.terminal(for: id))
                .navigationTitle(host.name)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            AeroEmptyState(systemImage: "server.rack", title: "Server removed", message: "This server is no longer in AeroOps.")
        }
    }
}

private struct TerminalSessionView: View {
    let host: RemoteHost
    let session: EmbeddedTerminalSession

    var body: some View {
        EmbeddedTerminalView(session: session)
            .clipShape(.rect(cornerRadius: Aero.radius.inner))
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .overlay { overlay }
            .background { SkyBackground() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                        .disabled(session.state == .connecting)
                }
            }
            .task {
                // Only the first time: after the shell ended or the connection dropped, the
                // screen waits for Reconnect.
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
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(host.name)…")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Aero.glass.fill, in: .capsule)
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
                message: "The connection to \(host.name) closed. AeroOps disconnects while it is in the background."
            )
        case .failed(let error):
            SessionIssueView(host: host, error: error, retryTitle: "Reconnect") { session.reconnect() }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
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
