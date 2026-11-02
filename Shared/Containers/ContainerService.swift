import AeroCore
import Collectors
import Foundation

/// The Containers views' services: one ``CapabilityCache`` for the app, the Docker, Kubernetes
/// and log collectors, and one ``HostContainersModel`` per host (kept while the host exists, so
/// switching tabs or hosts shows the last data at once).
///
/// The app supplies the runner: the Mac's goes through `SSHRunner` (system `/usr/bin/ssh`,
/// `~/.aeroops/ssh_config` and the in-app agent), the iOS app's is its `EmbeddedSSH` client.
@MainActor
final class ContainerService {
    /// Probe results per host, until the user presses Refresh (or the host's address changes).
    let capabilityCache: CapabilityCache

    private let currentRunner: @MainActor () -> any RemoteCommandRunning
    private let findHost: @MainActor (RemoteHost.ID) -> RemoteHost?
    private let canOpenTerminal: @MainActor (RemoteHost.ID) -> Bool
    private let openTerminal: @MainActor (RemoteHost.ID, String, String) -> Void
    private var hostModels: [RemoteHost.ID: HostContainersModel] = [:]

    /// - Parameters:
    ///   - runner: the current runner, asked each time collectors are made.
    ///   - canOpenTerminal: whether a terminal can run a command on the host.
    ///   - openTerminal: runs a command (host, quoted command, title) in a terminal.
    init(
        runner: @escaping @MainActor () -> any RemoteCommandRunning,
        host: @escaping @MainActor (RemoteHost.ID) -> RemoteHost?,
        canOpenTerminal: @escaping @MainActor (RemoteHost.ID) -> Bool = { _ in false },
        openTerminal: @escaping @MainActor (RemoteHost.ID, String, String) -> Void = { _, _, _ in }
    ) {
        currentRunner = runner
        findHost = host
        self.canOpenTerminal = canOpenTerminal
        self.openTerminal = openTerminal
        capabilityCache = CapabilityCache(runner: runner())
    }

    var runner: any RemoteCommandRunning { currentRunner() }

    var docker: DockerCollector { DockerCollector(runner: runner) }
    var kubernetes: KubernetesCollector { KubernetesCollector(runner: runner) }
    var logs: LogCollector { LogCollector(runner: runner) }

    func host(id: RemoteHost.ID) -> RemoteHost? {
        findHost(id)
    }

    /// The live state of one host's containers and pods, created on first use.
    func model(for hostID: RemoteHost.ID) -> HostContainersModel {
        if let existing = hostModels[hostID] { return existing }
        let created = HostContainersModel(hostID: hostID, service: self)
        hostModels[hostID] = created
        return created
    }

    /// Drops state for deleted hosts and lets edited hosts retry (a new kubectl prefix or docker
    /// sudo setting may fix a permission problem).
    func hostsDidChange(_ hosts: [RemoteHost]) {
        let byID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, model) in hostModels {
            if let host = byID[id] {
                model.hostDidChange(host)
            } else {
                model.stopPresentations()
                hostModels[id] = nil
                let cache = capabilityCache
                Task { await cache.invalidate(id) }
            }
        }
    }

    /// Tells every host model to stop its log follows and close its sheets (e.g. at quit).
    func stopAll() {
        for model in hostModels.values { model.stopPresentations() }
    }

    /// Whether a terminal can be opened for the host (the app decides).
    func canOpenSSH(_ id: RemoteHost.ID) -> Bool {
        canOpenTerminal(id)
    }

    /// Opens a terminal on the host running `remoteCommand` (already quoted by the collectors'
    /// command builders).
    func openSSH(_ id: RemoteHost.ID, remoteCommand: String, title: String) {
        guard canOpenTerminal(id) else { return }
        openTerminal(id, remoteCommand, title)
    }
}
