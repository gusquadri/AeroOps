import AeroCore
import Observation

/// The app's tabs.
enum MobileSection: Hashable, Identifiable, SwitcherTab {
    case servers, terminals, files, containers, keys

    /// The split layout's tab switcher, in the tab bar's order so folding an iPhone Duo keeps
    /// every tab in its place. Keys opens from the sidebar.
    static let switcherTabs: [MobileSection] = [.servers, .terminals, .files, .containers]

    var id: Self { self }

    var title: String {
        switch self {
        case .servers: "Servers"
        case .terminals: "Terminals"
        case .files: "Files"
        case .containers: "Containers"
        case .keys: "Keys"
        }
    }

    var systemImage: String {
        switch self {
        case .servers: "server.rack"
        case .terminals: "terminal"
        case .files: "folder"
        case .containers: "shippingbox"
        case .keys: "key.horizontal"
        }
    }
}

/// A screen pushed in the Servers tab.
enum ServerRoute: Hashable {
    case host(RemoteHost.ID)
    case folder(HostFolder.ID)

    var hostID: RemoteHost.ID? {
        if case .host(let id) = self { id } else { nil }
    }
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
///
/// Both layouts read the same state, so folding or unfolding an iPhone Duo keeps what was shown:
/// in the split layout a tab's stack holds the selected server's screen (the Servers stack is the
/// server's details, the Terminals stack the terminal shown).
@MainActor
@Observable
final class MobileNavigator {
    var section: MobileSection
    var serverPath: [ServerRoute] = []
    var terminalPath: [MobileTerminal.ID] = []
    var filePath: [RemoteHost.ID] = []
    var containerPath: [ContainersRoute] = []
    /// The server the split layout's sidebar selects. Its tabs show this server.
    var selectedHost: RemoteHost.ID?
    /// Keys, a sheet in the split layout.
    var isShowingKeys = false

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
        selectedHost = id
        section = .files
    }

    /// Pushes the logs just opened on `containers`, without timestamps: they would take most of
    /// a phone's line.
    func pushLogs(of containers: HostContainersModel) {
        containers.logs?.showTimestamps = false
        containerPath.append(.logs(containers.hostID))
    }

    /// Moves Keys between its tab (compact) and its sheet (split) when the layout changes.
    func layoutChanged(isSplit: Bool) {
        if isSplit, section == .keys {
            section = .servers
            isShowingKeys = true
        } else if !isSplit, isShowingKeys {
            isShowingKeys = false
            section = .keys
        }
    }

    /// Shows server `id` in the split layout's current tab. On Servers that shows its details
    /// unless `opensDetails` is false (then only details already shown move to it); on Terminals
    /// it shows `terminal`, the server's terminal (nil when it has none open).
    func select(host id: RemoteHost.ID, terminal: MobileTerminal.ID?, opensDetails: Bool = true) {
        selectedHost = id
        switch section {
        case .servers: showDetails(of: id, opening: opensDetails)
        case .files: filePath = [id]
        case .containers: showWorkloads(of: id)
        case .terminals: terminalPath = terminal.map { [$0] } ?? []
        default: break
        }
    }

    /// Shows server `id`'s details over the split layout's folder: Back returns to it.
    func push(host id: RemoteHost.ID) {
        selectedHost = id
        serverPath.append(.host(id))
    }

    private func showDetails(of id: RemoteHost.ID, opening: Bool) {
        if opening || serverPath.last?.hostID != nil { serverPath = [.host(id)] }
    }

    /// Keeps the screens pushed over the server's workloads when it is already shown.
    private func showWorkloads(of id: RemoteHost.ID) {
        if containerPath.first?.hostID != id { containerPath = [.host(id)] }
    }

    /// Switches the split layout to `section`, showing the selected server there, as the Mac's
    /// tabs all show the sidebar's host. `terminal` is as for ``select(host:terminal:opensDetails:)``.
    func open(_ section: MobileSection, terminal: MobileTerminal.ID?) {
        self.section = section
        if let selectedHost {
            select(host: selectedHost, terminal: terminal, opensDetails: false)
        }
    }

    /// Drops the screens of servers and terminals that are gone.
    func prune(hosts: Set<RemoteHost.ID>, terminals: Set<MobileTerminal.ID>) {
        if let id = selectedHost, !hosts.contains(id) { selectedHost = nil }
        serverPath.removeAll { $0.hostID.map { !hosts.contains($0) } ?? false }
        filePath.removeAll { !hosts.contains($0) }
        if let first = containerPath.first, !hosts.contains(first.hostID) { containerPath = [] }
        terminalPath.removeAll { !terminals.contains($0) }
    }
}
