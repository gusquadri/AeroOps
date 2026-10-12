import AeroCore
import Foundation
import SSHKit

/// Lists pods, reads and follows their logs, and fetches describe output and events over ssh.
///
/// Uses the host's kubectl prefix (``KubectlPrefix``; e.g. `sudo -n k3s kubectl` on k3s, whose
/// kubeconfig is root-only). Errors:
/// - ``CollectorInputError`` before anything is sent (bad prefix, unsafe name, bad `since`);
/// - `SSHError` when ssh itself fails;
/// - ``AeroCore/KubectlError`` when kubectl fails, with a user-facing `hint`
///   (`.kubeconfigUnreadable` suggests the k3s prefix, `.sudoRefused` a NOPASSWD rule).
public struct KubernetesCollector: Sendable {
    /// `SSHRunner` in the app.
    public let runner: any RemoteCommandRunning
    /// Limit for one pods, logs, describe or events run.
    public var timeout: Duration

    static let podsOutputLimit = 64 << 20
    static let logsOutputLimit = 8 << 20
    static let describeOutputLimit = 2 << 20
    static let eventsOutputLimit = 16 << 20

    public init(runner: any RemoteCommandRunning, timeout: Duration = .seconds(30)) {
        self.runner = runner
        self.timeout = timeout
    }

    /// `kubectl get pods -A -o json` (or one namespace) merged with the metrics API (one ssh
    /// round trip), parsed to the fields the plan lists. Running pods carry CPU and memory use
    /// when the cluster has metrics-server; otherwise the pods come back without it.
    public func pods(on host: RemoteHost, namespace: String? = nil) async throws -> [PodInfo] {
        let command = try KubectlCommands(host: host).pods(namespace: namespace)
        let result = try await run(command, on: host, outputLimit: Self.podsOutputLimit)
        guard !result.stdoutTruncated else { throw KubectlError.invalidOutput }
        let parts = KubectlCommands.splitPodsOutput(result.stdout)
        return try KubernetesParser.parsePods(parts.pods, metrics: parts.metrics)
    }

    /// The last `tail` lines (clamped to `1...2000`) of one container, ANSI-stripped and capped
    /// by `LogText.prepare` (2,000 lines, 1 MiB).
    ///
    /// - Parameters:
    ///   - container: `nil` lets kubectl pick the pod's default container.
    ///   - previous: the crashed previous instance (`--previous`); throws
    ///     ``AeroCore/KubectlError/noPreviousContainer(container:pod:)`` if it never restarted.
    public func logs(
        pod: String,
        namespace: String,
        container: String? = nil,
        previous: Bool = false,
        tail: Int = LogRequest.defaultTail,
        sinceSeconds: Int? = nil,
        on host: RemoteHost
    ) async throws -> CappedText {
        let command = try KubectlCommands(host: host).logs(
            pod: pod, namespace: namespace, container: container, previous: previous,
            tail: max(1, tail), sinceSeconds: sinceSeconds
        )
        let result = try await run(command, on: host, outputLimit: Self.logsOutputLimit)
        let prepared = LogText.prepare(result.stdoutString)
        return CappedText(text: prepared.text, truncated: prepared.truncated || result.stdoutTruncated)
    }

    /// Follows one container's logs (`kubectl logs -f ... --tail=100 --timestamps`), yielding
    /// ANSI-stripped lines until cancelled. Cancel the consuming task (or release the stream;
    /// breaking out of the loop while still holding it is not enough) to stop; the remote
    /// kubectl exits within a few seconds even when the pod is quiet.
    /// The stream throws ``AeroCore/KubectlError`` if kubectl exits non-zero.
    public func followLogs(
        pod: String,
        namespace: String,
        container: String? = nil,
        tail: Int = DockerCollector.defaultFollowTail,
        sinceSeconds: Int? = nil,
        on host: RemoteHost
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let command = try KubectlCommands(host: host).logs(
            pod: pod, namespace: namespace, container: container,
            tail: tail, sinceSeconds: sinceSeconds, follow: true
        )
        return try await LogFollowStream.start(command, on: host, runner: runner) { KubectlError.classify($0) }
    }

    /// `kubectl describe pod`, ANSI-stripped and capped at 1 MiB (the head is kept).
    public func describe(pod: String, namespace: String, on host: RemoteHost) async throws -> CappedText {
        let command = try KubectlCommands(host: host).describe(pod: pod, namespace: namespace)
        let result = try await run(command, on: host, outputLimit: Self.describeOutputLimit)
        let capped = LogText.capBytes(LogText.stripANSI(result.stdoutString), keep: .head)
        return CappedText(text: capped.text, truncated: capped.truncated || result.stdoutTruncated)
    }

    /// The pod's events (`--field-selector involvedObject.name=<pod>`), oldest first by last seen.
    public func events(pod: String, namespace: String, on host: RemoteHost) async throws -> [PodEvent] {
        let command = try KubectlCommands(host: host).events(pod: pod, namespace: namespace)
        let result = try await run(command, on: host, outputLimit: Self.eventsOutputLimit)
        guard !result.stdoutTruncated else { throw KubectlError.invalidOutput }
        return try KubernetesParser.parseEvents(result.stdout)
    }

    /// Runs `command`; throws `SSHError` for transport failures, ``AeroCore/KubectlError`` for a
    /// non-zero exit.
    private func run(_ command: String, on host: RemoteHost, outputLimit: Int) async throws -> SSHResult {
        let result = try await runner.run(command, on: host, stdin: nil, timeout: timeout, outputLimit: outputLimit)
        try RemoteShell.requireTransport(result)
        guard result.exitCode == 0 else { throw KubectlError.classify(RemoteShell.errorText(result)) }
        return result
    }
}
