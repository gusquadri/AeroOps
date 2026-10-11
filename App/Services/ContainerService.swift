import AeroCore
import Collectors
import Foundation
import SSHKit
import Synchronization

/// The Containers tab's services: one ``CapabilityCache`` for the app, the Docker, Kubernetes
/// and log collectors, and one ``HostContainersModel`` per host (kept while the host exists, so
/// switching tabs or hosts shows the last data at once).
///
/// Everything goes through the app's `SSHRunner` (``SSHServices/runner``): system `/usr/bin/ssh`,
/// `~/.aeroops/ssh_config` and the in-app agent. Get it with ``AppModel/containerService``.
@MainActor
final class ContainerService: HostInventoryObserver {
    let ssh: SSHServices
    /// Probe results per host, until the user presses Refresh (or the host's address changes).
    let capabilityCache: CapabilityCache

    private let runnerBox: ForwardingRunner
    private weak var appModel: AppModel?
    private var hostModels: [RemoteHost.ID: HostContainersModel] = [:]

    init(model: AppModel) {
        ssh = model.ssh
        appModel = model
        runnerBox = ForwardingRunner(model.ssh.runner)
        capabilityCache = CapabilityCache(runner: runnerBox)
    }

    // MARK: - Collectors

    /// The runner for collectors, following the current agent choice (in-app or system agent).
    var runner: any RemoteCommandRunning {
        runnerBox.update(ssh.runner)
        return runnerBox
    }

    var docker: DockerCollector { DockerCollector(runner: runner) }
    var kubernetes: KubernetesCollector { KubernetesCollector(runner: runner) }
    var logs: LogCollector { LogCollector(runner: runner) }

    // MARK: - Hosts

    func host(id: RemoteHost.ID) -> RemoteHost? {
        appModel?.host(id: id)
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

    // MARK: - Terminal

    /// Whether a terminal tab can be opened for the host (the Terminals tab decides).
    func canOpenSSH(_ id: RemoteHost.ID) -> Bool {
        appModel?.canOpenSSH(id) ?? false
    }

    /// Opens a terminal tab on the host running `remoteCommand` (already quoted by the
    /// collectors' command builders).
    func openSSH(_ id: RemoteHost.ID, remoteCommand: String, title: String) {
        guard let appModel, appModel.canOpenSSH(id) else { return }
        appModel.openSSH(id, remoteCommand: remoteCommand, title: title)
    }
}

/// A `RemoteCommandRunning` that forwards to the latest `SSHRunner`, so the capability cache
/// (created once) follows a switch between the in-app and the system agent.
final class ForwardingRunner: RemoteCommandRunning {
    private let current: Mutex<SSHRunner>

    init(_ runner: SSHRunner) {
        current = Mutex(runner)
    }

    func update(_ runner: SSHRunner) {
        current.withLock { $0 = runner }
    }

    private var runner: SSHRunner { current.withLock { $0 } }

    func run(_ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration, outputLimit: Int) async throws -> SSHResult {
        try await runner.run(command, on: host, stdin: stdin, timeout: timeout, outputLimit: outputLimit)
    }

    func stream(
        _ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration?, maxBufferedLines: Int
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try await runner.stream(command, on: host, stdin: stdin, timeout: timeout, maxBufferedLines: maxBufferedLines)
    }
}
