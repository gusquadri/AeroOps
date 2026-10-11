import AeroCore
import AeroTheme
import SSHKit
import SwiftUI

/// The main window's sidebar: every host with its status orb, name and tags, an Add Host
/// button, and a context menu per host.
struct HostSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var deletionCandidate: RemoteHost?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Hosts") {
                ForEach(model.hosts) { host in
                    HostRow(host: host, state: model.displayState(for: host.id), keyBlock: model.hostKeyBlock(for: host.id))
                        .contextMenu {
                            HostContextMenu(
                                host: host,
                                onEdit: { model.requestEdit(host.id) },
                                onDelete: { deletionCandidate = host }
                            )
                        }
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
            AddHostButton()
                .frame(maxWidth: .infinity)
                .padding(12)
                .help("Add a server to monitor (⌘N)")
        }
        .hostDeletionConfirmation($deletionCandidate)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
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
