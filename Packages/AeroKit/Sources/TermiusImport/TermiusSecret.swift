/// A password, private key or passphrase read from Termius, held only in memory.
///
/// Its description, debug description and mirror never show the value, so it can't end up in
/// logs, test output or `dump` by accident. Read it with ``reveal()`` only to hand it to the
/// Keychain or KeyAgent.
public struct TermiusSecret: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public func reveal() -> String { value }

    public var isEmpty: Bool { value.isEmpty }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "TermiusSecret(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
