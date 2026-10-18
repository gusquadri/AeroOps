import AeroCore
import Foundation
import Observation
import SSHKit

/// A host's SFTP sessions: one for browsing and one for transfers, so a big copy never queues
/// in front of a folder listing. Both connect on first use and reconnect after the connection
/// drops. The connector decides how: on the Mac `ssh -s … sftp`, where the second session rides
/// on the first's ControlMaster connection; on iOS an EmbeddedSSH channel, where both share the
/// client's pooled connection.
@MainActor
@Observable
final class RemoteFileSession {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed
    }

    enum Role {
        case browse
        case transfer
    }

    private(set) var host: RemoteHost
    /// The browsing session's state, for the pane header.
    private(set) var status: Status = .idle

    @ObservationIgnored private let connector: @MainActor (RemoteHost) async throws -> SFTPClient
    @ObservationIgnored private var clients: [Role: SFTPClient] = [:]
    @ObservationIgnored private var pending: [Role: Task<SFTPClient, any Error>] = [:]
    /// Bumped by ``disconnect()``, so a connection finishing afterwards is dropped.
    @ObservationIgnored private var generation = 0

    init(host: RemoteHost, connector: @escaping @MainActor (RemoteHost) async throws -> SFTPClient) {
        self.host = host
        self.connector = connector
    }

    /// The session for `role`, connecting (or reconnecting) if needed.
    func client(_ role: Role = .browse) async throws -> SFTPClient {
        if let client = clients[role] {
            if await client.isConnected { return client }
            if clients[role] === client { clients[role] = nil }
        }
        if let task = pending[role] {
            return try await task.value
        }
        let token = generation
        let task = Task { [host, connector] in try await connector(host) }
        pending[role] = task
        if role == .browse { status = .connecting }
        do {
            let client = try await task.value
            guard token == generation else {
                client.disconnect()
                throw CancellationError()
            }
            pending[role] = nil
            clients[role] = client
            if role == .browse { status = .connected }
            return client
        } catch {
            if token == generation {
                pending[role] = nil
                if role == .browse { status = .failed }
            }
            throw error
        }
    }

    /// Takes the edited host; a new address, user or login closes the sessions so the next
    /// request connects with it.
    func update(_ host: RemoteHost) {
        let old = self.host
        self.host = host
        if host.address != old.address || host.port != old.port || host.user != old.user
            || host.keyId != old.keyId || host.auth != old.auth {
            disconnect()
        }
    }

    /// Ends both sessions; running requests and transfers fail.
    func disconnect() {
        generation += 1
        for client in clients.values { client.disconnect() }
        for task in pending.values { task.cancel() }
        clients = [:]
        pending = [:]
        status = .idle
    }
}
