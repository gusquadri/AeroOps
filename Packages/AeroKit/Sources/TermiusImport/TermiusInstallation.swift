import Foundation
#if os(macOS)
import Security
#endif

/// Where a Termius install keeps its data, and the Keychain item that encrypts it.
///
/// Termius is an Electron app: its hosts, groups, identities and keys live in Chromium's
/// IndexedDB under Application Support, with sensitive fields sealed by a key it keeps in the
/// login Keychain. AeroOps only reads both; it never writes to Termius's files or Keychain item.
public struct TermiusInstallation: Sendable, Hashable {
    /// The `…indexeddb.leveldb` folder holding the hosts database.
    public var databaseDirectory: URL
    /// The Keychain service of the `localKey` item: `Termius`, or `Termius (MAS)` for the
    /// App Store build.
    public var keychainService: String

    public init(databaseDirectory: URL, keychainService: String) {
        self.databaseDirectory = databaseDirectory
        self.keychainService = keychainService
    }

    /// The Keychain account Termius stores its key under.
    public static let keychainAccount = "localKey"

    /// The first install found: the direct download, then the App Store build.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws(TermiusImportError) -> TermiusInstallation {
        let candidates: [(URL, String)] = [
            (home.appendingPathComponent("Library/Application Support/Termius"), "Termius"),
            (home.appendingPathComponent("Library/Containers/com.termius.mac/Data/Library/Application Support/Termius"), "Termius (MAS)"),
        ]
        var sawInstall = false
        for (support, service) in candidates {
            let indexedDB = support.appendingPathComponent("IndexedDB")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: indexedDB.path) else { continue }
            sawInstall = true
            for name in names.sorted() where name.hasSuffix(".indexeddb.leveldb") {
                let directory = indexedDB.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("CURRENT").path),
                   (try? Self.hasHostsDatabase(directory)) == true {
                    return TermiusInstallation(databaseDirectory: directory, keychainService: service)
                }
            }
        }
        throw sawInstall ? .noHostsDatabase : .notInstalled
    }

    private static func hasHostsDatabase(_ directory: URL) throws(StorageError) -> Bool {
        try IndexedDBSnapshot(directory: directory).rows(ofDatabase: TermiusData.Table.hosts.rawValue) != nil
    }

    /// Reads and decrypts the hosts and keys. `localKey` is the Keychain item's text (see
    /// ``readLocalKey()``). Runs synchronously; call it off the main actor.
    public func load(localKey: String) throws(TermiusImportError) -> TermiusData {
        let snapshot: IndexedDBSnapshot
        do {
            snapshot = try IndexedDBSnapshot(directory: databaseDirectory)
        } catch {
            throw .storage(error)
        }
        return try Self.data(from: snapshot, cipher: TermiusFieldCipher(localKey: localKey))
    }

    static func data(from snapshot: IndexedDBSnapshot, cipher: TermiusFieldCipher) throws(TermiusImportError) -> TermiusData {
        guard snapshot.rows(ofDatabase: TermiusData.Table.hosts.rawValue) != nil else { throw .noHostsDatabase }
        var rows: [TermiusData.Table: [JSValue]] = [:]
        var skipped = 0
        for table in TermiusData.Table.allCases {
            guard let store = snapshot.rows(ofDatabase: table.rawValue) else { continue }
            rows[table] = store.rows
            skipped += store.unreadableRows
        }
        return try TermiusData(rows: rows, cipher: cipher, skippedRows: skipped)
    }

    #if os(macOS)
    /// Termius's encryption key from the login Keychain. macOS asks the user to allow it,
    /// because the item belongs to Termius. Blocks until they answer; call it off the main actor.
    ///
    /// The key is only ever held in memory.
    public func readLocalKey() throws(TermiusImportError) -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw .badLocalKey }
            return text
        case errSecItemNotFound:
            throw .keyNotFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw .keyDenied
        default:
            throw .keychain(status)
        }
    }
    #endif
}
