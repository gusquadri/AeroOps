import AeroCore
import Foundation

/// A collector refused a request before anything was sent to the host.
///
/// Container, pod, namespace and container-in-pod names must pass `ShellQuote.isSafeName`
/// (`[A-Za-z0-9_.-]+`, no leading `-`) *and* are quoted with `ShellQuote.quote`; the kubectl
/// prefix must pass ``KubectlPrefix/normalized(_:)``.
public enum CollectorInputError: Error, Sendable, Hashable, LocalizedError {
    /// A name is empty or contains characters outside `[A-Za-z0-9_.-]` (or starts with `-`).
    /// `field` is `container`, `pod`, `namespace` or `name`; `value` is untrusted text.
    case unsafeName(field: String, value: String)
    /// The host's kubectl prefix is not a plain list of words (see ``KubectlPrefix``).
    case invalidKubectlPrefix(String, reason: String)
    /// `sinceSeconds` must be positive.
    case invalidSince(Int)
    /// The ``AeroCore/LogRequest`` names a different host than the one it was run on.
    case hostMismatch
    /// The request combines options that do not apply (e.g. `previous` for a Docker container).
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeName(let field, let value):
            "The \(field) name \(Self.preview(value)) is not allowed. Names may only contain letters, digits, "
                + "\".\", \"_\" and \"-\", and must not start with \"-\"."
        case .invalidKubectlPrefix(let prefix, let reason):
            "The kubectl prefix \(Self.preview(prefix)) is not allowed: \(reason)"
        case .invalidSince(let value):
            "\"since\" must be a positive number of seconds, not \(value)."
        case .hostMismatch:
            "The log request is for a different host."
        case .unsupported(let message):
            message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidKubectlPrefix:
            "Use plain words separated by spaces, for example \"sudo -n k3s kubectl\" or "
                + "\"KUBECONFIG=/etc/kube/config kubectl\". Quotes, $, ;, |, &, <, >, `, globs and ~ are not allowed."
        default:
            nil
        }
    }

    /// A short, quoted, single-line rendering of untrusted text for error messages.
    private static func preview(_ value: String) -> String {
        let flat = value.unicodeScalars.map { $0.properties.generalCategory == .control ? "?" : String($0) }.joined()
        return "\"" + (flat.count > 80 ? String(flat.prefix(80)) + "…" : flat) + "\""
    }
}

/// Name checks shared by the Docker, Kubernetes and log collectors.
enum NameCheck {
    /// Returns `value` if it passes `ShellQuote.isSafeName`, else throws ``CollectorInputError/unsafeName(field:value:)``.
    @discardableResult
    static func require(_ value: String, field: String) throws(CollectorInputError) -> String {
        guard ShellQuote.isSafeName(value) else { throw .unsafeName(field: field, value: value) }
        return value
    }

    /// Checks an optional `--since` value.
    static func requireSince(_ seconds: Int?) throws(CollectorInputError) {
        if let seconds, seconds <= 0 { throw .invalidSince(seconds) }
    }
}
