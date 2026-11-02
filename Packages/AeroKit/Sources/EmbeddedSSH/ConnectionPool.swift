import AeroCore
import Foundation

/// Keeps each host's SSH connections open between commands, like SSHKit's ControlMaster: one
/// login, then a session channel per command. A host gets another connection only when its
/// connections' session slots are all taken.
///
/// Concurrent callers share one login: while a connection is being made, the others wait for it
/// rather than start their own (a wrong password then costs one attempt, not one per collector).
actor ConnectionPool {
    /// What a connection was made for. A host whose settings change gets new connections.
    struct Key: Hashable {
        var address: String
        var port: Int
        var user: String
        var auth: HostAuthMethod
        var keyId: String?

        init(_ host: RemoteHost) {
            address = host.address
            port = host.port
            user = host.user
            auth = host.auth
            keyId = host.keyId
        }
    }

    private struct Entry {
        var key: Key
        var generation: UInt64
        var connections: [SSHConnection] = []
        var connecting: Task<Void, any Error>?
    }

    private let connect: @Sendable (RemoteHost) async throws -> SSHConnection
    private var entries: [RemoteHost.ID: Entry] = [:]
    private var generations: UInt64 = 0

    /// - Parameter connect: Makes and logs in one connection; its errors reach every waiter.
    init(connect: @escaping @Sendable (RemoteHost) async throws -> SSHConnection) {
        self.connect = connect
    }

    /// A connection to `host` with a session slot taken for the caller, and whether it was open
    /// before this call (a reused connection may have died without anyone noticing yet).
    func reserve(for host: RemoteHost) async throws -> (connection: SSHConnection, reused: Bool) {
        let key = Key(host)
        var waited = false
        while true {
            try Task.checkCancellation()
            if let entry = entries[host.id], entry.key != key { drop(host.id) }
            var entry = entries[host.id] ?? newEntry(key)
            entry.connections.removeAll { !$0.isActive }
            entries[host.id] = entry
            if let connection = entry.connections.first(where: { $0.reserve() }) {
                return (connection, !waited)
            }
            let connecting = entry.connecting ?? startConnecting(host, generation: entry.generation)
            waited = true
            try await connecting.value
        }
    }

    /// Closes `id`'s connections. Commands running on them fail with a closed connection.
    func disconnect(_ id: RemoteHost.ID) {
        drop(id)
    }

    func disconnectAll() {
        for id in entries.keys { drop(id) }
    }

    /// Closes the connections no command or session is using. Busy ones stay open, and so do
    /// logins still in progress.
    func closeIdle() {
        for id in entries.keys {
            entries[id]?.connections.removeAll { connection in
                guard connection.isIdle else { return false }
                connection.close()
                return true
            }
        }
    }

    private func newEntry(_ key: Key) -> Entry {
        generations += 1
        return Entry(key: key, generation: generations)
    }

    private func startConnecting(_ host: RemoteHost, generation: UInt64) -> Task<Void, any Error> {
        let task = Task {
            defer { if entries[host.id]?.generation == generation { entries[host.id]?.connecting = nil } }
            let connection = try await connect(host)
            if entries[host.id]?.generation == generation {
                entries[host.id]?.connections.append(connection)
            } else {
                connection.close()
            }
        }
        entries[host.id]?.connecting = task
        return task
    }

    private func drop(_ id: RemoteHost.ID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        for connection in entry.connections { connection.close() }
    }
}
