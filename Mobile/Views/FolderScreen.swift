import AeroCore
import AeroTheme
import SwiftUI

/// A folder's hosts, in order; long-press a card to drag it into place. The menu adds a host to
/// the folder, renames it or deletes it (its hosts move out).
struct FolderScreen: View {
    let id: HostFolder.ID

    @Environment(MobileModel.self) private var model
    @State private var editor: HostEditorScreen.Request?
    @State private var folderRequest: FolderNameRequest?
    @State private var folderDeletion: HostFolder?

    var body: some View {
        let folder = model.folder(id: id)
        content
            .background { SkyBackground() }
            .navigationTitle(folder?.name ?? "Folder")
            .toolbar {
                if let folder {
                    ToolbarItem(placement: .primaryAction) { menu(for: folder) }
                }
            }
            .sheet(item: $editor) { HostEditorScreen(request: $0) }
            .folderNameSheet($folderRequest) { try model.saveFolder($0, name: $1) }
            .folderDeletionConfirmation($folderDeletion) { model.deleteFolder($0) }
    }

    @ViewBuilder
    private var content: some View {
        let hosts = model.hosts(inFolder: id)
        if hosts.isEmpty {
            AeroEmptyState(
                systemImage: "folder",
                title: "No servers in this folder",
                message: "Add a server here, or long-press one on the Servers screen and choose Move to Folder."
            ) {
                Button("Add Host", systemImage: "plus") { editor = .newIn(id) }
                    .buttonStyle(.aqua)
            }
        } else {
            ScrollView {
                HostCardGrid(hosts: hosts, folder: id, isArranging: true) { folderRequest = .new(moving: $0) }
                    .padding(16)
            }
            .refreshable { model.refreshAll() }
        }
    }

    private func menu(for folder: HostFolder) -> some View {
        Menu("Folder", systemImage: "ellipsis") {
            Button("Add Host", systemImage: "plus") { editor = .newIn(folder.id) }
            Button("Rename…", systemImage: "pencil") { folderRequest = .rename(folder) }
            Button("Delete Folder…", systemImage: "trash", role: .destructive) { folderDeletion = folder }
        }
    }
}
