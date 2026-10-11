import AeroCore

extension AppModel {
    /// Opens a terminal tab on the host that runs `remoteCommand` (e.g. `docker logs -f …`).
    ///
    /// Temporary stub so the Containers tab compiles on its own; replaced at merge by the
    /// Terminals tab's implementation (same signature), which creates the TerminalKit session.
    func openSSH(_ id: RemoteHost.ID, remoteCommand: String, title: String? = nil) {
        selectedTab = .terminals
    }
}
