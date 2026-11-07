import Foundation

/// Why AeroOps couldn't read Termius's data.
public enum TermiusImportError: Error, Equatable, Sendable, LocalizedError {
    /// No Termius data folder in Application Support.
    case notInstalled
    /// The data folder has no hosts database (Termius never ran, or stores data elsewhere now).
    case noHostsDatabase
    /// Termius's database couldn't be read.
    case storage(StorageError)
    /// The Keychain has no Termius encryption key.
    case keyNotFound
    /// The user refused AeroOps access to Termius's Keychain item.
    case keyDenied
    /// The Keychain returned an unexpected status.
    case keychain(OSStatus)
    /// The Keychain item isn't a 32-byte key.
    case badLocalKey
    /// The key doesn't decrypt Termius's data (it belongs to another install or account).
    case wrongLocalKey

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Termius isn't installed on this Mac, or it has never been opened."
        case .noHostsDatabase:
            "Termius's data has no hosts. Open Termius once, then try again."
        case .storage(let error):
            "Termius's database couldn't be read (\(error)). Quit Termius and try again."
        case .keyNotFound:
            "Termius's encryption key isn't in your Keychain. Open Termius and sign in, then try again."
        case .keyDenied:
            "AeroOps wasn't allowed to read Termius's encryption key."
        case .keychain(let status):
            "The Keychain refused to read Termius's encryption key (error \(status))."
        case .badLocalKey:
            "Termius's encryption key isn't in a format AeroOps understands."
        case .wrongLocalKey:
            "Termius's encryption key doesn't open its data. Open Termius once, quit it, then try again."
        }
    }
}
