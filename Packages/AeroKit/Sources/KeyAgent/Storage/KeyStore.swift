import AeroCore
import CryptoKit
import Foundation
import Security

/// Non-secret metadata of one key. The private part lives only in the ``SecretStore``.
///
/// `RemoteHost.keyId` holds `id.uuidString`.
public struct SSHKeyRecord: Codable, Sendable, Hashable, Identifiable {
    /// How the key came to exist.
    public enum Origin: String, Codable, Sendable {
        case generated
        case imported
    }

    public let id: UUID
    /// A label chosen by the user.
    public var name: String
    public let algorithm: SSHKeyAlgorithm
    /// The comment in the `authorized_keys` line and in `ssh-add -L`.
    public let comment: String
    /// The SSH wire-format public key.
    public let publicKeyBlob: Data
    /// OpenSSH `SHA256:` fingerprint of ``publicKeyBlob``.
    public let fingerprint: String
    public let createdAt: Date
    public var policy: SigningPolicy
    public let origin: Origin

    /// The public key, e.g. for display.
    public var publicKey: SSHPublicKey {
        // The blob was validated when the record was created or loaded.
        (try? SSHPublicKey(blob: publicKeyBlob)) ?? SSHPublicKey(unchecked: publicKeyBlob, keyType: algorithm.keyType)
    }

    /// The line to paste into a server's `~/.ssh/authorized_keys`.
    public var authorizedKeysLine: String {
        publicKey.authorizedKeysLine(comment: comment)
    }
}

/// Why a ``KeyStore`` operation failed.
public enum KeyStoreError: Error, Equatable, Sendable, LocalizedError {
    case keyNotFound(UUID)
    /// The same public key is already stored, under the given record.
    case duplicateKey(existing: UUID, name: String)
    case secureEnclaveUnavailable
    case importFailed(KeyImportError)
    case secretStore(SecretStoreError)
    /// The metadata names a key whose secret is gone (deleted outside the app).
    case missingSecret(UUID)
    /// The stored secret does not produce the recorded public key.
    case secretMismatch(UUID)
    case generationFailed(String)
    /// `keys.json` or a `.pub` file could not be read or written.
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .keyNotFound: "The key no longer exists."
        case .duplicateKey(_, let name): "This key is already stored as “\(name)”."
        case .secureEnclaveUnavailable: "This Mac has no Secure Enclave."
        case .importFailed(let error): error.errorDescription
        case .secretStore(let error): error.errorDescription
        case .missingSecret: "The key's private part is missing from the Keychain."
        case .secretMismatch: "The key's private part in the Keychain does not match its public key."
        case .generationFailed(let why): "Could not generate the key: \(why)"
        case .storage(let why): why
        }
    }
}

