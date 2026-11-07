import AeroCore
import Observation

/// The app's tabs.
enum MobileSection: Hashable {
    case servers, terminals, files, containers, keys
}

/// A screen pushed in the Servers tab.
enum ServerRoute: Hashable {
    case host(RemoteHost.ID)
    case folder(HostFolder.ID)
}

/// A screen pushed in the Containers tab.
enum ContainersRoute: Hashable {
    case host(RemoteHost.ID)
    case container(RemoteHost.ID, ContainerInfo.ID)
    case inspection(RemoteHost.ID)
    case pod(RemoteHost.ID, PodInfo.ID)
    case describe(RemoteHost.ID)
    case logs(RemoteHost.ID)

    var hostID: RemoteHost.ID {
        switch self {
        case .host(let id), .inspection(let id), .describe(let id), .logs(let id): id
        case .container(let id, _), .pod(let id, _): id
        }
    }
}

/// The selected tab and each tab's stack, so a button in one tab can open a screen in another.
@MainActor
@Observable
final class MobileNavigator {
    var section: MobileSection
    var serverPath: [ServerRoute] = []
    var terminalPath: [MobileTerminal.ID] = []
    var filePath: [RemoteHost.ID] = []
    var containerPath: [ContainersRoute] = []

    init(section: MobileSection = .servers) {
        self.section = section
    }

    /// Pops every folder not in `folders` off the Servers tab: it was deleted, here or
    /// on another device.
    func closeFolders(notIn folders: Set<HostFolder.ID>) {
        serverPath.removeAll { route in
            if case .folder(let id) = route { !folders.contains(id) } else { false }
        }
    }

    func show(terminal id: MobileTerminal.ID) {
        terminalPath = [id]
        section = .terminals
    }

    func showFiles(of id: RemoteHost.ID) {
        filePath = [id]
        section = .files
    }

    /// Pushes the logs just opened on `containers`, without timestamps: they would take most of
    /// a phone's line.
    func pushLogs(of containers: HostContainersModel) {
        containers.logs?.showTimestamps = false
        containerPath.append(.logs(containers.hostID))
    }
}
