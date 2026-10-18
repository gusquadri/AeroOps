import AskpassProtocol
import Foundation
import Synchronization

/// Password hosts' login passwords: Keychain items (service ``keychainService``, account = host
/// id), plus short-lived passwords for testing an unsaved host.
///
/// Passwords leave the vault only through ``AskpassServer``, to a verified `aeroops-askpass`, and
/// on iOS through ``loginPassword(for:token:)`` to EmbeddedSSH, which sends them to the host.
/// The vault only answers for hosts set with ``setPasswordHosts(_:)``, so a host switched back to
/// key authentication stops getting its old password even before the app deletes it.
public final class HostPasswordVault: Sendable {
    /// The Keychain service of AeroOps password items.
    public static let keychainService = "app.aeroops.passwords"

    /// The Keychain store the app uses for passwords.
    public static func keychainStore() -> KeychainSecretStore {
        KeychainSecretStore(service: keychainService, label: "AeroOps SSH password", itemDescription: "AeroOps SSH login password")
    }

    /// How long a test password stays usable if ``endTemporary(_:)`` is never called.
    static let temporaryLifetime: Duration = .seconds(120)

    private struct Temporary {
        var host: UUID
        var password: String
        var expires: ContinuousClock.Instant
    }

    private struct State {
        var passwordHosts: Set<UUID> = []
        /// Hosts known to have a saved password. A cache of the store, so the attempt gate can
        /// ask on every command without touching the Keychain.
        var saved: Set<UUID> = []
        var temporary: [String: Temporary] = [:]
    }

    private let store: any SecretStore
    private let state = Mutex(State())

    public init(store: any SecretStore) {
        self.store = store
    }

    /// The password hosts. Refreshes the saved-password cache for them from the store; a host
    /// whose item cannot be checked counts as having none.
    public func setPasswordHosts(_ ids: Set<UUID>) {
        let saved = Set(ids.filter { (try? store.contains($0)) == true })
        state.withLock {
            $0.passwordHosts = ids
            $0.saved = saved
        }
    }

    /// Whether `id` is a password host with a saved password. Cached; never touches the Keychain.
    public func hasPassword(for id: UUID) -> Bool {
        state.withLock { $0.passwordHosts.contains(id) && $0.saved.contains(id) }
    }

    /// Whether the store holds a password for `id`, whether or not it is a password host.
    /// Asks the store (attributes only, never the password).
    public func isSaved(_ id: UUID) -> Bool {
        (try? store.contains(id)) == true
    }

    /// Saves `password` for `id`, replacing any previous one.
    public func save(_ password: String, for id: UUID) throws(HostPasswordError) {
        if let problem = Askpass.passwordProblem(password) { throw .unusable(problem) }
        do {
            try store.save(Data(password.utf8), for: id)
        } catch {
            throw .store(error)
        }
        state.withLock { _ = $0.saved.insert(id) }
    }

    /// Deletes `id`'s saved password. Succeeds when there is none.
    public func delete(for id: UUID) throws(SecretStoreError) {
        try store.delete(for: id)
        state.withLock { _ = $0.saved.remove(id) }
    }

    /// Makes `password` available for `id` until ``endTemporary(_:)``, without saving it.
    /// Returns the token to pass as ``SSHKit/SSHContext/askpassToken``.
    public func beginTemporary(_ password: String, for id: UUID) throws(HostPasswordError) -> String {
        if let problem = Askpass.passwordProblem(password) { throw .unusable(problem) }
        let token = Askpass.makeToken()
        let expires = ContinuousClock.now + Self.temporaryLifetime
        state.withLock { state in
            let now = ContinuousClock.now
            state.temporary = state.temporary.filter { $0.value.expires > now }
            state.temporary[token] = Temporary(host: id, password: password, expires: expires)
        }
        return token
    }

    public func endTemporary(_ token: String) {
        _ = state.withLock { $0.temporary.removeValue(forKey: token) }
    }

    /// The password for `request`, or why there is none (safe to show).
    func answer(_ request: AskpassRequest) -> Result<String, AskpassRefusal> {
        loginPassword(for: request.host, token: request.token)
    }

    /// The password for host `id` (the test password of `token`, if given), or why there is none.
    /// `package`: besides ``AskpassServer``, only AeroKit's in-process SSH client (EmbeddedSSH,
    /// used on iOS) reads passwords, and it sends them only to the host's verified server.
    package func loginPassword(for id: UUID, token: String? = nil) -> Result<String, AskpassRefusal> {
        if let token {
            let entry = state.withLock { state -> Temporary? in
                guard let entry = state.temporary[token], entry.expires > .now else { return nil }
                return entry
            }
            guard let entry, entry.host == id else { return .failure(.unknownToken) }
            return .success(entry.password)
        }
        guard state.withLock({ $0.passwordHosts.contains(id) }) else { return .failure(.notPasswordHost) }
        let data: Data?
        do {
            data = try store.load(for: id)
        } catch {
            return .failure(.store(error.localizedDescription))
        }
        guard let data, let password = String(data: data, encoding: .utf8), Askpass.passwordProblem(password) == nil else {
            state.withLock { _ = $0.saved.remove(id) }
            return .failure(.noPassword)
        }
        return .success(password)
    }
}

/// Why a password could not be saved or used.
public enum HostPasswordError: Error, Equatable, Sendable, LocalizedError {
    case unusable(Askpass.PasswordProblem)
    case store(SecretStoreError)

    public var errorDescription: String? {
        switch self {
        case .unusable(.empty): "The password is empty."
        case .unusable(.lineBreak): "The password contains a line break, which ssh cannot send."
        case .unusable(.tooLong): "The password is longer than \(Askpass.maxPasswordBytes) bytes, which ssh cannot send."
        case .store(let error): error.localizedDescription
        }
    }
}

/// Why the askpass server gave `aeroops-askpass` no password. The descriptions are safe to show
/// and log: they never contain a secret.
public enum AskpassRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The helper's code signature, parent or ancestry did not check out.
    case untrustedPeer(String)
    case malformedRequest
    /// Anything but the login password: a passphrase, a one-time code, an expired password's
    /// change dialogue.
    case notPasswordPrompt
    /// The same ssh asked again, so the server rejected the password it was given.
    case alreadyAnswered
    case notPasswordHost
    case noPassword
    case unknownToken
    case store(String)

    public var description: String {
        switch self {
        case .untrustedPeer(let reason): "the askpass helper could not be verified: \(reason)"
        case .malformedRequest: "the askpass request was malformed"
        case .notPasswordPrompt: "the server asked for something other than the login password"
        case .alreadyAnswered: "the server rejected the password and asked again"
        case .notPasswordHost: "the host does not use password authentication"
        case .noPassword: "no password is saved for the host"
        case .unknownToken: "the test password expired"
        case .store(let reason): "the Keychain could not be read: \(reason)"
        }
    }
}
