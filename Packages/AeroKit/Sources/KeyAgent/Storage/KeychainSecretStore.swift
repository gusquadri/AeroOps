import Foundation
import LocalAuthentication
import Security
import Synchronization

/// A ``SecretStore`` backed by Keychain generic-password items (service `app.aeroops.keys`,
/// account = key id).
///
/// ## Backend
///
/// Today every build is signed with the Apple Development identity of team `VUDQQS32NW` and uses
/// the **legacy file-based login keychain** (``Backend/legacyFileKeychain``). Items created by
/// such a build carry the partition list `teamid:VUDQQS32NW`, so rebuilt binaries read and update
/// them without a prompt. Two quirks are handled here:
///
/// - Deleting an item from a *different* build than the one that created it fails with
///   `errSecInvalidOwnerEdit` (-25244), whatever `SecAccess`/partition list the item was created
///   with. ``delete(for:)`` falls back to `SecKeychainItemDelete` on the item reference, which works.
/// - The per-query "fail instead of prompting" flag alone does not stop the legacy keychain's
///   access dialog, so with `allowsUserInteraction == false` each operation also turns off
///   keychain user interaction process-wide for its duration (restoring the previous state).
///
/// ## SWITCH POINT: data protection keychain
///
/// ``Backend/dataProtection(accessGroup:)`` stores items in the data protection keychain
/// (`kSecUseDataProtectionKeychain`, `WhenUnlockedThisDeviceOnly`, never synchronized). That
/// keychain needs the `keychain-access-groups` entitlement, which a macOS app may only carry with
/// a provisioning profile; the team has none yet. Once it does: add the entitlement in project.yml,
/// switch the app to `.dataProtection(accessGroup: "VUDQQS32NW.app.aeroops")`, and migrate items
/// (load from `.legacyFileKeychain`, save to `.dataProtection`, delete the legacy item).
public struct KeychainSecretStore: SecretStore {
    /// Which keychain holds the items.
    public enum Backend: Sendable, Hashable {
        /// The legacy file-based login keychain. Works for any consistently signed build.
        case legacyFileKeychain
        /// SWITCH POINT: the data protection keychain. Requires the `keychain-access-groups`
        /// entitlement and a provisioning profile; see the type documentation.
        case dataProtection(accessGroup: String?)
    }

    /// The Keychain service of AeroOps key items.
    public static let defaultService = "app.aeroops.keys"

    public let service: String
    public let backend: Backend
    /// When `false` (the default), operations that would show a Keychain dialog fail with
    /// ``SecretStoreError/interactionRequired(operation:)`` instead. The agent signs on behalf of
    /// background `ssh` processes, so a hidden dialog must never block it.
    public let allowsUserInteraction: Bool

    public init(service: String = defaultService, backend: Backend = .legacyFileKeychain, allowsUserInteraction: Bool = false) {
        self.service = service
        self.backend = backend
        self.allowsUserInteraction = allowsUserInteraction
    }

    // MARK: SecretStore

    public func save(_ secret: Data, for id: UUID) throws(SecretStoreError) {
        try withInteractionPolicy { () throws(SecretStoreError) in
            var add = query(for: id)
            add[kSecValueData] = secret
            add[kSecAttrLabel] = "AeroOps SSH key"
            add[kSecAttrDescription] = "AeroOps SSH private key"
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

    public func delete(for id: UUID) throws(SecretStoreError) {
        try withInteractionPolicy { () throws(SecretStoreError) in
            let status = SecItemDelete(query(for: id) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                return
            case errSecInvalidOwnerEdit where backend == .legacyFileKeychain:
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
        case .legacyFileKeychain:
            if !allowsUserInteraction {
                query[Self.legacy.authenticationUIKey] = Self.legacy.authenticationUIFail
            }
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
    }

    /// Serialises this type's keychain operations, which also keeps the process-wide
    /// user-interaction switch consistent between them.
    private static let lock = Mutex(())

    private func withInteractionPolicy<T>(_ body: () throws(SecretStoreError) -> T) throws(SecretStoreError) -> T {
        try Self.lock.withLock { _ throws(SecretStoreError) -> T in
            guard backend == .legacyFileKeychain, !allowsUserInteraction else { return try body() }
            let previous = Self.legacy.userInteractionAllowed()
            if previous { Self.legacy.setUserInteractionAllowed(false) }
            defer { if previous { Self.legacy.setUserInteractionAllowed(true) } }
            return try body()
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

    private static let legacy: any LegacyKeychainAPI = LegacyKeychain()
}

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
