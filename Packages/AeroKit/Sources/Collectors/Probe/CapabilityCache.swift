import AeroCore
import Foundation
import SSHKit

/// Runs ``RemoteScripts/probe`` once per host and remembers the result until ``refresh(_:)``.
///
/// ```swift
/// let caps = try await cache.capabilities(for: host)   // probes on first use only
/// if caps.dockerNeedsSetup { showDockerPermissionHint() }
/// _ = try await cache.refresh(host)                    // the user pressed Refresh
/// ```
///
/// - Concurrent callers for the same host share one in-flight probe.
/// - Failures are not cached: the next call probes again.
/// - The cache is keyed by host id, but an entry is only reused while the host's address, port
///   and user are unchanged, so editing a host re-probes it.
public actor CapabilityCache {
    /// Runs the probe; `SSHRunner` in the app.
    public nonisolated let runner: any HostCommandRunning
    /// Limit for one probe run (the script itself gives kubectl 3 s).
    public nonisolated let timeout: Duration

    private var entries: [UUID: Entry] = [:]
    private var generation = 0

    public init(runner: any HostCommandRunning, timeout: Duration = .seconds(20)) {
        self.runner = runner
        self.timeout = timeout
    }

    /// The cached capabilities, probing the host first if there are none (or a probe is running).
    ///
    /// - Throws: `SSHError` when ssh fails or the script exits non-zero.
    public func capabilities(for host: RemoteHost) async throws -> HostCapabilities {
        if let entry = entries[host.id], entry.endpoint == Endpoint(host) {
            switch entry.state {
            case .ready(let capabilities): return capabilities
            case .probing(let task, _): return try await task.value
            }
        }
        return try await probe(host)
    }

    /// Probes again, replacing the cached value (and superseding a probe already running).
    @discardableResult
    public func refresh(_ host: RemoteHost) async throws -> HostCapabilities {
        try await probe(host)
    }

    /// The cached value without probing; `nil` when the host was never probed, a probe is still
    /// running, or the host's address, port or user changed since.
    public func cached(for host: RemoteHost) -> HostCapabilities? {
        guard let entry = entries[host.id], entry.endpoint == Endpoint(host),
              case .ready(let capabilities) = entry.state else { return nil }
        return capabilities
    }

    /// Forgets one host (e.g. after it was deleted).
    public func invalidate(_ hostID: UUID) {
        entries[hostID] = nil
    }

    /// Forgets every host.
    public func invalidateAll() {
        entries.removeAll()
    }

    private func probe(_ host: RemoteHost) async throws -> HostCapabilities {
        generation += 1
        let token = generation
        let runner = runner
        let timeout = timeout
        let task = Task { try await Self.runProbe(runner: runner, host: host, timeout: timeout) }
        entries[host.id] = Entry(endpoint: Endpoint(host), state: .probing(task, token: token))
        do {
            let capabilities = try await task.value
            if isCurrent(host.id, token) {
                entries[host.id] = Entry(endpoint: Endpoint(host), state: .ready(capabilities))
            }
            return capabilities
        } catch {
            if isCurrent(host.id, token) { entries[host.id] = nil }
            throw error
        }
    }

    private func isCurrent(_ hostID: UUID, _ token: Int) -> Bool {
        if case .probing(_, let current)? = entries[hostID]?.state { return current == token }
        return false
    }

    private static func runProbe(runner: any HostCommandRunning, host: RemoteHost, timeout: Duration) async throws -> HostCapabilities {
        let result = try await runner.run(
            RemoteScripts.shellCommand, on: host, stdin: Data(RemoteScripts.probe.utf8), timeout: timeout, outputLimit: 16 * 1024
        )
        try result.checked()
        return HostCapabilities(probeOutput: result.stdoutString)
    }

    private struct Endpoint: Hashable {
        var address: String
        var port: Int
        var user: String

        init(_ host: RemoteHost) {
            address = host.address
            port = host.port
            user = host.user
        }
    }

    private enum State {
        case probing(Task<HostCapabilities, any Error>, token: Int)
        case ready(HostCapabilities)
    }

    private struct Entry {
        var endpoint: Endpoint
        var state: State
    }
}
