import AeroCore
import AeroTheme
import SwiftUI

/// Settings › Hosts: the host list with + / − / import on the left and the editor for the
/// selected host (or a new one) on the right.
struct HostsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: RemoteHost.ID?
    @State private var isCreating = false
    @State private var deletionCandidate: RemoteHost?
    @State private var isImporting = false

    var body: some View {
        HStack(spacing: 0) {
            hostList
                .frame(width: 230)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The plain sky gradient: bubbles and ribbons would sit behind form text.
        .background { Aero.sky.gradient.ignoresSafeArea() }
        .hostDeletionConfirmation($deletionCandidate)
        .sshConfigImportSheet(isPresented: $isImporting) { ids in
            isCreating = false
            selection = ids.first
        }
        .onAppear {
            if selection == nil { selection = model.selection ?? model.hosts.first?.id }
        }
        .onChange(of: selection) {
            if selection != nil { isCreating = false }
        }
    }

    private var hostList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.hosts) { host in
                    HostRow(host: host, state: model.displayState(for: host.id), keyBlock: model.hostKeyBlock(for: host.id))
                        .contextMenu {
                            HostContextMenu(
                                host: host,
                                onEdit: { selection = host.id },
                                onDelete: { deletionCandidate = host }
                            )
                        }
                }
                if isCreating {
                    Label("New Host", systemImage: "plus.circle")
                        .font(Aero.font(.body, weight: .medium))
                        .foregroundStyle(Aero.text.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if model.hosts.isEmpty, !isCreating {
                    Text("No hosts")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                }
            }
            Divider()
            HStack(spacing: 2) {
                Button("Add Host", systemImage: "plus", action: startCreating)
                    .help("Add a host")
                Button("Delete Host", systemImage: "minus") {
                    deletionCandidate = selection.flatMap { model.host(id: $0) }
                }
                .help("Delete the selected host")
                .disabled(selection == nil)
                Spacer()
                Button("Import from ~/.ssh/config…", systemImage: "square.and.arrow.down") { isImporting = true }
                    .help("Import hosts from ~/.ssh/config")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.aquaSecondary)
            .controlSize(.small)
            .padding(10)
        }
        .aeroGlass(in: Rectangle(), shadow: nil)
    }

    @ViewBuilder
    private var editor: some View {
        if isCreating {
            HostEditorForm(
                original: nil,
                onSave: { (host: RemoteHost) throws(HostStoreError) in
                    try model.addHost(host)
                    isCreating = false
                    selection = host.id
                },
                onCancel: { isCreating = false }
            )
            .id("new")
        } else if let id = selection, let host = model.host(id: id) {
            HostEditorForm(
                original: host,
                onSave: { (host: RemoteHost) throws(HostStoreError) in try model.updateHost(host) },
                onDelete: { deletionCandidate = host }
            )
            .id(host.id)
        } else {
            AeroEmptyState(
                systemImage: "server.rack",
                title: model.hosts.isEmpty ? "No hosts yet" : "Select a host",
                message: model.hosts.isEmpty
                    ? "Add the servers you want to monitor. AeroOps reaches them over SSH; nothing is installed on them."
                    : "Choose a host on the left to edit it, or add a new one."
            ) {
                HStack(spacing: 8) {
                    Button("Add Host", systemImage: "plus", action: startCreating)
                        .buttonStyle(.aqua)
                    if model.hosts.isEmpty {
                        Button("Import from ~/.ssh/config…", systemImage: "square.and.arrow.down") { isImporting = true }
                            .buttonStyle(.aquaSecondary)
                    }
                }
            }
        }
    }

    private func startCreating() {
        selection = nil
        isCreating = true
    }
}

#Preview("Hosts pane · many") {
    HostsSettingsPane()
        .environment(AppModel.preview())
        .frame(width: 780, height: 600)
}

#Preview("Hosts pane · empty") {
    HostsSettingsPane()
        .environment(AppModel.preview(hosts: []))
        .frame(width: 780, height: 600)
}
