import AeroCore
import AeroTheme
import SwiftUI

/// Context menu items for a host in the sidebar or a list: Edit, Open SSH and Browse Files
/// (disabled while ``AppModel/canOpenSSH(_:)`` is false), Delete.
struct HostContextMenu: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("Edit…", systemImage: "pencil", action: onEdit)
        Button("Open SSH", systemImage: "terminal") { model.openSSH(host.id) }
            .disabled(!model.canOpenSSH(host.id))
        Button("Browse Files", systemImage: "folder") { model.browseFiles(host.id) }
            .disabled(!model.canOpenSSH(host.id))
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

extension View {
    /// Asks before deleting `host` (set it to start), then deletes it through ``AppModel`` and
    /// shows an alert if saving fails.
    func hostDeletionConfirmation(_ host: Binding<RemoteHost?>) -> some View {
        modifier(HostDeletionConfirmation(candidate: host))
    }
}

private struct HostDeletionConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var candidate: RemoteHost?
    @State private var failure: HostStoreError?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete “\(candidate?.name ?? "")”?",
                isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }),
                presenting: candidate
            ) { host in
                Button("Delete", role: .destructive) { delete(host) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("AeroOps forgets this host and its settings. Nothing changes on the server, and your keys are kept.")
            }
            .alert(
                "Couldn’t delete the host",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: failure
            ) { _ in
                Button("OK") {}
            } message: { error in
                Text(error.localizedDescription)
            }
    }

    private func delete(_ host: RemoteHost) {
        do {
            try model.deleteHost(id: host.id)
        } catch {
            failure = error
        }
    }
}

/// Shown above the content when the hosts or pinned host keys could not be loaded, with a Reload button.
struct HostLoadErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.hostStore.loadError?.localizedDescription ?? model.ssh.hostKeyError {
            AeroCard(padding: 12) {
                HStack(spacing: 10) {
                    StatusOrb(tone: .warning)
                    Text(error)
                        .font(Aero.font(.callout))
                        .lineLimit(3)
                    Spacer(minLength: 8)
                    Button("Reload") { model.reloadHosts() }
                        .buttonStyle(.aquaSecondary)
                        .controlSize(.small)
                }
            }
            .padding([.horizontal, .top], 16)
        }
    }
}
