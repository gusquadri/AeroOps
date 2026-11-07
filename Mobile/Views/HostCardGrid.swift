import AeroCore
import AeroTheme
import SwiftUI

/// A grid of host cards: tap one for its details, or its buttons for its files and terminal.
/// Arranging, a card drags onto another to take its place or onto a folder to move in, and a
/// drop on the grid's space puts it last in `folder`. Each card's menu moves it to a folder.
struct HostCardGrid: View {
    let hosts: [RemoteHost]
    /// The folder the grid shows (`nil`: the top level).
    let folder: HostFolder.ID?
    let isArranging: Bool
    /// Shows the details of the host with this ID.
    let onSelect: (RemoteHost.ID) -> Void
    /// Asks for a new folder that the host with this ID moves into.
    let onNewFolder: (RemoteHost.ID) -> Void

    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    /// Why turning a host's monitoring on or off could not be saved.
    @State private var monitoringFailure: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
            ForEach(hosts) { host in
                card(for: host)
                    .contextMenu {
                        MoveToFolderMenu(
                            folders: model.folders,
                            current: model.folderID(ofHost: host.id),
                            onMove: { model.moveHost(host.id, toFolder: $0) },
                            onNewFolder: { onNewFolder(host.id) }
                        )
                    }
                    .hostArranging(.host(host.id), target: .item(.host(host.id)), isEnabled: isArranging, onDrop: { model.arrange($0, on: $1) })
            }
        }
        .hostArranging(nil, target: .end(folder: folder), isEnabled: isArranging, onDrop: { model.arrange($0, on: $1) })
        .alert(
            "Couldn’t save the server",
            isPresented: Binding(get: { monitoringFailure != nil }, set: { if !$0 { monitoringFailure = nil } }),
            presenting: monitoringFailure
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private func toggleMonitoring(_ host: RemoteHost) {
        do {
            try model.setMonitoring(!host.monitored, for: host.id)
        } catch {
            monitoringFailure = error.localizedDescription
        }
    }

    private func card(for host: RemoteHost) -> some View {
        HostCard(
            host: host,
            state: model.displayState(for: host.id),
            canOpenSSH: model.canOpenSession(on: host),
            onOpenSSH: { navigator.show(terminal: model.currentTerminal(on: host.id).id) },
            onBrowseFiles: { navigator.showFiles(of: host.id) },
            keyBlock: model.hostKeyBlock(for: host),
            onReviewKey: { onSelect(host.id) },
            onTrustKey: { Task { await model.requestHostKeyTrust(for: host) } },
            isScanningKey: model.scanningHostIDs.contains(host.id),
            keyScanError: model.scanErrors[host.id],
            onToggleMonitoring: { toggleMonitoring(host) }
        )
        .equatable()
        .contentShape(.rect(cornerRadius: Aero.radius.card))
        .onTapGesture { onSelect(host.id) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the server’s details")
    }
}
