import Foundation
import LocalAuthentication
import Security
import Synchronization

/// Where AeroOps kept private keys and passwords before both apps shared ``AeroCore/SystemKeychain``:
/// Keychain generic-password items (service `app.aeroops.keys`, account = key id; password hosts
/// use service `app.aeroops.passwords`, account = host id). The apps only read it to move the
/// items (``KeyStore/importLegacyKeys(metadataDirectory:secrets:)``,
/// ``HostPasswordVault/importLegacyPasswords(of:from:)``).
///
/// ## Backend
///
/// The Mac app used the **legacy file-based login keychain** (``Backend/legacyFileKeychain``).
/// Items created by an Apple Development build of team `VUDQQS32NW` carry the partition list
/// `teamid:VUDQQS32NW`, so later builds of the team read them without a prompt. Two quirks are
/// handled here:
///
/// - Deleting an item from a *different* build than the one that created it fails with
///   `errSecInvalidOwnerEdit` (-25244), whatever `SecAccess`/partition list the item was created
///   with. ``delete(for:)`` falls back to `SecKeychainItemDelete` on the item reference, which works.
/// - The per-query "fail instead of prompting" flag alone does not stop the legacy keychain's
///   access dialog, so with `allowsUserInteraction == false` each operation also turns off
///   keychain user interaction process-wide for its duration (restoring the previous state).
///
/// The iOS app used the data protection keychain (``Backend/dataProtection(accessGroup:)``,
/// `WhenUnlockedThisDeviceOnly`, never synchronized) in its own access group.
public struct KeychainSecretStore: SecretStore {
    /// Which keychain holds the items.
    public enum Backend: Sendable, Hashable {
        #if os(macOS)
        /// The legacy file-based login keychain. Works for any consistently signed build.
        case legacyFileKeychain
        #endif
        /// The data protection keychain, in `accessGroup` (`nil`: every group the app has).
        case dataProtection(accessGroup: String?)

        /// What an older AeroOps used: the legacy keychain on macOS, the iOS app's own access group
        /// (its application identifier) on iOS.
        public static var platformDefault: Backend {
            #if os(macOS)
            .legacyFileKeychain
            #else
            .dataProtection(accessGroup: "VUDQQS32NW.app.aeroops.AeroOpsMobile")
            #endif
        }

        var isLegacy: Bool {
            #if os(macOS)
            self == .legacyFileKeychain
            #else
            false
            #endif
        }
    }

    /// The Keychain service of AeroOps key items.
    public static let defaultService = "app.aeroops.keys"

    public let service: String
    public let backend: Backend
    /// When `false` (the default), operations that would show a Keychain dialog fail with
    /// ``SecretStoreError/interactionRequired(operation:)`` instead. The agent signs on behalf of
    /// background `ssh` processes, so a hidden dialog must never block it.
    public let allowsUserInteraction: Bool
    /// The item name Keychain Access shows.
    public let label: String
    /// The item kind Keychain Access shows.
    public let itemDescription: String

    public init(
        service: String = defaultService,
        backend: Backend = .platformDefault,
        allowsUserInteraction: Bool = false,
        label: String = "AeroOps SSH key",
        itemDescription: String = "AeroOps SSH private key"
    ) {
        self.service = service
        self.backend = backend
        self.allowsUserInteraction = allowsUserInteraction
        self.label = label
        self.itemDescription = itemDescription
    }

    // MARK: SecretStore

    public func save(_ secret: Data, for id: UUID) throws(SecretStoreError) {
        try withInteractionPolicy { () throws(SecretStoreError) in
            var add = query(for: id)
            add[kSecValueData] = secret
            add[kSecAttrLabel] = label
            add[kSecAttrDescription] = itemDescription
            if case .dataProtection = backend {
                add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
            let status = SecItemAdd(add as CFDictionary, nil)
            switch status {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                let update = SecItemUpdate(query(for: id) as CFDictionary, [kSecValueData: secret] as CFDictionary)
                guard update == errSecSuccess else { throw Self.error("update", update) }
            default:
                throw Self.error("add", status)
            }
        }
    }

    public func load(for id: UUID) throws(SecretStoreError) -> Data? {
        try withInteractionPolicy { () throws(SecretStoreError) -> Data? in
            var find = query(for: id)
            find[kSecReturnData] = true
            find[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(find as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { throw .unexpectedData("item for \(id) has no data") }
                return data.isEmpty ? nil : data
            case errSecItemNotFound:
                return nil
            default:
                throw Self.error("read", status)
            }
        }
    }

    /// Reads only the item's attributes, so it never needs the item's access control.
    public func contains(_ id: UUID) throws(SecretStoreError) -> Bool {
        try withInteractionPolicy { () throws(SecretStoreError) -> Bool in
            var find = query(for: id)
            find[kSecReturnAttributes] = true
            find[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(find as CFDictionary, &result)
            switch status {
            case errSecSuccess: return true
            case errSecItemNotFound: return false
            default: throw Self.error("lookup", status)
            }
        }
    }

    public func delete(for id: UUID) throws(SecretStoreError) {
        try withInteractionPolicy { () throws(SecretStoreError) in
            let status = SecItemDelete(query(for: id) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                return
            case errSecInvalidOwnerEdit where backend.isLegacy:
                try deleteByReference(id)
            default:
                throw Self.error("delete", status)
            }
        }
    }

    // MARK: Internals

    private func query(for id: UUID) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
        ]
        switch backend {
        #if os(macOS)
        case .legacyFileKeychain:
            if !allowsUserInteraction {
                query[Self.legacy.authenticationUIKey] = Self.legacy.authenticationUIFail
            }
        #endif
        case .dataProtection(let accessGroup):
            query[kSecUseDataProtectionKeychain] = true
            query[kSecAttrSynchronizable] = false
            if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
            if !allowsUserInteraction {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext] = context
            }
        }
        return query
    }

