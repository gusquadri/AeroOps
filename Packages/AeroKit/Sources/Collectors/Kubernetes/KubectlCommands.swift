import AeroCore
import Foundation

/// The remote command strings behind ``KubernetesCollector``.
///
/// Each command is `LC_ALL=C <prefix> <arguments>`: the prefix is validated by
/// ``KubectlPrefix/normalized(_:)`` and inserted as is; every name is checked with
/// `ShellQuote.isSafeName` and quoted with `ShellQuote.quote`.
public struct KubectlCommands: Sendable, Hashable {
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

    /// `get pods -A -o json`, or `get pods -n '<namespace>' -o json`.
    public func pods(namespace: String? = nil) throws(CollectorInputError) -> String {
        guard let namespace else { return command("get pods -A -o json") }
        let ns = try quoted(namespace, field: "namespace")
        return command("get pods -n \(ns) -o json")
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

    private func command(_ arguments: String) -> String {
        "\(RemoteShell.localePrefix) \(prefix) \(arguments)"
    }

    private func quoted(_ value: String, field: String) throws(CollectorInputError) -> String {
        ShellQuote.quote(try NameCheck.require(value, field: field))
    }
}
