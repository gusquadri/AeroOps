import AeroCore
import Collectors
import Foundation
import SSHKit
import Synchronization

extension ContainerService: HostInventoryObserver {}

extension AppModel {
    /// The Containers tab's services (capability cache, collectors, per-host state), created on
    /// first use and kept for the model's lifetime. Registered as an inventory observer so
    /// deleted hosts are forgotten and edited hosts retry.
    var containerService: ContainerService {
        if let existing = ContainerServiceRegistry.services.object(forKey: self) {
            return existing
        }
        let service = makeContainerService()
        ContainerServiceRegistry.services.setObject(service, forKey: self)
        addInventoryObserver(service)
        return service
    }

    /// The live Containers state of one host.
    func containers(for hostID: RemoteHost.ID) -> HostContainersModel {
        containerService.model(for: hostID)
    }

    private func makeContainerService() -> ContainerService {
        let ssh = ssh
        let box = ForwardingRunner(ssh.runner)
        return ContainerService(
            runner: {
                box.update(ssh.runner)
                return box
            },
            host: { [weak self] in self?.host(id: $0) },
            canOpenTerminal: { [weak self] in self?.canOpenSSH($0) ?? false },
            openTerminal: { [weak self] id, command, title in
                self?.openSSH(id, remoteCommand: command, title: title)
            }
        )
    }
}

/// One ``ContainerService`` per ``AppModel`` without a stored property on the model (an
/// extension can't add one). Keys are weak, so a released model releases its service.
@MainActor
private enum ContainerServiceRegistry {
    static let services = NSMapTable<AppModel, ContainerService>.weakToStrongObjects()
}

/// A `RemoteCommandRunning` that forwards to the latest `SSHRunner`, so the capability cache
/// (created once) follows a switch between the in-app and the system agent.
private final class ForwardingRunner: RemoteCommandRunning {
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
