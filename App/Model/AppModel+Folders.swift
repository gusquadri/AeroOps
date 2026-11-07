import AeroCore

extension AppModel: HostLayoutEditing {
    var layoutStore: HostStore { hostStore }

    func layoutDidChange() {
        hostsDidChange()
    }

    /// The folder the Dashboard shows, while it exists.
    var openFolder: HostFolder? { openFolderID.flatMap(hostStore.folder(id:)) }

    /// Where a new host goes: the folder open on the Dashboard while it is shown, else the top level.
    var newHostFolderID: HostFolder.ID? { selectedTab == .dashboard ? openFolder?.id : nil }

    /// Opens the folder name sheet for a new folder, which `host` moves into once it is created.
    func requestNewFolder(moving host: RemoteHost.ID? = nil) {
        folderRequest = .new(moving: host)
    }

    /// Shows the folder holding the host with `id` on the Dashboard, unless a search is shown.
    func showFolder(ofHost id: RemoteHost.ID) {
        guard hostSearch.isEmpty else { return }
        openFolderID = hostStore.folderID(ofHost: id)
    }

    func closeMissingFolder() {
        if openFolderID != nil, openFolder == nil { openFolderID = nil }
        if let folder = folderDeletion, hostStore.folder(id: folder.id) == nil { folderDeletion = nil }
    }
}
