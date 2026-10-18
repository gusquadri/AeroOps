import AeroCore
import Foundation
import KeyAgent
import NIOCore
import NIOSSH
import SSHKit

/// What EmbeddedSSH logs in with: the same stores the macOS agent and askpass server read, so a
/// key or password set up once works through either client.
public struct EmbeddedSSHCredentials: Sendable {
    public var keyStore: KeyStore
    /// Password hosts' passwords; without a vault every password host fails with
    /// ``SSHKit/SSHError/authFailed``.
    public var passwords: HostPasswordVault?
    /// Asks for user presence as each key's ``KeyAgent/SigningPolicy`` requires, before the key
    /// is offered to a server.
    public var authorizer: PolicySigningAuthorizer

    public init(keyStore: KeyStore, passwords: HostPasswordVault?, authorizer: PolicySigningAuthorizer) {
        self.keyStore = keyStore
        self.passwords = passwords
        self.authorizer = authorizer
    }
}

/// Offers `host`'s credentials, each once: its saved password, or its key (every key but RSA ones,
/// which NIOSSH cannot sign with, when the host names none, like the agent offers all of its
/// keys). Running out fails the promise with ``SSHKit/SSHError/authFailed``, which ends the
/// connection.
///
/// NIOSSH calls the delegate on the connection's event loop, one offer at a time.
final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let host: RemoteHost
    private let credentials: EmbeddedSSHCredentials
    private var attempt = 0

    init(host: RemoteHost, credentials: EmbeddedSSHCredentials) {
        self.host = host
        self.credentials = credentials
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let attempt = attempt
        self.attempt += 1
        let host = host
        let credentials = credentials
        Task {
            do {
                nextChallengePromise.succeed(try await Self.offer(attempt, host: host, credentials: credentials, methods: availableMethods))
            } catch {
                nextChallengePromise.fail(error)
            }
        }
    }

    static func offer(
        _ attempt: Int,
        host: RemoteHost,
        credentials: EmbeddedSSHCredentials,
        methods: NIOSSHAvailableUserAuthenticationMethods
    ) async throws -> NIOSSHUserAuthenticationOffer {
        switch host.auth {
        case .password:
            // One try, like the generated ssh_config's `NumberOfPasswordPrompts 1`.
            guard attempt == 0, methods.contains(.password), let vault = credentials.passwords,
                  case .success(let password) = vault.loginPassword(for: host.id)
            else { throw SSHError.authFailed }
            return NIOSSHUserAuthenticationOffer(username: host.user, serviceName: "ssh-connection", offer: .password(.init(password: password)))
        case .key:
            guard methods.contains(.publicKey) else { throw SSHError.authFailed }
            let candidates = await candidateKeys(for: host, in: credentials.keyStore)
            guard attempt < candidates.count else { throw SSHError.authFailed }
            let (record, key) = try await credentials.keyStore.clientPrivateKey(id: candidates[attempt])
            let decision = await credentials.authorizer.authorizeClientSignature(key: record, user: host.user, host: host.address)
            // A refused Touch ID is what the agent's refusal is to ssh: a failed login.
            guard decision == .allow else { throw SSHError.authFailed }
            return NIOSSHUserAuthenticationOffer(username: host.user, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key.nioKey)))
        }
    }

    /// The host's key, or (if it names none) every key NIOSSH can sign with.
    static func candidateKeys(for host: RemoteHost, in keyStore: KeyStore) async -> [UUID] {
        if let keyId = host.keyId {
            return UUID(uuidString: keyId).map { [$0] } ?? []
        }
        return await keyStore.keys.filter { $0.algorithm != .rsa }.map(\.id)
    }
}

extension KeyStore.ClientPrivateKey {
    var nioKey: NIOSSHPrivateKey {
        switch self {
        case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key): NIOSSHPrivateKey(p256Key: key)
        case .secureEnclaveP256(let key): NIOSSHPrivateKey(secureEnclaveP256Key: key)
        }
    }
}

/// Hands the server's host key to `check`, which accepts it (returns) or rejects it (throws,
/// which ends the connection with that error).
final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let check: @Sendable (HostKey) async throws -> Void

    init(check: @escaping @Sendable (HostKey) async throws -> Void) {
        self.check = check
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key: HostKey
        do {
            key = try HostKey(nio: hostKey)
        } catch {
            validationCompletePromise.fail(SSHError.other("The server's host key could not be read: \(error.localizedDescription)"))
            return
        }
        let check = check
        Task {
            do {
                try await check(key)
                validationCompletePromise.succeed()
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }
}

extension HostKey {
    init(nio key: NIOSSHPublicKey) throws(HostKeyError) {
        let parts = String(openSSHPublicKey: key).split(separator: " ", maxSplits: 1).map(String.init)
        try self.init(type: parts.first ?? "", base64: parts.count > 1 ? parts[1] : "")
    }
}

/// What a server's host key means for `host`, like OpenSSH's `StrictHostKeyChecking yes` with
/// SSHKit's pinned keys: a pinned key passes; no pinned key (or only keys of other types) is
/// ``SSHKit/SSHError/hostKeyUnknown``; a different key of a pinned type blocks the host and is
/// ``SSHKit/SSHError/hostKeyChanged``.
func checkHostKey(_ key: HostKey, for host: RemoteHost, in store: HostKeyStore) async throws {
    let pinned = try await store.pinnedKeys(for: host)
    if pinned.contains(key) { return }
    guard pinned.contains(where: { $0.type == key.type }) else { throw SSHError.hostKeyUnknown }
    await store.block(host, offered: [key])
    throw SSHError.hostKeyChanged
}
