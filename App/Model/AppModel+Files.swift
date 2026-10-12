import AeroCore
import Foundation

extension AppModel {
    /// The Files tab's services (the local pane, SFTP sessions and remote panes per host, the
    /// transfer queue), created on first use and kept for the model's lifetime. Registered as an
    /// inventory observer so deleted hosts are dropped and re-addressed hosts reconnect.
    var fileService: FileService {
        if let existing = FileServiceRegistry.services.object(forKey: self) {
            return existing
        }
        let service = FileService(model: self)
        FileServiceRegistry.services.setObject(service, forKey: self)
        addInventoryObserver(service)
        return service
    }

    /// Shows the host's files in ``AppTab/files``.
    func browseFiles(_ id: RemoteHost.ID) {
        guard host(id: id) != nil else { return }
        selection = id
        selectedTab = .files
    }

    /// Cancels transfers and closes every SFTP session, if the Files tab was ever used.
    func closeFileSessions() {
        FileServiceRegistry.services.object(forKey: self)?.closeAll()
    }
}

/// One ``FileService`` per ``AppModel`` without a stored property on the model (an extension
/// can't add one). Keys are weak, so a released model releases its service.
@MainActor
private enum FileServiceRegistry {
    static let services = NSMapTable<AppModel, FileService>.weakToStrongObjects()
}
