import AeroCore
import AeroTheme
import SwiftUI
import TerminalKit

/// Terminals tab: one libghostty ssh session per tab (Phase 4).
///
/// The sidebar lists the tabs under their hosts; the selected session's surface fills the tab.
/// Only the selected session is on screen; the others keep running and keep their scrollback.
/// Tabs not shown for a while give up their surface to save memory and get it back when shown.
/// First contact with a host shows the host-key trust sheet here, closing a
/// running tab asks first, and unsafe pastes ask in a sheet.
struct TerminalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let terminals = model.terminals
        Group {
            if let session = terminals.selectedSession {
                TerminalPane(session: session)
                    .id(session.id)
                    .padding(.top, 12)
                    .padding([.horizontal, .bottom], 16)
            } else {
                TerminalsEmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ⌘W, ⌃Tab, ⌘⌥1…9 and the font size items act on these tabs while they are shown.
        .focusedSceneValue(\.terminalTabs, terminals.sessions.isEmpty ? nil : terminals)
        .modifier(TerminalPrompts())
    }
}

// MARK: - Empty state

private struct TerminalsEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AeroEmptyState(
            systemImage: "terminal",
            title: "No terminal tabs",
            message: "Open SSH from a host card, the sidebar or here. Each tab runs OpenSSH against the host, signed by AeroOps’ own key agent."
        ) {
            if model.hosts.isEmpty {
                AddHostButton()
            } else if let host = model.selectedHost {
                Button("Open SSH to \(host.name)", systemImage: "terminal") { model.openSSH(host.id) }
                    .buttonStyle(.aqua)
                    .disabled(!model.canOpenSSH(host.id))
                    .help(model.terminals.unavailableReason(host) ?? "Open a terminal tab (⌘T)")
            } else {
                OpenSSHMenu()
            }
        }
    }
}

/// A menu of every host; hosts that can't be opened are disabled.
private struct OpenSSHMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.hosts) { host in
                Button(host.name) { model.openSSH(host.id) }
                    .disabled(!model.canOpenSSH(host.id))
            }
        } label: {
            Label("Open SSH…", systemImage: "terminal")
        }
        .fixedSize()
        .help("Choose a host")
    }
}

// MARK: - Status

extension TerminalService.Status.Tone {
    var orbTone: OrbTone {
        switch self {
        case .connecting: .warning
        case .running: .healthy
        case .ended: .neutral
        case .failed: .error
        }
    }
}

// MARK: - Session pane

/// The selected session's surface in a glass frame, with the exit banner once it ends.
private struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
        ZStack(alignment: .bottom) {
            // Clipboard prompts are shown by ``TerminalPrompts`` as an Aero sheet.
            TerminalSurfaceView(session: session, presentsClipboardPrompts: false)
                .clipShape(shape)
            if session.state.isFinished {
                TerminalExitBanner(session: session)
                    .padding(14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.state.isFinished)
        .padding(6)
        .aeroGlass(in: RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous))
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

/// "ssh failed (exit 255)" / "Session ended", with Reconnect and Close.
struct TerminalExitBanner: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession

    var body: some View {
        let status = TerminalService.status(of: session.state)
        let terminals = model.terminals
        AeroCard(padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                StatusOrb(tone: status.tone.orbTone, size: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.text)
                        .font(Aero.font(.headline, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                    if let hint = status.hint {
                        Text(hint)
                            .font(Aero.font(.callout))
                            .foregroundStyle(Aero.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Button("Close") { terminals.close(session.id) }
                    .buttonStyle(.aquaSecondary)
                Button("Reconnect", systemImage: "arrow.clockwise") { terminals.reconnect(session.id) }
                    .buttonStyle(.aqua)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!terminals.canReconnect(session.id))
            }
        }
        .frame(maxWidth: 680)
    }
}

// MARK: - Sheets and confirmations

/// Trust sheet for first contact, the close confirmation, clipboard prompts and open errors.
private struct TerminalPrompts: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var terminals = model.terminals
        content
            .sheet(item: $terminals.trustRequest) { request in
                HostKeyTrustSheet(
                    host: request.host,
                    offered: request.offered,
                    onTrust: { try await terminals.trustAndOpen(request) },
                    onCancel: { terminals.cancelTrust() }
                )
            }
            .sheet(item: clipboardPrompt) { prompt in
                TerminalClipboardSheet(prompt: prompt)
            }
            .confirmationDialog(
                "Close “\(closeTitle)”?",
                isPresented: Binding(
                    get: { terminals.closeConfirmation != nil },
                    set: { if !$0 { terminals.closeConfirmation = nil } }
                ),
                presenting: terminals.closeConfirmation
            ) { id in
                Button("Close Tab", role: .destructive) { terminals.close(id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The ssh session is still running. Closing the tab ends it.")
            }
            .alert(
                "Couldn’t open the terminal",
                isPresented: Binding(get: { terminals.openError != nil }, set: { if !$0 { terminals.openError = nil } }),
                presenting: terminals.openError
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
    }

    private var closeTitle: String {
        let terminals = model.terminals
        return terminals.closeConfirmation.flatMap { terminals.tab(for: $0)?.title } ?? "tab"
    }

    /// The selected session's pending prompt; dismissing the sheet denies it.
    private var clipboardPrompt: Binding<TerminalClipboardPrompt?> {
        let session = model.terminals.selectedSession
        return Binding(
            get: { session?.clipboardPrompt },
            set: { if $0 == nil { session?.clipboardPrompt?.deny() } }
        )
    }
}

/// Asks before an unsafe paste (text that would run commands) or a remote clipboard access.
struct TerminalClipboardSheet: View {
    let prompt: TerminalClipboardPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: prompt.kind == .paste ? "doc.on.clipboard" : "lock.shield")
                    .font(Aero.font(size: 34, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Aero.aqua)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(Aero.font(.title3, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                    Text(message)
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            AeroCard(padding: 12) {
                ScrollView {
                    Text(preview)
                        .font(Aero.monospacedFont(.callout))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { prompt.deny() }
                    .buttonStyle(.aquaSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(prompt.kind == .paste ? "Paste" : "Allow") { prompt.allow() }
                    .buttonStyle(.aqua)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background { Aero.sky.gradient.ignoresSafeArea() }
    }

    private var title: String {
        switch prompt.kind {
        case .paste: "Paste text that may run commands?"
        case .remoteRead: "Let the remote program read the clipboard?"
        case .remoteWrite: "Let the remote program set the clipboard?"
        }
    }

    private var message: String {
        switch prompt.kind {
        case .paste: "The text has line breaks or control characters, so the shell may run it as soon as it is pasted."
        case .remoteRead: "A program on the server asked for the contents of your clipboard."
        case .remoteWrite: "A program on the server wants to replace your clipboard with this text."
        }
    }

    private var preview: String {
        let limit = 2_000
        return prompt.contents.count > limit ? String(prompt.contents.prefix(limit)) + "…" : prompt.contents
    }
}

// MARK: - Focus

extension FocusedValues {
    /// The terminal tabs while the main window shows a non-empty Terminals tab; the menu
    /// commands (⌘W, ⌃Tab, ⌘⌥1…9, font size) act on them.
    @Entry var terminalTabs: TerminalService?
}

#Preview("Terminals · empty") {
    TerminalsView()
        .environment(AppModel.preview())
        .background { SkyBackground() }
        .frame(width: 800, height: 600)
}
