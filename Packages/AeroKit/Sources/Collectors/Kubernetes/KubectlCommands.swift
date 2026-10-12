import AeroCore
import Foundation

/// The remote command strings behind ``KubernetesCollector``.
///
/// Each command is `LC_ALL=C <prefix> <arguments>`: the prefix is validated by
/// ``KubectlPrefix/normalized(_:)`` and inserted as is; every name is checked with
/// `ShellQuote.isSafeName` and quoted with `ShellQuote.quote`.
public struct KubectlCommands: Sendable, Hashable {
    /// The line ``pods(namespace:)`` prints between the pods JSON and the metrics JSON.
    public static let metricsMarker = "@@aero-pod-metrics"
    /// How long the metrics call may take; a slow or broken metrics-server must not hold up the
    /// pod list.
    static let metricsTimeout = "5s"

    /// The normalized prefix, e.g. `kubectl` or `sudo -n k3s kubectl`.
    public let prefix: String

    /// - Throws: ``CollectorInputError/invalidKubectlPrefix(_:reason:)``.
    public init(prefix: String?) throws(CollectorInputError) {
        self.prefix = try KubectlPrefix.normalized(prefix)
    }

    /// Uses `host.kubectlPrefix`.
    public init(host: RemoteHost) throws(CollectorInputError) {
        try self.init(prefix: host.kubectlPrefix)
    }

    /// The pods and their CPU and memory use (metrics-server) in one round trip:
    /// `LC_ALL=C sh -c '<prefix> get pods -A -o json || exit $?; echo; echo @@aero-pod-metrics;
    /// <prefix> get --raw '/apis/metrics.k8s.io/v1beta1/pods' --request-timeout=5s 2>/dev/null || true'`,
    /// or the same for one namespace (`-n '<namespace>'`, `.../namespaces/<namespace>/pods`).
    ///
    /// The script exits with `get pods`'s status when that fails. A failing metrics call (no
    /// metrics-server, no permission) prints nothing after ``metricsMarker``, so the pods come
    /// back without CPU and memory.
    public func pods(namespace: String? = nil) throws(CollectorInputError) -> String {
        let scope: String
        let metricsPath: String
        if let namespace {
            scope = "-n \(try quoted(namespace, field: "namespace"))"
            metricsPath = "/apis/metrics.k8s.io/v1beta1/namespaces/\(namespace)/pods"
        } else {
            scope = "-A"
            metricsPath = "/apis/metrics.k8s.io/v1beta1/pods"
        }
        let script = "\(prefix) get pods \(scope) -o json || exit $?; "
            + "echo; echo \(Self.metricsMarker); "
            + "\(prefix) get --raw \(ShellQuote.quote(metricsPath)) --request-timeout=\(Self.metricsTimeout) 2>/dev/null || true"
        return RemoteShell.script(script)
    }

    /// `logs [-f] -n '<ns>' '<pod>' [-c '<container>'] [--previous] --tail=<n> --timestamps [--since=<s>s]`.
    ///
    /// `tail` is clamped to `0...LogRequest.maxTail`.
    public func logs(
        pod: String,
        namespace: String,
        container: String? = nil,
        previous: Bool = false,
        tail: Int,
        sinceSeconds: Int? = nil,
        follow: Bool = false
    ) throws(CollectorInputError) -> String {
        var words = ["logs"]
        if follow { words.append("-f") }
        words += ["-n", try quoted(namespace, field: "namespace"), try quoted(pod, field: "pod")]
        if let container { words += ["-c", try quoted(container, field: "container")] }
        if previous { words.append("--previous") }
        words += ["--tail=\(min(max(tail, 0), LogRequest.maxTail))", "--timestamps"]
        try NameCheck.requireSince(sinceSeconds)
        if let sinceSeconds { words.append("--since=\(sinceSeconds)s") }
        return command(words.joined(separator: " "))
    }

    /// `describe pod -n '<ns>' '<pod>'`.
    public func describe(pod: String, namespace: String) throws(CollectorInputError) -> String {
        let ns = try quoted(namespace, field: "namespace")
        let name = try quoted(pod, field: "pod")
        return command("describe pod -n \(ns) \(name)")
    }

    /// `get events -n '<ns>' --field-selector 'involvedObject.name=<pod>' -o json`.
    public func events(pod: String, namespace: String) throws(CollectorInputError) -> String {
        let namespace = try quoted(namespace, field: "namespace")
        try NameCheck.require(pod, field: "pod")
        let selector = ShellQuote.quote("involvedObject.name=\(pod)")
        return command("get events -n \(namespace) --field-selector \(selector) -o json")
    }

    /// Splits ``pods(namespace:)`` output into the pods JSON and the metrics JSON (empty when
    /// the metrics call failed or the marker is missing).
    static func splitPodsOutput(_ output: Data) -> (pods: Data, metrics: Data) {
        // JSON strings cannot hold a raw newline, so the marker line cannot occur inside the pods JSON.
        guard let marker = output.range(of: Data("\n\(metricsMarker)\n".utf8)) else { return (output, Data()) }
        return (output[..<marker.lowerBound], output[marker.upperBound...])
    }

    private func command(_ arguments: String) -> String {
        "\(RemoteShell.localePrefix) \(prefix) \(arguments)"
    }

    private func quoted(_ value: String, field: String) throws(CollectorInputError) -> String {
        ShellQuote.quote(try NameCheck.require(value, field: field))
    }
}
