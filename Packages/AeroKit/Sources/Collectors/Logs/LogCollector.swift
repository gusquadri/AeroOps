import AeroCore
import Foundation

/// Runs an AeroCore `LogRequest`: the single entry point for the Logs sheet and the MCP
/// `get_logs` tool.
///
/// ```swift
/// let logs = LogCollector(runner: sshRunner)
/// let request = LogRequest(hostId: host.id, kind: .pod, name: "crasher-89b4b56b4-djl5b",
///                          namespace: "demo", previous: true)
/// let text = try await logs.fetch(request, on: host)   // CappedText: ANSI-stripped, capped
/// ```
///
/// Requests are validated before anything is sent: every name must pass `ShellQuote.isSafeName`,
/// `sinceSeconds` must be positive, `hostId` must match `host.id`, and `previous` is for pods
/// only. A pod request without a namespace uses `default`; namespace and container are ignored
/// for Docker containers.
public struct LogCollector: Sendable {
    public let docker: DockerCollector
    public let kubernetes: KubernetesCollector

    public init(runner: any RemoteCommandRunning, timeout: Duration = .seconds(30)) {
        self.init(
            docker: DockerCollector(runner: runner, timeout: timeout),
            kubernetes: KubernetesCollector(runner: runner, timeout: timeout)
        )
    }

    public init(docker: DockerCollector, kubernetes: KubernetesCollector) {
        self.docker = docker
        self.kubernetes = kubernetes
    }

    /// The last `request.tail` lines (at most 2,000), ANSI-stripped and capped at 1 MiB, with
    /// `truncated` set when anything was cut. Always a snapshot: `request.follow` is ignored
    /// (use ``follow(_:on:)``).
    ///
    /// - Throws: ``CollectorInputError``, `SSHError`, ``AeroCore/DockerError`` or ``AeroCore/KubectlError``.
    public func fetch(_ request: LogRequest, on host: RemoteHost) async throws -> CappedText {
        try Self.validate(request, on: host)
        switch request.kind {
        case .container:
            return try await docker.logs(
                of: request.name, on: host, tail: request.tail, sinceSeconds: request.sinceSeconds
            )
        case .pod:
            return try await kubernetes.logs(
                pod: request.name, namespace: Self.namespace(of: request), container: request.container,
                previous: request.previous, tail: request.tail, sinceSeconds: request.sinceSeconds, on: host
            )
        }
    }

    /// Follows the logs, starting with the last `request.tail` lines; ANSI-stripped lines until
    /// the consumer cancels. `previous` cannot be followed.
    ///
    /// - Throws: as ``fetch(_:on:)``; the stream itself throws `SSHError`,
    ///   ``AeroCore/DockerError`` or ``AeroCore/KubectlError``.
    public func follow(_ request: LogRequest, on host: RemoteHost) async throws -> AsyncThrowingStream<String, any Error> {
        try Self.validate(request, on: host)
        guard !request.previous else {
            throw CollectorInputError.unsupported("The logs of a previous container instance cannot be followed.")
        }
        switch request.kind {
        case .container:
            return try await docker.followLogs(
                of: request.name, on: host, tail: request.tail, sinceSeconds: request.sinceSeconds
            )
        case .pod:
            return try await kubernetes.followLogs(
                pod: request.name, namespace: Self.namespace(of: request), container: request.container,
                tail: request.tail, sinceSeconds: request.sinceSeconds, on: host
            )
        }
    }

    /// Checks everything that can be checked without the host.
    static func validate(_ request: LogRequest, on host: RemoteHost) throws(CollectorInputError) {
        guard request.hostId == host.id else { throw .hostMismatch }
        switch request.kind {
        case .container:
            try NameCheck.require(request.name, field: "container")
            guard !request.previous else {
                throw .unsupported("Previous-instance logs are only available for Kubernetes pods.")
            }
        case .pod:
            try NameCheck.require(request.name, field: "pod")
            try NameCheck.require(namespace(of: request), field: "namespace")
            if let container = request.container { try NameCheck.require(container, field: "container") }
        }
        try NameCheck.requireSince(request.sinceSeconds)
    }

    static func namespace(of request: LogRequest) -> String {
        request.namespace ?? "default"
    }
}
