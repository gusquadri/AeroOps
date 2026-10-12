import Foundation
import Synchronization

/// Where private key material lives, addressed by key id.
///
/// Secrets live only here (Keychain or Secure Enclave wrapping), never in files, logs or
/// fixtures. ``KeychainSecretStore`` is the real implementation; ``InMemorySecretStore`` is for
/// tests and previews.
public protocol SecretStore: Sendable {
    /// Stores `secret` for `id`, replacing any previous value.
    func save(_ secret: Data, for id: UUID) throws(SecretStoreError)
    /// The secret for `id`, or `nil` when there is none.
    func load(for id: UUID) throws(SecretStoreError) -> Data?
    /// Removes the secret for `id`. Succeeds when there is none.
    func delete(for id: UUID) throws(SecretStoreError)
    /// Whether a secret is stored for `id`, without reading it where the store can.
    func contains(_ id: UUID) throws(SecretStoreError) -> Bool
}

extension SecretStore {
    public func contains(_ id: UUID) throws(SecretStoreError) -> Bool {
        try load(for: id) != nil
    }
}

/// A ``SecretStore`` failure.
public enum SecretStoreError: Error, Equatable, Sendable, LocalizedError {
    /// The Keychain returned `status` for `operation`. `message` is `SecCopyErrorMessageString`.
    case keychain(operation: String, status: Int32, message: String)
    /// Access needs user interaction (an ACL prompt or a locked keychain) but it is disabled.
    case interactionRequired(operation: String)
    /// The store returned something other than the expected bytes.
    case unexpectedData(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status, let message): "Keychain \(operation) failed (\(status)): \(message)"
        case .interactionRequired(let operation):
            "Keychain \(operation) needs user interaction (the keychain is locked, or this build is not trusted by the item)."
        case .unexpectedData(let why): "Keychain returned unexpected data: \(why)"
        }
    }
}

/// A ``SecretStore`` in process memory. For tests and previews only.
public final class InMemorySecretStore: SecretStore {
    private let secrets = Mutex<[UUID: Data]>([:])

    public init() {}

    public func save(_ secret: Data, for id: UUID) throws(SecretStoreError) {
        secrets.withLock { $0[id] = secret }
    }

    public func load(for id: UUID) throws(SecretStoreError) -> Data? {
        secrets.withLock { $0[id] }
    }

    public func delete(for id: UUID) throws(SecretStoreError) {
        _ = secrets.withLock { $0.removeValue(forKey: id) }
    }

    /// The ids currently stored (for test assertions).
    public var storedIDs: Set<UUID> {
        secrets.withLock { Set($0.keys) }
    }
}
