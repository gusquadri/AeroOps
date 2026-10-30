import AeroCore
import CryptoKit
import Foundation
import Security

/// Non-secret metadata of one key, kept in the key's Keychain item beside the private part.
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
    /// Whether iCloud Keychain carries the key to the user's other devices. Kept by the Keychain
    /// item, not in the record.
    public var syncs = false

    /// Secure Enclave keys never leave the device that made them.
    public var canSync: Bool { algorithm != .secureEnclaveP256 }

    private enum CodingKeys: String, CodingKey {
        case id, name, algorithm, comment, publicKeyBlob, fingerprint, createdAt, policy, origin
    }

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
    case keychain(KeychainError)
    /// Only keys that can leave this device sync with iCloud Keychain.
    case deviceBound(UUID)
    /// The metadata names a key whose secret is gone (deleted outside the app).
    case missingSecret(UUID)
    /// The stored secret does not produce the recorded public key.
    case secretMismatch(UUID)
    case generationFailed(String)
    /// A `.pub` file (or an older AeroOps's `keys.json`) could not be read or written.
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .keyNotFound: "The key no longer exists."
        case .duplicateKey(_, let name): "This key is already stored as “\(name)”."
        case .secureEnclaveUnavailable: "This Mac has no Secure Enclave."
        case .importFailed(let error): error.errorDescription
        case .keychain(let error): error.errorDescription
        case .deviceBound: "Secure Enclave keys stay on the device that made them."
        case .missingSecret: "The key's private part is missing from the Keychain."
        case .secretMismatch: "The key's private part in the Keychain does not match its public key."
        case .generationFailed(let why): "Could not generate the key: \(why)"
        case .storage(let why): why
        }
    }
}

