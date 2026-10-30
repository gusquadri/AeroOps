import Foundation
import LocalAuthentication
import Security

/// A ``KeychainStore`` of generic-password items in the data protection keychain, in the access
/// group the Mac and iOS apps share. Items with ``KeychainItem/syncs`` set travel between the
/// user's devices with iCloud Keychain; the others stay on this device.
///
/// Items open after the device's first unlock, not only while it is unlocked: the Mac app keeps
/// polling and signing behind a locked screen, and a synced item has the same class everywhere.
///
/// Both apps need the `keychain-access-groups` entitlement for ``sharedAccessGroup`` (on macOS that
/// takes a provisioning profile). No operation ever shows a dialog: one that would fails with
/// ``KeychainError/interactionRequired(operation:)``, because the agent signs for background `ssh`.
public struct SystemKeychain: KeychainStore {
    /// The access group of both apps (`$(AppIdentifierPrefix)app.aeroops`).
    public static let sharedAccessGroup = "VUDQQS32NW.app.aeroops"

    public let service: String
    /// The item name the system shows.
    public let label: String

    public init(service: String, label: String) {
        self.service = service
        self.label = label
    }

    public func items() throws(KeychainError) -> [KeychainItem] {
        var find = query()
        find[kSecReturnAttributes] = true
        find[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.error("list", status) }
        let rows = result as? [[String: Any]] ?? []
        return Self.newestPerAccount(rows.compactMap(Self.entry))
    }

    public func secret(for account: String) throws(KeychainError) -> Data? {
        var find = query(account: account)
        find[kSecReturnData] = true
        find[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.error("read", status) }
        guard let data = result as? Data else { throw .unexpectedData(account) }
        return data
    }

    /// Adds the item with the sync flag it asks for, then removes any copy with the other flag
    /// (the Keychain treats the two as different items).
    public func save(_ item: KeychainItem, secret: Data) throws(KeychainError) {
        var add = query(account: item.account, syncs: item.syncs)
        add[kSecValueData] = secret
        add[kSecAttrGeneric] = item.record
        add[kSecAttrLabel] = label
        add[kSecAttrAccessible] = Self.accessibility(syncs: item.syncs)
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let changes: [CFString: Any] = [
                kSecValueData: secret, kSecAttrGeneric: item.record, kSecAttrAccessible: Self.accessibility(syncs: item.syncs),
            ]
            status = SecItemUpdate(query(account: item.account, syncs: item.syncs) as CFDictionary, changes as CFDictionary)
        }
        guard status == errSecSuccess else { throw Self.error("save", status) }
        try remove(item.account, syncs: !item.syncs)
    }

    private static func accessibility(syncs: Bool) -> CFString {
        syncs ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    /// Rewrites the record in place; a changed sync flag re-adds the item with its secret.
    public func update(_ item: KeychainItem) throws(KeychainError) {
        let changes: [CFString: Any] = [kSecAttrGeneric: item.record]
        let status = SecItemUpdate(query(account: item.account, syncs: item.syncs) as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.error("update", status) }
        guard let secret = try secret(for: item.account) else { throw .missingItem(item.account) }
        try save(item, secret: secret)
    }

    public func delete(_ account: String) throws(KeychainError) {
        try remove(account, syncs: nil)
    }

    private func remove(_ account: String, syncs: Bool?) throws(KeychainError) {
        let status = SecItemDelete(query(account: account, syncs: syncs) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error("delete", status) }
    }

    /// `syncs: nil` matches the item whichever its sync flag.
    private func query(account: String? = nil, syncs: Bool? = nil) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: Self.sharedAccessGroup,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: syncs.map { $0 as Any } ?? kSecAttrSynchronizableAny,
            kSecUseAuthenticationContext: context,
        ]
        query[kSecAttrAccount] = account
        return query
    }

    private struct Entry {
        var item: KeychainItem
        var modified: Date
    }

    private static func entry(_ row: [String: Any]) -> Entry? {
        guard let account = row[kSecAttrAccount as String] as? String else { return nil }
        let item = KeychainItem(
            account: account,
            record: row[kSecAttrGeneric as String] as? Data ?? Data(),
            syncs: row[kSecAttrSynchronizable as String] as? Bool ?? false)
        return Entry(item: item, modified: row[kSecAttrModificationDate as String] as? Date ?? .distantPast)
    }

    /// One item per account: a save interrupted between its add and its delete leaves both copies.
    private static func newestPerAccount(_ entries: [Entry]) -> [KeychainItem] {
        let newest = Dictionary(entries.map { ($0.item.account, $0) }) { $0.modified >= $1.modified ? $0 : $1 }
        return newest.values.map(\.item)
    }

    private static func error(_ operation: String, _ status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            .interactionRequired(operation: operation)
        default:
            .failed(operation: operation, status: status, message: SecCopyErrorMessageString(status, nil) as String? ?? "unknown error")
        }
    }
}
