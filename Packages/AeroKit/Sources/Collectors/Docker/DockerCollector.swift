import AeroCore
import Foundation
import SSHKit

/// Lists containers, reads and follows their logs, and inspects them over ssh.
///
/// Uses the host's `dockerSudo` setting (`sudo -n docker`). Errors:
/// - ``CollectorInputError`` before anything is sent (unsafe container name, bad `since`);
/// - `SSHError` when ssh itself fails (auth, timeout, unreachable);
/// - ``AeroCore/DockerError`` when docker fails, with a user-facing `hint`
///   (`.permissionDenied` suggests the docker group or the `sudo -n` toggle).
public struct DockerCollector: Sendable {
    /// `SSHRunner` in the app.
    public let runner: any RemoteCommandRunning
    /// Limit for one list, logs or inspect run.
    public var timeout: Duration
    /// Default lines for ``followLogs(of:on:tail:sinceSeconds:)`` (`--tail 100`).
    public static let defaultFollowTail = 100

    static let listOutputLimit = 16 << 20
    static let logsOutputLimit = 8 << 20
    static let inspectOutputLimit = 4 << 20
    static let actionOutputLimit = 64 << 10
    /// Limit for a stop, restart or remove: `docker stop` waits for the container's stop
    /// timeout (10 s by default, often more in Compose files) before it kills it.
    public static let actionTimeout = Duration.seconds(120)

    public init(runner: any RemoteCommandRunning, timeout: Duration = .seconds(30)) {
        self.runner = runner
        self.timeout = timeout
    }

    /// `docker ps` merged with `docker stats` (one ssh round trip). Running containers carry CPU
    /// and memory; stopped ones have `nil`. If only `docker stats` fails, rows come back without it.
    public func containers(on host: RemoteHost, includeStopped: Bool = true) async throws -> [ContainerInfo] {
        let command = DockerCommands.list(includeStopped: includeStopped, sudo: host.dockerSudo)
        let result = try await runner.run(command, on: host, stdin: nil, timeout: timeout, outputLimit: Self.listOutputLimit)
        try Self.check(result)
        let parts = DockerCommands.splitListOutput(result.stdoutString)
        return try DockerParser.parseContainers(ps: parts.ps, stats: parts.stats)
    }

    /// The last `tail` lines (clamped to `1...2000`), ANSI-stripped and capped by
    /// `LogText.prepare` (2,000 lines, 1 MiB). `truncated` is set when anything was cut.
    public func logs(
        of container: String,
        on host: RemoteHost,
        tail: Int = LogRequest.defaultTail,
        sinceSeconds: Int? = nil
    ) async throws -> CappedText {
        let command = try DockerCommands.logs(
            container: container, tail: max(1, tail), sinceSeconds: sinceSeconds, sudo: host.dockerSudo
        )
        let result = try await runner.run(command, on: host, stdin: nil, timeout: timeout, outputLimit: Self.logsOutputLimit)
        try Self.check(result)
        let prepared = LogText.prepare(result.stdoutString)
        return CappedText(text: prepared.text, truncated: prepared.truncated || result.stdoutTruncated)
    }

    /// Follows the logs (`docker logs -f --tail 100 --timestamps <name> 2>&1`), yielding
    /// ANSI-stripped lines until cancelled. Cancel the consuming task (or release the stream;
    /// breaking out of the loop while still holding it is not enough) to stop: the local ssh
    /// process is killed and the remote `docker logs -f` exits within a few seconds even when
    /// the container is quiet.
    ///
    /// The stream throws ``AeroCore/DockerError`` if `docker logs` exits non-zero (its last
    /// output lines, which carry the error, have been yielded as lines first).
    public func followLogs(
        of container: String,
        on host: RemoteHost,
        tail: Int = DockerCollector.defaultFollowTail,
        sinceSeconds: Int? = nil
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let command = try DockerCommands.logs(
            container: container, tail: tail, sinceSeconds: sinceSeconds, follow: true, sudo: host.dockerSudo
        )
        return try await LogFollowStream.start(command, on: host, runner: runner) { DockerError.classify($0) }
    }

    /// `docker inspect` for one container.
    ///
    /// - Throws: ``AeroCore/DockerError`` (`.failed` with docker's message for an unknown container).
    public func inspect(_ container: String, on host: RemoteHost) async throws -> DockerInspection {
        let command = try DockerCommands.inspect(container: container, sudo: host.dockerSudo)
        let result = try await runner.run(command, on: host, stdin: nil, timeout: timeout, outputLimit: Self.inspectOutputLimit)
        try Self.check(result)
        guard !result.stdoutTruncated, let summary = DockerParser.parseInspect(result.stdout).first else {
            throw DockerError.failed(message: "docker inspect returned no readable container for \(container).")
        }
        return DockerInspection(summary: summary, json: result.stdout)
    }

    /// Stops, restarts or removes one container (by name or ID).
    ///
    /// - Throws: ``CollectorInputError`` for an unsafe name, `SSHError`, or
    ///   ``AeroCore/DockerError`` (`.failed` with docker's message for an unknown container).
    public func perform(_ action: DockerContainerAction, on container: String, host: RemoteHost) async throws {
        let command = try DockerCommands.action(action, container: container, sudo: host.dockerSudo)
        let result = try await runner.run(
            command, on: host, stdin: nil, timeout: max(timeout, Self.actionTimeout), outputLimit: Self.actionOutputLimit
        )
        try Self.check(result)
    }

    /// Throws `SSHError` for transport failures, ``AeroCore/DockerError`` for a non-zero exit.
    static func check(_ result: SSHResult) throws {
        try RemoteShell.requireTransport(result)
        guard result.exitCode == 0 else { throw DockerError.classify(RemoteShell.errorText(result)) }
    }
}

/// The result of ``DockerCollector/inspect(_:on:)``.
public struct DockerInspection: Sendable, Hashable {
    /// The fields the Containers tab shows.
    public var summary: DockerInspectSummary
    /// The raw `docker inspect` JSON array, for the detail view only.
    ///
    /// It includes `Config.Env`, which often holds passwords and tokens: never log it, write it
    /// to disk, or return it from an MCP tool.
    public var json: Data

    public init(summary: DockerInspectSummary, json: Data) {
        self.summary = summary
        self.json = json
    }
}
