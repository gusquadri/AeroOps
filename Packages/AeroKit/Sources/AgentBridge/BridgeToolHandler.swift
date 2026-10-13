import AeroCore
import BridgeProtocol
import Foundation

/// A host and its current monitoring status.
public struct BridgeHostState: Sendable, Hashable {
    public var host: RemoteHost
    public var status: HostStatus

    public init(host: RemoteHost, status: HostStatus) {
        self.host = host
        self.status = status
    }
}

/// The app's data, as the bridge needs it for the read tools. The app implements this on top
/// of its host store and collectors; the bridge never talks to collectors itself.
///
/// The bridge has already validated the arguments, resolved the host and applied the policy
/// before any of these methods is called, so implementations only fetch data. Throw
/// ``BridgeHandlerError`` for expected failures (its message goes to the agent); any other
/// error becomes a generic failure. `run_command` does not go through the handler: the bridge
/// runs it with its ``CommandExecutor``.
public protocol BridgeToolHandler: Sendable {
    /// Every configured host, Off ones included (the bridge filters them out).
    func hosts() async -> [BridgeHostState]
    /// The latest metrics sample. Throw ``BridgeHandlerError/unavailable(_:)`` when there is none yet.
    func metrics(for host: RemoteHost) async throws -> MetricsSnapshot
    /// Docker containers; stopped ones only when `includeStopped`.
    func containers(on host: RemoteHost, includeStopped: Bool) async throws -> [ContainerInfo]
    /// Kubernetes pods; all namespaces when `namespace` is `nil`.
    func pods(on host: RemoteHost, namespace: String?) async throws -> [PodInfo]
    /// Log text for a validated request (never `follow`). The bridge strips escapes and caps it.
    func logs(_ request: LogRequest, on host: RemoteHost) async throws -> String
}

/// Expected failures of a ``BridgeToolHandler``; the message is shown to the agent.
public enum BridgeHandlerError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The data is not available right now ("No metrics yet for this host.").
    case unavailable(String)
    /// The host does not support it ("Docker is not installed on this host.").
    case notSupported(String)
    /// ssh failed while fetching it.
    case sshFailed(String)

    public var description: String {
        switch self {
        case .unavailable(let message), .notSupported(let message), .sshFailed(let message): message
        }
    }

    var bridgeError: BridgeError {
        switch self {
        case .unavailable(let message), .notSupported(let message): BridgeError(code: .unavailable, message: message)
        case .sshFailed(let message): BridgeError(code: .sshFailed, message: message)
        }
    }
}

/// Finds the host an agent means by its `host` argument.
public enum HostResolver {
    public enum Failure: Error, Sendable, Hashable {
        case notFound(String)
        case ambiguous(String, count: Int)

        public var bridgeError: BridgeError {
            switch self {
            case .notFound(let query):
                BridgeError(code: .hostNotFound, message: "No host matches \(String(reflecting: query)). Call list_hosts for the available hosts.")
            case .ambiguous(let query, let count):
                BridgeError(code: .hostNotFound,
                            message: "\(String(reflecting: query)) matches \(count) hosts. Use the host's id from list_hosts.")
            }
        }
    }

    /// Matches, in order: id, exact name, case-insensitive name, SSH alias (`aero-<id>`), and an
    /// address that only one host has. Off hosts are matched too (the policy then refuses them
    /// with "not shared with agents").
    public static func resolve(_ query: String, in hosts: [RemoteHost]) -> Result<RemoteHost, Failure> {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: trimmed), let host = hosts.first(where: { $0.id == id }) {
            return .success(host)
        }
        let exact = hosts.filter { $0.name == trimmed }
        if exact.count == 1 { return .success(exact[0]) }
        if exact.count > 1 { return .failure(.ambiguous(trimmed, count: exact.count)) }
        let folded = hosts.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if folded.count == 1 { return .success(folded[0]) }
        if folded.count > 1 { return .failure(.ambiguous(trimmed, count: folded.count)) }
        if let host = hosts.first(where: { "aero-" + $0.id.uuidString.lowercased() == trimmed.lowercased() }) {
            return .success(host)
        }
        let byAddress = hosts.filter { $0.address.caseInsensitiveCompare(trimmed) == .orderedSame }
        if byAddress.count == 1 { return .success(byAddress[0]) }
        if byAddress.count > 1 { return .failure(.ambiguous(trimmed, count: byAddress.count)) }
        return .failure(.notFound(trimmed))
    }
}
