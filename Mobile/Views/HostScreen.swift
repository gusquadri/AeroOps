import AeroCore
import SwiftUI

/// One host's details (the Mac inspector's ``HostDetailView``), with Edit, Terminal and Files.
struct HostScreen: View {
    let id: RemoteHost.ID
    /// Pushes the host's terminal or files.
    var open: (MobileRoute) -> Void = { _ in }
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    var body: some View {
        if let host = model.host(id: id) {
            let block = model.hostKeyBlock(for: host)
            HostDetailView(
                host: host,
                state: model.displayState(for: id),
                keyBlock: block,
                onRefresh: { model.refresh(id) },
                onTrustNewKey: { try await model.trust(block?.offered ?? [], for: host, replacingPinned: true) },
                onRecheckKey: { try await model.recheckHostKey(host) },
                onOpenTerminal: { open(.terminal(id)) },
                onBrowseFiles: { open(.files(id)) }
            )
            .refreshable { model.refresh(id) }
            .navigationTitle(host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { isEditing = true }
                }
            }
            .sheet(isPresented: $isEditing) {
                HostEditorScreen(request: .edit(id), onDelete: { dismiss() })
            }
        } else {
            // Deleted while shown.
            AeroEmptyState(systemImage: "server.rack", title: "Server removed", message: "This server is no longer in AeroOps.")
        }
    }
}

#Preview {
    let model = MobileModel.preview()
    NavigationStack {
        HostScreen(id: model.hosts[0].id)
    }
    .environment(model)
}
