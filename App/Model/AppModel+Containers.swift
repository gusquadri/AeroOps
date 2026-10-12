import AeroCore
import Foundation

extension AppModel {
    /// The Containers tab's services (capability cache, collectors, per-host state), created on
    /// first use and kept for the model's lifetime. Registered as an inventory observer so
    /// deleted hosts are forgotten and edited hosts retry.
    var containerService: ContainerService {
        if let existing = ContainerServiceRegistry.services.object(forKey: self) {
            return existing
        }
        let service = ContainerService(model: self)
        ContainerServiceRegistry.services.setObject(service, forKey: self)
        addInventoryObserver(service)
        return service
    }

    /// The live Containers state of one host.
    func containers(for hostID: RemoteHost.ID) -> HostContainersModel {
        containerService.model(for: hostID)
    }
}

/// One ``ContainerService`` per ``AppModel`` without a stored property on the model (an
/// extension can't add one). Keys are weak, so a released model releases its service.
@MainActor
private enum ContainerServiceRegistry {
    static let services = NSMapTable<AppModel, ContainerService>.weakToStrongObjects()
}
