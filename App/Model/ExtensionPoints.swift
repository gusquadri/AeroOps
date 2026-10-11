import AeroCore

/// Reacts to host inventory changes. Register with ``AppModel/addInventoryObserver(_:)``.
///
/// Planned observers: SSHKit regenerating `~/.aeroops/ssh_config` (Phase 2) and Collectors
/// starting, restarting and stopping one `HostMonitor` actor per host (Phase 3). Observers
/// receive the full list and diff it themselves; work that leaves the main actor should hop
/// to the observer's own actor.
@MainActor
protocol HostInventoryObserver: AnyObject {
    /// Called once on registration and after every successful add, update, delete or reload.
    func hostsDidChange(_ hosts: [RemoteHost])
}

/// A key the host editor's key picker can offer. Only an identifier and labels: key material
/// never leaves KeyAgent.
///
/// Phase 2 fills ``AppModel/availableKeys`` from KeyAgent's key store; until then the picker
/// shows "None" and keeps any `keyId` already in `hosts.json`.
struct KeySummary: Identifiable, Hashable, Sendable {
    /// The KeyAgent key identifier stored in ``RemoteHost/keyId``.
    var id: String
    /// Display name, e.g. "MacBook Secure Enclave".
    var name: String
    /// Secondary line, e.g. "ecdsa-sha2-nistp256 · SHA256:…".
    var detail: String
}

/// What the main window's host editor sheet is editing.
enum HostEditorRequest: Identifiable, Hashable {
    case new
    case edit(RemoteHost.ID)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let hostID): hostID.uuidString
        }
    }
}
