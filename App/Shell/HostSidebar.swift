import AeroCore
import AeroTheme
import SSHKit
import SwiftUI
import TerminalKit

/// The main window's sidebar: every host with its status orb, name and tags, Add Host and
/// update buttons, and a context menu per host. Under each host, its open terminal tabs (click one to
/// show it in Terminals; the Terminals tab has no tab strip of its own) and a New Terminal row.
struct HostSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var deletionCandidate: RemoteHost?
    /// Hosts whose terminals are listed. A host opens when a terminal to it starts opening.
    @State private var expanded: Set<RemoteHost.ID> = []

    var body: some View {
        List(selection: selection) {
            Section("Hosts") {
                ForEach(model.hosts) { host in
                    DisclosureGroup(isExpanded: isExpanded(host.id)) {
                        HostTerminalRows(host: host)
                    } label: {
                        HostRow(host: host, state: model.displayState(for: host.id), keyBlock: model.hostKeyBlock(for: host.id))
                            .contextMenu {
                                HostContextMenu(
                                    host: host,
                                    onEdit: { model.requestEdit(host.id) },
                                    onDelete: { deletionCandidate = host }
                                )
                            }
                    }
                    .tag(SidebarItem.host(host.id))
                }
            }
        }
        .overlay {
            if model.hosts.isEmpty {
                Text("No hosts yet")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                AddHostButton()
                    .help("Add a server to monitor (⌘N)")
                SidebarUpdateButton()
            }
            .frame(maxWidth: .infinity)
            .padding(12)
        }
        .onAppear { expanded.formUnion(hostsWithTerminals) }
        .onChange(of: hostsWithTerminals) { old, new in
            expanded.formUnion(new.subtracting(old))
        }
        .hostDeletionConfirmation($deletionCandidate)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
    }

    /// Hosts with an open terminal or one still checking the host key.
    private var hostsWithTerminals: Set<RemoteHost.ID> {
        let terminals = model.terminals
        return Set(terminals.sessions.compactMap { terminals.tab(for: $0.id)?.hostID })
            .union(terminals.pendingOpens.keys)
    }

    private func isExpanded(_ id: RemoteHost.ID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { open in
                if open { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    /// While Terminals is shown, the row of the shown tab (if its host is the selected one and
    /// open); otherwise the selected host. Picking a terminal shows it in Terminals; picking a
    /// host there shows that host's first tab.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                let terminals = model.terminals
                if model.selectedTab == .terminals, let session = terminals.selectedSession,
                   let hostID = terminals.tab(for: session.id)?.hostID,
                   hostID == model.selection, expanded.contains(hostID) {
                    return .terminal(session.id)
                }
                return model.selection.map(SidebarItem.host)
            },
            set: { item in
                let terminals = model.terminals
                switch item {
                case let .host(id):
                    model.selection = id
                    guard model.selectedTab == .terminals,
                          terminals.selectedSession.flatMap({ terminals.tab(for: $0.id)?.hostID }) != id,
                          let first = terminals.sessions(on: id).first else { return }
                    terminals.selectedID = first.id
                case let .terminal(id):
                    guard let tab = terminals.tab(for: id) else { return }
                    model.selection = tab.hostID
                    terminals.selectedID = id
                    model.selectedTab = .terminals
                case nil:
                    model.selection = nil
                }
            }
        )
    }
}

/// Next to Add Host: checks for a new AeroOps release; Sparkle's window shows the result. A dot
/// marks a release a check found that is not installed or skipped yet, and the arrows turn
/// while a check started here runs. Builds without an update feed (every development build)
/// show it disabled; see ``UpdateService``.
private struct SidebarUpdateButton: View {
    @Environment(\.updateService) private var updates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isChecking = updates?.isChecking ?? false
        let availableVersion = updates?.availableVersion
        Button {
            updates?.checkForUpdates()
        } label: {
            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                .labelStyle(.iconOnly)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isChecking && !reduceMotion)
        }
        .buttonStyle(.aquaSecondary)
        .overlay(alignment: .topTrailing) {
            if availableVersion != nil {
                StatusOrb(tone: .healthy, size: 9)
                    .offset(x: 2, y: -2)
                    .allowsHitTesting(false)
            }
        }
        .disabled(updates?.canCheckForUpdates != true)
        .help(help)
        .accessibilityValue(availableVersion.map { "Version \($0) available" } ?? (isChecking ? "Checking" : ""))
    }

    private var help: String {
        if let updates, updates.status == .running {
            if let version = updates.availableVersion {
                return "AeroOps \(version) is available"
            }
            return updates.isChecking ? "Checking for updates…" : "Check for updates"
        }
        switch updates?.status ?? .notConfigured {
        case .failed(let message):
            return "The updater could not start: \(message)"
        case .idle:
            return "The updater is starting"
        case .notConfigured, .running:
            return "This build has no update feed, so it never checks for updates"
        }
    }
}

/// A row of ``HostSidebar``.
private enum SidebarItem: Hashable {
    case host(RemoteHost.ID)
    case terminal(TerminalSession.ID)
}