/// The app's SSH keys: metadata in `keys.json`, private parts in a ``SecretStore``, and one
/// `<key-id>.pub` file per key for `IdentityFile` in the generated ssh_config.
///
/// ```swift
/// let store = try KeyStore(secretStore: KeychainSecretStore(), paths: .standard)
/// let key = try await store.generate(.secureEnclaveP256, name: "MacBook", policy: .oncePerSession)
/// print(key.authorizedKeysLine)
/// ```
public actor KeyStore {
    /// `keys.json` metadata file.
    public nonisolated let metadataFile: URL
    /// Directory of `<key-id>.pub` files (`~/.aeroops/pub/`).
    public nonisolated let publicKeysDirectory: URL

    static let metadataFileName = "keys.json"

    private let secretStore: any SecretStore
    private var records: [SSHKeyRecord]
    /// Rebuilt signing keys, so the Keychain is read once per key per app run.
    private var signingKeyCache: [UUID: any SSHSigningKey] = [:]

    /// The app's store: `keys.json` in Application Support, public keys in `~/.aeroops/pub/`.
    public init(secretStore: any SecretStore, paths: AeroPaths = .standard) throws {
        try self.init(secretStore: secretStore, metadataDirectory: paths.applicationSupport, publicKeysDirectory: paths.publicKeysDirectory)
    }

    /// A store with explicit directories (tests).
    public init(secretStore: any SecretStore, metadataDirectory: URL, publicKeysDirectory: URL) throws {
        self.secretStore = secretStore
        self.metadataFile = metadataDirectory.appending(path: Self.metadataFileName)
        self.publicKeysDirectory = publicKeysDirectory
        self.records = try Self.loadRecords(from: metadataFile)
    }

    // MARK: Reading

    /// All keys, oldest first.
    public var keys: [SSHKeyRecord] { records }

    public func key(id: UUID) -> SSHKeyRecord? {
        records.first { $0.id == id }
    }

    /// The `authorized_keys` line of a key.
    public func authorizedKeysLine(for id: UUID) throws -> String {
        try record(id).authorizedKeysLine
    }

    /// `<publicKeysDirectory>/<key-id>.pub`, the `IdentityFile` for this key.
    public nonisolated func publicKeyFileURL(for id: UUID) -> URL {
        publicKeysDirectory.appending(path: "\(id.uuidString).pub")
    }

    // MARK: Creating

    /// Generates a key. Ed25519 keys are stored in the ``SecretStore``; Secure Enclave keys never
    /// leave the enclave, and only their wrapped handle is stored.
    @discardableResult
    public func generate(_ type: KeyGenerationType, name: String, comment: String? = nil, policy: SigningPolicy = .oncePerSession) throws -> SSHKeyRecord {
        let secret: Data
        let signingKey: any SSHSigningKey
        switch type {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            (secret, signingKey) = (key.rawRepresentation, Ed25519SigningKey(privateKey: key))
        case .secureEnclaveP256:
            guard SecureEnclave.isAvailable else { throw KeyStoreError.secureEnclaveUnavailable }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error) else {
                throw KeyStoreError.generationFailed(RSASigningKey.describe(error))
            }
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
                (secret, signingKey) = (key.dataRepresentation, SecureEnclaveP256SigningKey(privateKey: key))
            } catch {
                throw KeyStoreError.generationFailed(String(describing: error))
            }
        }
        return try add(
            algorithm: type.algorithm, name: name, comment: comment ?? name, policy: policy, origin: .generated,
            publicKeyBlob: signingKey.publicKeyBlob, secret: secret, signingKey: signingKey)
    }

    /// Imports an unencrypted OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`):
    /// Ed25519, ECDSA P-256 or RSA (≥ 1024 bits). `name` defaults to the key's comment.
    ///
    /// The private key moves into the ``SecretStore``; this does not touch the original file.
    @discardableResult
    public func importOpenSSHPrivateKey(_ text: String, name: String? = nil, policy: SigningPolicy = .oncePerSession) throws -> SSHKeyRecord {
        let parsed: OpenSSHPrivateKey
        do {
            parsed = try OpenSSHPrivateKey.parse(text)
        } catch {
            throw KeyStoreError.importFailed(error)
        }
        let fallbackName = parsed.comment.isEmpty ? "Imported \(parsed.algorithm.displayName) key" : parsed.comment
        let chosenName = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? fallbackName
        return try add(
            algorithm: parsed.algorithm, name: chosenName, comment: parsed.comment, policy: policy, origin: .imported,
            publicKeyBlob: parsed.publicKeyBlob, secret: parsed.secret, signingKey: parsed.signingKey)
    }

    private func add(
        algorithm: SSHKeyAlgorithm, name: String, comment: String, policy: SigningPolicy, origin: SSHKeyRecord.Origin,
        publicKeyBlob: [UInt8], secret: Data, signingKey: any SSHSigningKey
    ) throws -> SSHKeyRecord {
        let blob = Data(publicKeyBlob)
        if let existing = records.first(where: { $0.publicKeyBlob == blob }) {
            throw KeyStoreError.duplicateKey(existing: existing.id, name: existing.name)
        }
        // Whole seconds, so the record survives the ISO 8601 round trip through keys.json unchanged.
        let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let record = SSHKeyRecord(
            id: UUID(), name: name, algorithm: algorithm, comment: SSHPublicKey.sanitizedComment(comment),
            publicKeyBlob: blob, fingerprint: SSHPublicKey.fingerprint(of: blob), createdAt: createdAt,
            policy: policy, origin: origin)

        do {
            try secretStore.save(secret, for: record.id)
        } catch {
            throw KeyStoreError.secretStore(error)
        }
        do {
            try writePublicKeyFile(record)
            try saveRecords(records + [record])
        } catch {
            try? FileManager.default.removeItem(at: publicKeyFileURL(for: record.id))
            try? secretStore.delete(for: record.id)
            throw error
        }
        records.append(record)
        signingKeyCache[record.id] = signingKey
        return record
    }

    // MARK: Changing

    public func rename(id: UUID, to name: String) throws {
        try update(id) { $0.name = name }
    }

    /// Changes a key's signing policy. Callers using ``PolicySigningAuthorizer`` should also call
    /// ``PolicySigningAuthorizer/forgetSessionApproval(for:)`` so a stricter policy applies at once.
    public func setPolicy(id: UUID, _ policy: SigningPolicy) throws {
        try update(id) { $0.policy = policy }
    }

    private func update(_ id: UUID, _ change: (inout SSHKeyRecord) -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw KeyStoreError.keyNotFound(id) }
        var updated = records
        change(&updated[index])
        try saveRecords(updated)
        records = updated
    }

    /// Deletes the private part, the `.pub` file and the metadata. The secret goes first, so a
    /// failure leaves the key listed and the user can retry.
    public func delete(id: UUID) throws {
        guard records.contains(where: { $0.id == id }) else { throw KeyStoreError.keyNotFound(id) }
        do {
            try secretStore.delete(for: id)
        } catch {
            throw KeyStoreError.secretStore(error)
        }
        signingKeyCache[id] = nil
        let pub = publicKeyFileURL(for: id)
        if FileManager.default.fileExists(atPath: pub.path) {
            do {
                try FileManager.default.removeItem(at: pub)
            } catch {
                throw KeyStoreError.storage("Could not delete \(pub.path): \(error.localizedDescription)")
            }
        }
        let remaining = records.filter { $0.id != id }
        try saveRecords(remaining)
        records = remaining
    }

    /// Rewrites every `.pub` file (e.g. at launch, in case `~/.aeroops/pub/` was cleared).
    public func writePublicKeyFiles() throws {
        for record in records { try writePublicKeyFile(record) }
    }

    // MARK: Agent

    /// The keys the agent offers, in order.
    func identities() -> [SSHKeyRecord] { records }

    /// The record and signing key for a public key blob, or `nil` when no stored key has it.
    func signingKey(forPublicKeyBlob blob: [UInt8]) throws -> (record: SSHKeyRecord, key: any SSHSigningKey)? {
        guard let record = records.first(where: { $0.publicKeyBlob.elementsEqual(blob) }) else { return nil }
        if let cached = signingKeyCache[record.id] { return (record, cached) }
        let secret: Data?
        do {
            secret = try secretStore.load(for: record.id)
        } catch {
            throw KeyStoreError.secretStore(error)
        }
        guard let secret else { throw KeyStoreError.missingSecret(record.id) }
        let key: any SSHSigningKey
        do {
            key = try SigningKeyFactory.make(record.algorithm, secret: secret)
        } catch {
            throw KeyStoreError.secretMismatch(record.id)
        }
        guard key.publicKeyBlob.elementsEqual(record.publicKeyBlob) else { throw KeyStoreError.secretMismatch(record.id) }
        signingKeyCache[record.id] = key
        return (record, key)
    }

    // MARK: Embedded SSH client

    /// A stored key's private part for AeroKit's in-process SSH client (EmbeddedSSH, used on iOS
    /// where there is no `/usr/bin/ssh`). `package`, so it never reaches the app: the key only
    /// signs inside this process and is never written anywhere.
    package enum ClientPrivateKey: Sendable {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case secureEnclaveP256(SecureEnclave.P256.Signing.PrivateKey)
    }

    package enum ClientKeyError: Error, Equatable, Sendable, LocalizedError {
        /// swift-nio-ssh has no RSA user keys.
        case unsupportedAlgorithm(SSHKeyAlgorithm)

        package var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let algorithm): "\(algorithm.displayName) keys are not supported on this device. Use an Ed25519 or ECDSA key."
            }
        }
    }

    /// The record and private key of `id`, for the embedded client's `publickey` userauth.
    package func clientPrivateKey(id: UUID) throws -> (record: SSHKeyRecord, key: ClientPrivateKey) {
        let blob = try record(id).publicKeyBlob
        guard let (record, signingKey) = try signingKey(forPublicKeyBlob: Array(blob)) else { throw KeyStoreError.keyNotFound(id) }
        switch signingKey {
        case let key as Ed25519SigningKey: return (record, .ed25519(key.privateKey))
        case let key as P256SigningKey: return (record, .p256(key.privateKey))
        case let key as SecureEnclaveP256SigningKey: return (record, .secureEnclaveP256(key.privateKey))
        default: throw ClientKeyError.unsupportedAlgorithm(record.algorithm)
        }
    }

    // MARK: Files

    private func record(_ id: UUID) throws -> SSHKeyRecord {
        guard let record = key(id: id) else { throw KeyStoreError.keyNotFound(id) }
        return record
    }

    private struct MetadataFile: Codable {
        var version: Int
        var keys: [SSHKeyRecord]
    }

    private static func loadRecords(from url: URL) throws -> [SSHKeyRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(MetadataFile.self, from: Data(contentsOf: url))
            guard file.version == 1 else { throw KeyStoreError.storage("\(url.path) has unsupported version \(file.version).") }
            return file.keys.filter { (try? SSHPublicKey(blob: $0.publicKeyBlob)) != nil }
        } catch let error as KeyStoreError {
            throw error
        } catch {
            throw KeyStoreError.storage("Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    private func saveRecords(_ records: [SSHKeyRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try Self.createPrivateDirectory(metadataFile.deletingLastPathComponent())
            try encoder.encode(MetadataFile(version: 1, keys: records)).write(to: metadataFile, options: .atomic)
        } catch {
            throw KeyStoreError.storage("Could not write \(metadataFile.path): \(error.localizedDescription)")
        }
    }

    private func writePublicKeyFile(_ record: SSHKeyRecord) throws {
        let url = publicKeyFileURL(for: record.id)
        do {
            try Self.createPrivateDirectory(publicKeysDirectory)
            try Data((record.authorizedKeysLine + "\n").utf8).write(to: url, options: .atomic)
        } catch {
            throw KeyStoreError.storage("Could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Creates `url` (and missing parents) with mode 0700; leaves existing directories alone.
    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

extension SSHPublicKey {
    /// For blobs already validated elsewhere.
    init(unchecked blob: Data, keyType: String) {
        self.blob = blob
        self.keyType = keyType
    }
}