    /// The -25244 fallback: a build other than the item's creator may not `SecItemDelete` it,
    /// but `SecKeychainItemDelete` on the reference succeeds without a prompt.
    private func deleteByReference(_ id: UUID) throws(SecretStoreError) {
        #if os(macOS)
        // A loop, in case an earlier bug left duplicates behind; bounded so it cannot spin.
        for _ in 0..<8 {
            var find = query(for: id)
            find[kSecReturnRef] = true
            find[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(find as CFDictionary, &result)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess, let result else { throw Self.error("delete (lookup)", status) }
            let deleted = Self.legacy.delete(result)
            guard deleted == errSecSuccess else { throw Self.error("delete", deleted) }
        }
        throw .keychain(operation: "delete", status: errSecInvalidOwnerEdit, message: "item for \(id) keeps reappearing")
        #else
        throw Self.error("delete", errSecInvalidOwnerEdit)
        #endif
    }

    /// Serialises this type's keychain operations, which also keeps the process-wide
    /// user-interaction switch consistent between them.
    private static let lock = Mutex(())

    private func withInteractionPolicy<T>(_ body: () throws(SecretStoreError) -> T) throws(SecretStoreError) -> T {
        try Self.lock.withLock { _ throws(SecretStoreError) -> T in
            #if os(macOS)
            guard backend.isLegacy, !allowsUserInteraction else { return try body() }
            let previous = Self.legacy.userInteractionAllowed()
            if previous { Self.legacy.setUserInteractionAllowed(false) }
            defer { if previous { Self.legacy.setUserInteractionAllowed(true) } }
            return try body()
            #else
            return try body()
            #endif
        }
    }

    private static func error(_ operation: String, _ status: OSStatus) -> SecretStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .interactionRequired(operation: operation)
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return .keychain(operation: operation, status: status, message: message)
        }
    }

    #if os(macOS)
    private static let legacy: any LegacyKeychainAPI = LegacyKeychain()
    #endif
}

#if os(macOS)

// MARK: Legacy keychain calls

/// The file-based keychain calls this store needs. Apple deprecated them along with that keychain,
/// but they are still the only way to do these jobs on it. Calling them through protocol
/// witnesses keeps the deprecation notices on these few lines instead of every call site.
private protocol LegacyKeychainAPI: Sendable {
    func delete(_ item: CFTypeRef) -> OSStatus
    func userInteractionAllowed() -> Bool
    func setUserInteractionAllowed(_ allowed: Bool)
    var authenticationUIKey: CFString { get }
    var authenticationUIFail: CFString { get }
}

private struct LegacyKeychain: LegacyKeychainAPI {
    @available(macOS, deprecated: 10.10)
    func delete(_ item: CFTypeRef) -> OSStatus {
        guard CFGetTypeID(item) == SecKeychainItemGetTypeID() else { return errSecParam }
        return SecKeychainItemDelete(unsafeDowncast(item, to: SecKeychainItem.self))
    }

    @available(macOS, deprecated: 10.10)
    func userInteractionAllowed() -> Bool {
        var state = DarwinBoolean(true)
        return SecKeychainGetUserInteractionAllowed(&state) == errSecSuccess ? state.boolValue : true
    }

    @available(macOS, deprecated: 10.10)
    func setUserInteractionAllowed(_ allowed: Bool) {
        _ = SecKeychainSetUserInteractionAllowed(allowed)
    }

    @available(macOS, deprecated: 11.0)
    var authenticationUIKey: CFString { kSecUseAuthenticationUI }

    @available(macOS, deprecated: 11.0)
    var authenticationUIFail: CFString { kSecUseAuthenticationUIFail }
}
#endif