/// A host's terminal tabs and its New Terminal row, which shows progress while an open checks
/// the host key.
private struct HostTerminalRows: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost

    var body: some View {
        let terminals = model.terminals
        let isOpening = terminals.isOpening(host.id)
        ForEach(terminals.sessions(on: host.id)) { session in
            SidebarTerminalRow(session: session, tab: terminals.tab(for: session.id))
                .tag(SidebarItem.terminal(session.id))
        }
        Button {
            model.selection = host.id
            model.openSSH(host.id)
        } label: {
            Label {
                Text("New Terminal")
            } icon: {
                if isOpening {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "plus")
                }
            }
            .font(Aero.font(.callout))
            .foregroundStyle(Aero.text.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!model.canOpenSSH(host.id))
        .help(isOpening ? "Checking the host key…" : terminals.unavailableReason(host) ?? "Open an SSH terminal to \(host.name)")
    }
}

/// One terminal tab under its host: its title, then the program's progress and a bell while the
/// tab wants attention (it rang or posted a notification while hidden). The host's orb above
/// stands for its tabs; a tab's own status is in its tooltip. A tab whose surface was freed to
/// save memory is dimmed; its ssh session keeps running.
private struct SidebarTerminalRow: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    let tab: TerminalService.Tab?

    private var status: TerminalService.Status { TerminalService.status(of: session.state) }

    /// The program's own title (e.g. "user@web-01: ~") once it sets one, else the tab's.
    private var title: String {
        guard let tab, session.title == session.spec.title else { return session.title }
        return tab.title
    }

    var body: some View {
        let terminals = model.terminals
        HStack(spacing: 7) {
            Text(title)
                .font(Aero.font(.callout))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(session.isSuspended ? Aero.text.secondary : Aero.text.primary)
            if session.progress != nil || session.needsAttention {
                Spacer(minLength: 4)
            }
            if let progress = session.progress {
                SidebarTerminalProgress(progress: progress)
            }
            if session.needsAttention {
                Image(systemName: "bell.fill")
                    .imageScale(.small)
                    .foregroundStyle(Aero.aquaDeep)
                    .accessibilityHidden(true)
            }
        }
        .help(help)
        // Terminals shows the confirmations and sheets these can lead to.
        .contextMenu {
            Button("Reconnect", systemImage: "arrow.clockwise") {
                model.selectedTab = .terminals
                terminals.reconnect(session.id)
            }
            .disabled(!terminals.canReconnect(session.id))
            Divider()
            Button("Move Up", systemImage: "arrow.up") { terminals.move(session.id, by: -1) }
                .disabled(!terminals.canMove(session.id, by: -1))
            Button("Move Down", systemImage: "arrow.down") { terminals.move(session.id, by: 1) }
                .disabled(!terminals.canMove(session.id, by: 1))
            if let host = tab.flatMap({ model.host(id: $0.hostID) }), terminals.terminfo(for: host)?.hasGhosttyEntry != true {
                Divider()
                Button("Install Terminfo on \(host.name)…", systemImage: "arrow.down.doc") {
                    model.selectedTab = .terminals
                    terminals.requestTerminfoInstall(host.id)
                }
                .disabled(!terminals.canInstallTerminfo(host))
            }
            Divider()
            Button("Close Tab", systemImage: "xmark") {
                model.selectedTab = .terminals
                terminals.requestClose(session.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var help: String {
        var parts = [status.text]
        if let directory = session.workingDirectory {
            parts.append(directory)
        }
        if session.isSuspended {
            parts.append("in the background to save memory")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [title, status.text]
        if let percent = session.progress?.percent {
            parts.append("\(percent)% done")
        } else if session.progress != nil {
            parts.append("in progress")
        }
        if session.needsAttention {
            parts.append("needs attention")
        }
        return parts.joined(separator: ", ")
    }
}

/// A small ring for a tab's progress report: its percentage, or a spinner without one.
private struct SidebarTerminalProgress: View {
    let progress: TerminalProgress

    var body: some View {
        Group {
            if let percent = progress.percent {
                ProgressView(value: Double(percent), total: 100)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.circular)
        .controlSize(.mini)
        .tint(progress.state == .failed ? Aero.coral : progress.state == .paused ? Aero.sun : Aero.aqua)
        .accessibilityHidden(true)
    }
}

/// One host in a list: status orb, name, and tags underneath. A host whose key changed gets a
/// red orb and a "Key changed" tag; hovering shows the old and new fingerprints.
struct HostRow: View {
    let host: RemoteHost
    let state: HostDisplayState
    var keyBlock: HostKeyBlock?

    var body: some View {
        HStack(spacing: 8) {
            StatusOrb(tone: state.orbTone(blocked: keyBlock != nil), size: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                    .font(Aero.font(.body, weight: .medium))
                    .lineLimit(1)
                if let keyBlock {
                    AeroTag("Key changed", systemImage: "exclamationmark.octagon.fill", tint: Aero.coral)
                        .help(keyBlock.helpText)
                }
                if !host.tags.isEmpty {
                    TagRow(tags: host.tags)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(keyBlock == nil ? state.title(blocked: false) : "Blocked: host key changed")
    }
}

#Preview("Sidebar · many hosts") {
    NavigationSplitView {
        HostSidebar()
    } detail: {
        SkyBackground()
    }
    .environment(AppModel.preview())
    .frame(width: 700, height: 500)
}

#Preview("Sidebar · empty") {
    NavigationSplitView {
        HostSidebar()
    } detail: {
        SkyBackground()
    }
    .environment(AppModel.preview(hosts: []))
    .frame(width: 700, height: 500)
}