/// The app's SSH keys: one Keychain item per key (service ``keychainService``, account = key id)
/// holding the private part and the ``SSHKeyRecord``, and one `<key-id>.pub` file per key for
/// `IdentityFile` in the generated ssh_config. Keys that sync arrive on the user's other devices
/// with iCloud Keychain; ``reload()`` picks them up.
///
/// The signing policy belongs to each device, in a local item (`<key-id>.policy`): a key new to a
/// device signs no more freely than ``SigningPolicy/oncePerSession``, so relaxing a key on one
/// device relaxes it nowhere else.
///
/// ```swift
/// let store = try KeyStore(keychain: KeyStore.systemKeychain(), paths: .standard)
/// let key = try await store.generate(.secureEnclaveP256, name: "MacBook", policy: .oncePerSession)
/// print(key.authorizedKeysLine)
/// ```
public actor KeyStore {
    /// Directory of `<key-id>.pub` files (`~/.aeroops/pub/`).
    public nonisolated let publicKeysDirectory: URL

    /// The Keychain service of AeroOps key items.
    public static let keychainService = "app.aeroops.keys"
    /// Where an older AeroOps kept key metadata, in its metadata directory.
    static let legacyMetadataFileName = "keys.json"

    /// The Keychain store the app uses for keys.
    public static func systemKeychain(service: String = keychainService) -> SystemKeychain {
        SystemKeychain(service: service, label: "AeroOps SSH key")
    }

    private let keychain: any KeychainStore
    private var records: [SSHKeyRecord]
    /// Rebuilt signing keys, so the Keychain is read once per key per app run.
    private var signingKeyCache: [UUID: any SSHSigningKey] = [:]

    /// The app's store, with public keys in `~/.aeroops/pub/`.
    public init(keychain: any KeychainStore, paths: AeroPaths = .standard) throws {
        try self.init(keychain: keychain, publicKeysDirectory: paths.publicKeysDirectory)
    }

    /// A store with an explicit public key directory (tests). A device that has not been unlocked
    /// yet starts with no keys; ``reload()`` picks them up later.
    public init(keychain: any KeychainStore, publicKeysDirectory: URL) throws {
        self.keychain = keychain
        self.publicKeysDirectory = publicKeysDirectory
        do {
            self.records = try Self.loadRecords(from: keychain)
        } catch KeyStoreError.keychain(.interactionRequired) {
            self.records = []
        }
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

    /// Generates a key. Ed25519 keys are stored in the Keychain and sync when `syncs` is set; Secure
    /// Enclave keys never leave the enclave, and only their wrapped handle is stored, on this device.
    @discardableResult
    public func generate(
        _ type: KeyGenerationType, name: String, comment: String? = nil, policy: SigningPolicy = .oncePerSession, syncs: Bool = true
    ) throws -> SSHKeyRecord {
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
            algorithm: type.algorithm, name: name, comment: comment ?? name, policy: policy, syncs: syncs, origin: .generated,
            publicKeyBlob: signingKey.publicKeyBlob, secret: secret, signingKey: signingKey)
    }

    /// Imports an unencrypted OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`):
    /// Ed25519, ECDSA P-256 or RSA (≥ 1024 bits). `name` defaults to the key's comment.
    ///
    /// The private key moves into the Keychain; this does not touch the original file.
    @discardableResult
    public func importOpenSSHPrivateKey(
        _ text: String, name: String? = nil, policy: SigningPolicy = .oncePerSession, syncs: Bool = true
    ) throws -> SSHKeyRecord {
        let parsed: OpenSSHPrivateKey
        do {
            parsed = try OpenSSHPrivateKey.parse(text)
        } catch {
            throw KeyStoreError.importFailed(error)
        }
        let fallbackName = parsed.comment.isEmpty ? "Imported \(parsed.algorithm.displayName) key" : parsed.comment
        let chosenName = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? fallbackName
        return try add(
            algorithm: parsed.algorithm, name: chosenName, comment: parsed.comment, policy: policy, syncs: syncs, origin: .imported,
            publicKeyBlob: parsed.publicKeyBlob, secret: parsed.secret, signingKey: parsed.signingKey)
    }

    private func add(
        algorithm: SSHKeyAlgorithm, name: String, comment: String, policy: SigningPolicy, syncs: Bool, origin: SSHKeyRecord.Origin,
        publicKeyBlob: [UInt8], secret: Data, signingKey: any SSHSigningKey
    ) throws -> SSHKeyRecord {
        let blob = Data(publicKeyBlob)
        if let existing = records.first(where: { $0.publicKeyBlob == blob }) {
            throw KeyStoreError.duplicateKey(existing: existing.id, name: existing.name)
        }
        let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var record = SSHKeyRecord(
            id: UUID(), name: name, algorithm: algorithm, comment: SSHPublicKey.sanitizedComment(comment),
            publicKeyBlob: blob, fingerprint: SSHPublicKey.fingerprint(of: blob), createdAt: createdAt,
            policy: policy, origin: origin)
        record.syncs = syncs && record.canSync
        try store(record, secret: secret)
        signingKeyCache[record.id] = signingKey
        return record
    }

    /// Saves a new key's Keychain item and `.pub` file; on failure neither is left behind.
    private func store(_ record: SSHKeyRecord, secret: Data) throws {
        let item = try Self.item(record)
        do {
            try keychain.save(Self.policyItem(record), secret: Data())
            try keychain.save(item, secret: secret)
        } catch {
            throw KeyStoreError.keychain(error)
        }
        do {
            try writePublicKeyFile(record)
        } catch {
            try? keychain.delete(record.id.uuidString)
            try? keychain.delete(Self.policyAccount(record.id))
            throw error
        }
        records.append(record)
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

    /// Turns iCloud Keychain sync on or off for a key. Turning it off removes the key from the
    /// user's other devices.
    public func setSyncs(id: UUID, _ syncs: Bool) throws {
        let canSync = try record(id).canSync
        guard canSync || !syncs else { throw KeyStoreError.deviceBound(id) }
        try update(id) { $0.syncs = syncs }
    }

    private func update(_ id: UUID, _ change: (inout SSHKeyRecord) -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw KeyStoreError.keyNotFound(id) }
        var updated = records[index]
        change(&updated)
        let item = try Self.item(updated)
        do {
            try keychain.update(item)
            try keychain.save(Self.policyItem(updated), secret: Data())
        } catch {
            throw KeyStoreError.keychain(error)
        }
        records[index] = updated
    }

    /// Deletes the key's Keychain item (on every device it syncs to) and its `.pub` file. The item
    /// goes first, so a failure leaves the key listed and the user can retry.
    public func delete(id: UUID) throws {
        guard records.contains(where: { $0.id == id }) else { throw KeyStoreError.keyNotFound(id) }
        do {
            try keychain.delete(id.uuidString)
            try keychain.delete(Self.policyAccount(id))
        } catch {
            throw KeyStoreError.keychain(error)
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
        records.removeAll { $0.id == id }
    }

    /// Rewrites every `.pub` file (e.g. at launch, in case `~/.aeroops/pub/` was cleared).
    public func writePublicKeyFiles() throws {
        for record in records { try writePublicKeyFile(record) }
    }

    /// Re-reads the Keychain, for keys added, changed or deleted on the user's other devices, and
    /// brings the `.pub` files in line. Returns whether the keys changed.
    @discardableResult
    public func reload() throws -> Bool {
        let current = try Self.loadRecords(from: keychain)
        guard current != records else { return false }
        let removed = Set(records.map(\.id)).subtracting(current.map(\.id))
        for id in removed {
            signingKeyCache[id] = nil
            try? keychain.delete(Self.policyAccount(id))
            try? FileManager.default.removeItem(at: publicKeyFileURL(for: id))
        }
        records = current
        try writePublicKeyFiles()
        return true
    }

    /// Moves the keys of an older AeroOps (`keys.json` in `metadataDirectory`, private parts in
    /// `legacySecrets`) into the Keychain, syncing the ones that can, then deletes the old copies.
    /// A failure leaves the rest of the old copies for the next launch. Returns how many moved.
    @discardableResult
    public func importLegacyKeys(metadataDirectory: URL, secrets legacySecrets: any SecretStore) throws -> Int {
        let file = metadataDirectory.appending(path: Self.legacyMetadataFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        let legacy = try Self.legacyRecords(at: file)
        var moved = 0
        for var record in legacy where key(id: record.id) == nil {
            guard let secret = try Self.legacySecret(of: record, in: legacySecrets) else { continue }
            record.syncs = record.canSync
            try store(record, secret: secret)
            moved += 1
        }
        records.sort(by: Self.oldestFirst)
        for record in legacy { try? legacySecrets.delete(for: record.id) }
        try? FileManager.default.removeItem(at: file)
        return moved
    }

    // MARK: Agent

    /// The keys the agent offers, in order.
    func identities() -> [SSHKeyRecord] { records }

    /// The record and signing key for a public key blob, or `nil` when no stored key has it.
    func signingKey(forPublicKeyBlob blob: [UInt8]) throws -> (record: SSHKeyRecord, key: any SSHSigningKey)? {
        guard let record = records.first(where: { $0.publicKeyBlob.elementsEqual(blob) }) else { return nil }
        if let cached = signingKeyCache[record.id] { return (record, cached) }
        let key = try loadSigningKey(record)
        signingKeyCache[record.id] = key
        return (record, key)
    }

    private func loadSigningKey(_ record: SSHKeyRecord) throws -> any SSHSigningKey {
        let secret: Data?
        do {
            secret = try keychain.secret(for: record.id.uuidString)
        } catch {
            throw KeyStoreError.keychain(error)
        }
        guard let secret else { throw KeyStoreError.missingSecret(record.id) }
        let key: any SSHSigningKey
        do {
            key = try SigningKeyFactory.make(record.algorithm, secret: secret)
        } catch {
            throw KeyStoreError.secretMismatch(record.id)
        }
        guard key.publicKeyBlob.elementsEqual(record.publicKeyBlob) else { throw KeyStoreError.secretMismatch(record.id) }
        return key
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

    /// The Keychain item of `record`: the record as JSON (dates in whole seconds, ISO 8601).
    static func item(_ record: SSHKeyRecord) throws -> KeychainItem {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return KeychainItem(account: record.id.uuidString, record: try encoder.encode(record), syncs: record.syncs)
    }

    /// Every key in the Keychain, oldest first. Items whose record does not decode, or whose
    /// public key is invalid, are skipped.
    private static func loadRecords(from keychain: any KeychainStore) throws -> [SSHKeyRecord] {
        let items: [KeychainItem]
        do {
            items = try keychain.items()
        } catch {
            throw KeyStoreError.keychain(error)
        }
        let policies = localPolicies(in: items)
        return items.compactMap { record($0, policies: policies) }.sorted(by: oldestFirst)
    }

    private static func policyAccount(_ id: UUID) -> String {
        id.uuidString + ".policy"
    }

    private static func policyItem(_ record: SSHKeyRecord) -> KeychainItem {
        KeychainItem(account: policyAccount(record.id), record: Data(record.policy.rawValue.utf8), syncs: false)
    }

    /// The policies chosen on this device, by account. A synced item is never this device's choice.
    private static func localPolicies(in items: [KeychainItem]) -> [String: SigningPolicy] {
        let pairs = items.filter { !$0.syncs }.compactMap { item in
            SigningPolicy(rawValue: String(decoding: item.record, as: UTF8.self)).map { (item.account, $0) }
        }
        return Dictionary(pairs) { first, _ in first }
    }

    /// The policy of a key new to this device.
    private static func arrivalPolicy(_ policy: SigningPolicy) -> SigningPolicy {
        policy == .always ? .oncePerSession : policy
    }

    private static func oldestFirst(_ a: SSHKeyRecord, _ b: SSHKeyRecord) -> Bool {
        (a.createdAt, a.id.uuidString) < (b.createdAt, b.id.uuidString)
    }

    private static func record(_ item: KeychainItem, policies: [String: SigningPolicy]) -> SSHKeyRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var record = try? decoder.decode(SSHKeyRecord.self, from: item.record),
              record.id.uuidString == item.account, (try? SSHPublicKey(blob: record.publicKeyBlob)) != nil else { return nil }
        record.syncs = item.syncs
        record.policy = policies[policyAccount(record.id)] ?? arrivalPolicy(record.policy)
        return record
    }

    private struct LegacyMetadataFile: Decodable {
        var keys: [SSHKeyRecord]
    }

    private static func legacyRecords(at url: URL) throws -> [SSHKeyRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(LegacyMetadataFile.self, from: Data(contentsOf: url)).keys
        } catch {
            throw KeyStoreError.storage("Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    private static func legacySecret(of record: SSHKeyRecord, in store: any SecretStore) throws -> Data? {
        do {
            return try store.load(for: record.id)
        } catch {
            throw KeyStoreError.storage("Could not move “\(record.name)” from the old Keychain: \(error.localizedDescription)")
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
