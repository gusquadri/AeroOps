// Generic-password storage for key material, in either the legacy file-based
// login keychain or the data protection keychain.
import Foundation
import LocalAuthentication
import Security

enum KeychainMode: Sendable, CustomStringConvertible {
    /// File-based login keychain. Item ACL is bound to the creating binary's
    /// code signature (cdhash when ad-hoc signed) plus a partition list.
    case legacy
    /// iOS-style data protection keychain (`kSecUseDataProtectionKeychain`).
    /// Needs a keychain-access-group-granting entitlement.
    case dataProtection(accessGroup: String?)

    var description: String {
        switch self {
        case .legacy: "legacy file keychain"
        case .dataProtection(let g): "data protection keychain (group: \(g ?? "default"))"
        }
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let op: String
    let status: OSStatus
    var description: String {
        "\(op) failed: OSStatus \(status) (\(SecCopyErrorMessageString(status, nil) as String? ?? "?"))"
    }
}

struct Keychain: Sendable {
    static let service = "app.aeroops.spike"

    let mode: KeychainMode
    /// When true, any query that would need UI (legacy ACL "allow access" prompt,
    /// Touch ID) fails with errSecInteractionNotAllowed instead of blocking.
    let noUI: Bool

    private func base(_ account: String) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Keychain.service,
            kSecAttrAccount: account,
        ]
        if case .dataProtection(let group) = mode {
            q[kSecUseDataProtectionKeychain] = true
            if let group { q[kSecAttrAccessGroup] = group }
        }
        if noUI {
            let ctx = LAContext()
            ctx.interactionNotAllowed = true
            q[kSecUseAuthenticationContext] = ctx
            q[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail // legacy-keychain equivalent
        }
        return q
    }

    func read(_ account: String) throws -> Data? {
        var q = base(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainError(op: "SecItemCopyMatching(\(account))", status: status)
        }
        return data
    }

    func add(_ account: String, data: Data, label: String) throws {
        var q = base(account)
        q[kSecValueData] = data
        q[kSecAttrLabel] = label
        // Only honoured by the data protection keychain on macOS (ignored by legacy).
        q[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(op: "SecItemAdd(\(account))", status: status) }
    }

    @discardableResult
    func delete(_ account: String) -> OSStatus {
        var q = base(account)
        q.removeValue(forKey: kSecUseAuthenticationContext)
        q.removeValue(forKey: kSecUseAuthenticationUI)
        return SecItemDelete(q as CFDictionary)
    }

    /// Loads the item, or creates it with `make()` when absent.
    func loadOrCreate(_ account: String, label: String, make: () throws -> Data) throws -> (Data, created: Bool) {
        if let d = try read(account) { return (d, false) }
        let d = try make()
        try add(account, data: d, label: label)
        return (d, true)
    }
}

/// The deprecated global switch for the legacy keychain. It vanished from the
/// public headers in the macOS 27 SDK but is still exported, so look it up.
func setLegacyKeychainUserInteraction(allowed: Bool) -> OSStatus? {
    typealias Fn = @convention(c) (DarwinBoolean) -> OSStatus
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") else { return nil }
    return unsafeBitCast(sym, to: Fn.self)(DarwinBoolean(allowed))
}
