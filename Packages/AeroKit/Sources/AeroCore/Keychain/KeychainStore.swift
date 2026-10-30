import Foundation
import Synchronization

/// One Keychain item: a secret, plus a record that can be read without it.
public struct KeychainItem: Sendable, Hashable {
    /// Unique within the store's service.
    public var account: String
    /// Non-secret data kept beside the secret.
    public var record: Data
    /// Whether iCloud Keychain carries the item to the user's other devices.
    public var syncs: Bool

    public init(account: String, record: Data = Data(), syncs: Bool) {
        self.account = account
        self.record = record
        self.syncs = syncs
    }
}

/// The items of one Keychain service. ``SystemKeychain`` is the app's; ``InMemoryKeychain`` is for
/// tests and previews.
///
/// Secrets live only here (or in the Secure Enclave), never in files, logs or fixtures.
public protocol KeychainStore: Sendable {
    /// Every item, without its secret.
    func items() throws(KeychainError) -> [KeychainItem]
    /// The secret of `account`, or `nil` when there is no such item.
    func secret(for account: String) throws(KeychainError) -> Data?
    /// Stores `item` with `secret`, replacing any item with the same account.
    func save(_ item: KeychainItem, secret: Data) throws(KeychainError)
    /// Changes an existing item's record or sync flag and keeps its secret.
    func update(_ item: KeychainItem) throws(KeychainError)
    /// Removes the item of `account` here and on every device it syncs to. Succeeds when there is none.
    func delete(_ account: String) throws(KeychainError)
}

/// A ``KeychainStore`` failure.
public enum KeychainError: Error, Equatable, Sendable, LocalizedError {
    /// The Keychain returned `status` for `operation`. `message` is `SecCopyErrorMessageString`.
    case failed(operation: String, status: Int32, message: String)
    /// The item needs user interaction (a locked device), which the store never shows.
    case interactionRequired(operation: String)
    /// ``KeychainStore/update(_:)`` found no item for the account.
    case missingItem(String)
    /// The Keychain returned something other than the secret's bytes.
    case unexpectedData(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let operation, let status, let message): "Keychain \(operation) failed (\(status)): \(message)"
        case .interactionRequired(let operation): "Keychain \(operation) needs this device to be unlocked."
        case .missingItem: "The item is no longer in the Keychain."
        case .unexpectedData(let account): "The Keychain returned unexpected data for \(account)."
        }
    }
}

/// A ``KeychainStore`` in process memory. For tests and previews only.
public final class InMemoryKeychain: KeychainStore {
    private struct Entry {
        var item: KeychainItem
        var secret: Data
    }

    private let entries = Mutex<[String: Entry]>([:])

    public init() {}

    public func items() -> [KeychainItem] {
        entries.withLock { $0.values.map(\.item) }
    }

    public func secret(for account: String) -> Data? {
        entries.withLock { $0[account]?.secret }
    }

    public func save(_ item: KeychainItem, secret: Data) {
        entries.withLock { $0[item.account] = Entry(item: item, secret: secret) }
    }

    public func update(_ item: KeychainItem) throws(KeychainError) {
        try entries.withLock { (entries: inout [String: Entry]) throws(KeychainError) in
            guard let secret = entries[item.account]?.secret else { throw .missingItem(item.account) }
            entries[item.account] = Entry(item: item, secret: secret)
        }
    }

    public func delete(_ account: String) {
        _ = entries.withLock { $0.removeValue(forKey: account) }
    }
}
