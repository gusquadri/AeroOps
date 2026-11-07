import AeroCore

/// A model that lets the user arrange hosts into folders and reorder them: ``AppModel`` and
/// ``MobileModel``. Each change is saved to ``layoutStore`` and then reported with
/// ``layoutDidChange()``; drags and menu actions that fail set ``layoutError``.
@MainActor
protocol HostLayoutEditing: AnyObject {
    var layoutStore: HostStore { get }
    var layoutError: HostStoreError? { get set }
    func layoutDidChange()
}

extension HostLayoutEditing {
    /// The host folders, in order.
    var folders: [HostFolder] { layoutStore.folders }

    func folder(id: HostFolder.ID) -> HostFolder? {
        layoutStore.folder(id: id)
    }

    /// The hosts in the folder with `id` (`nil`: in none), in order.
    func hosts(inFolder id: HostFolder.ID?) -> [RemoteHost] {
        layoutStore.hosts(inFolder: id)
    }

    func folderID(ofHost id: RemoteHost.ID) -> HostFolder.ID? {
        layoutStore.folderID(ofHost: id)
    }

    /// Creates or renames the folder for `request`; a new folder takes the host it names.
    func saveFolder(_ request: FolderNameRequest, name: String) throws(HostStoreError) {
        switch request {
        case .new(let moving):
            let folder = try layoutStore.addFolder(named: name)
            if let moving { try layoutStore.moveHost(moving, toFolder: folder.id) }
        case .rename(let folder):
            try layoutStore.renameFolder(id: folder.id, to: name)
        }
        layoutDidChange()
    }

    /// Deletes `folder`; its hosts move to the end of the top level.
    func deleteFolder(_ folder: HostFolder) {
        record { () throws(HostStoreError) in try layoutStore.deleteFolder(id: folder.id) }
    }

    /// Moves the host with `id` last into the folder with `folder` (`nil`: out of every folder).
    func moveHost(_ id: RemoteHost.ID, toFolder folder: HostFolder.ID?) {
        record { () throws(HostStoreError) in try layoutStore.moveHost(id, toFolder: folder) }
    }

    /// Applies a drag and drop of a host or folder.
    func arrange(_ item: HostLayoutItem, on target: HostLayoutTarget) {
        record { () throws(HostStoreError) in _ = try layoutStore.drop(item, on: target) }
    }

    private func record(_ change: () throws(HostStoreError) -> Void) {
        do {
            try change()
        } catch {
            layoutError = error
        }
        layoutDidChange()
    }
}
