import AeroCore
import AeroTheme
import SwiftUI
import TerminalKit

/// Terminals tab: one libghostty ssh session per tab (Phase 4).
///
/// The tab strip sits above the selected session's surface. Only the selected session is on
/// screen; the others keep running and keep their scrollback. First contact with a host shows
/// the host-key trust sheet here, closing a running tab asks first, and unsafe pastes ask in a
/// sheet.
struct TerminalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let terminals = model.terminals
        Group {
            if terminals.sessions.isEmpty {
                TerminalsEmptyState()
            } else {
                VStack(spacing: 0) {
                    TerminalTabStrip()
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 10)
                    if let session = terminals.selectedSession {
                        TerminalPane(session: session)
                            .id(session.id)
                            .padding([.horizontal, .bottom], 16)
                    }
                }
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
                OpenSSHMenu(title: "Open SSH…")
            }
        }
    }
}

/// A menu of every host; hosts that can't be opened are disabled.
private struct OpenSSHMenu: View {
    @Environment(AppModel.self) private var model
    let title: String
    var compact = false

    var body: some View {
        Menu {
            ForEach(model.hosts) { host in
                Button(host.name) { model.openSSH(host.id) }
                    .disabled(!model.canOpenSSH(host.id))
            }
        } label: {
            if compact {
                Image(systemName: "plus")
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.aquaDeep)
                    .accessibilityLabel(title)
            } else {
                Label(title, systemImage: "terminal")
            }
        }
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .help(compact ? "New tab (⌘T opens the selected host)" : "Choose a host")
    }
}

// MARK: - Tab strip

/// The tabs in an aqua-glass pill: status orb, title (" (2)" for duplicates) and a close button.
/// Drag a tab onto another to reorder.
struct TerminalTabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let terminals = model.terminals
        let selectedID = terminals.selectedSession?.id
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(terminals.sessions) { session in
                            TerminalTabItem(
                                session: session,
                                tab: terminals.tab(for: session.id),
                                isSelected: session.id == selectedID
                            )
                            .id(session.id)
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.never)
                .fixedSize(horizontal: false, vertical: true)
                // Keep the shown tab in view when it changes (⌃Tab, ⌘⌥9, a new tab). Next turn,
                // so a tab added in the same update has been laid out.
                .onChange(of: selectedID, initial: true) { _, id in
                    guard let id else { return }
                    Task { withAnimation(.snappy) { proxy.scrollTo(id) } }
                }
            }

            if terminals.pendingOpens > 0 {
                ProgressView()
                    .controlSize(.small)
                    .help("Checking the host key…")
            }
            OpenSSHMenu(title: "New Tab", compact: true)
                .padding(.trailing, 10)
        }
        .aeroGlass(in: Capsule(), shadow: Aero.shadow.control)
    }
}

private struct TerminalTabItem: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    let tab: TerminalService.Tab?
    let isSelected: Bool

    @State private var isHovered = false
    @State private var isDropTarget = false

    private var terminals: TerminalService { model.terminals }
    private var status: TerminalService.Status { TerminalService.status(of: session.state) }
    private var title: String { tab?.title ?? session.title }

    var body: some View {
        HStack(spacing: 7) {
            StatusOrb(tone: status.tone.orbTone, size: 9)
            Text(title)
                .font(Aero.font(.callout, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                terminals.requestClose(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(Aero.font(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected || isHovered ? 1 : 0.35)
            .help("Close tab (⌘W)")
            .accessibilityLabel("Close \(title)")
        }
        .foregroundStyle(isSelected ? Aero.text.onAccent : Aero.text.primary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minWidth: 110, maxWidth: 240, alignment: .leading)
        .background {
            Capsule()
                .fill(isSelected ? Aero.aquaDeep : (isHovered || isDropTarget ? Aero.glass.fill : .clear))
        }
        .overlay {
            if isDropTarget {
                Capsule().strokeBorder(Aero.aqua, lineWidth: 1.5)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { terminals.selectedID = session.id }
        .onHover { isHovered = $0 }
        .draggable(session.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            withAnimation(.snappy) { terminals.move(dragged, to: session.id) }
            return true
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            Button("Reconnect", systemImage: "arrow.clockwise") { terminals.reconnect(session.id) }
                .disabled(!terminals.canReconnect(session.id))
            Divider()
            Button("Move Left", systemImage: "arrow.left") { terminals.move(session.id, by: -1) }
            Button("Move Right", systemImage: "arrow.right") { terminals.move(session.id, by: 1) }
            Divider()
            Button("Close Tab", systemImage: "xmark") { terminals.requestClose(session.id) }
        }
        .help("\(session.title) · \(status.text)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.text)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

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
