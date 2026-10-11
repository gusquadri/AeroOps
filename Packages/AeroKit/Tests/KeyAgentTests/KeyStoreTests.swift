import CryptoKit
import Foundation
import Testing
@testable import KeyAgent

/// `swift test` binaries are ad-hoc signed, which cannot use the team's Keychain items, so these
/// tests use ``InMemorySecretStore``. ``KeychainSecretStore`` was proven with an Apple-Development
/// signed scratch binary.
@Suite("KeyStore")
struct KeyStoreTests {
    @Test func generateEd25519WritesMetadataPublicKeyAndSecret() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let secrets = InMemorySecretStore()
        let store = try makeKeyStore(dir, secrets: secrets)

        let record = try await store.generate(.ed25519, name: "Laptop", policy: .always)
        #expect(record.algorithm == .ed25519)
        #expect(record.origin == .generated)
        #expect(record.comment == "Laptop")
        #expect(record.fingerprint == SSHPublicKey.fingerprint(of: record.publicKeyBlob))
        #expect(secrets.storedIDs == [record.id])
        #expect(try secrets.load(for: record.id)?.count == 32)

        let pub = store.publicKeyFileURL(for: record.id)
        #expect(pub.lastPathComponent == "\(record.id.uuidString).pub")
        #expect(try String(contentsOf: pub, encoding: .utf8) == record.authorizedKeysLine + "\n")
        #expect(try await store.authorizedKeysLine(for: record.id) == record.authorizedKeysLine)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appending("pub").path)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        // Metadata is public-only: the secret never appears in keys.json.
        let json = try String(contentsOf: store.metadataFile, encoding: .utf8)
        let secret = try #require(try secrets.load(for: record.id))
        #expect(!json.contains(secret.base64EncodedString()))
        #expect(json.contains("\"version\" : 1"))
    }

    @Test func reloadServesTheSameKeysFromTheSecretStore() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let secrets = InMemorySecretStore()
        let first = try makeKeyStore(dir, secrets: secrets)
        let ed = try await first.generate(.ed25519, name: "One", policy: .oncePerSession)

        let second = try makeKeyStore(dir, secrets: secrets)
        #expect(await second.keys == [ed])
        let found = try #require(try await second.signingKey(forPublicKeyBlob: Array(ed.publicKeyBlob)))
        #expect(found.record == ed)
        let signature = try found.key.signature(for: [1, 2, 3], flags: 0)
        #expect(SignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: Array(ed.publicKeyBlob), data: [1, 2, 3]))
        #expect(try await second.signingKey(forPublicKeyBlob: [0, 0, 0, 1, 0x41]) == nil)
    }

    @Test func importDeduplicatesAndUsesCommentAsName() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let store = try makeKeyStore(dir)
        let generated = try await GeneratedOpenSSHKey.make(type: "ecdsa", bits: 256, comment: "ops@bastion", in: dir)

        let record = try await store.importOpenSSHPrivateKey(generated.privateKeyText, policy: .everySignature)
        #expect(record.name == "ops@bastion")
        #expect(record.origin == .imported)
        #expect(record.algorithm == .ecdsaP256)
        #expect(record.policy == .everySignature)
        #expect(record.authorizedKeysLine == generated.publicKeyLine)
        #expect(record.fingerprint == generated.fingerprint)

        await #expect(throws: KeyStoreError.duplicateKey(existing: record.id, name: "ops@bastion")) {
            try await store.importOpenSSHPrivateKey(generated.privateKeyText, name: "again")
        }
        await #expect(throws: KeyStoreError.importFailed(.notOpenSSHFormat(detected: nil))) {
            try await store.importOpenSSHPrivateKey("garbage")
        }
        #expect(await store.keys.count == 1)
    }

    @Test func renameAndPolicyPersist() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let secrets = InMemorySecretStore()
        let store = try makeKeyStore(dir, secrets: secrets)
        let record = try await store.generate(.ed25519, name: "Old", policy: .always)
        try await store.rename(id: record.id, to: "New")
        try await store.setPolicy(id: record.id, .everySignature)
        let reloaded = try makeKeyStore(dir, secrets: secrets)
        let key = try #require(await reloaded.key(id: record.id))
        #expect(key.name == "New")
        #expect(key.policy == .everySignature)
        #expect(key.comment == "Old") // The comment is part of the published key line and stays.
        await #expect(throws: KeyStoreError.keyNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)) {
            try await store.rename(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, to: "x")
        }
    }

    @Test func deleteRemovesSecretPublicKeyFileAndMetadata() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let secrets = InMemorySecretStore()
        let store = try makeKeyStore(dir, secrets: secrets)
        let keep = try await store.generate(.ed25519, name: "Keep")
        let gone = try await store.generate(.ed25519, name: "Gone")

        try await store.delete(id: gone.id)
        #expect(secrets.storedIDs == [keep.id])
        #expect(!FileManager.default.fileExists(atPath: store.publicKeyFileURL(for: gone.id).path))
        #expect(FileManager.default.fileExists(atPath: store.publicKeyFileURL(for: keep.id).path))
        #expect(await store.keys == [keep])
        #expect(try await makeKeyStore(dir, secrets: secrets).keys == [keep])
        #expect(try await store.signingKey(forPublicKeyBlob: Array(gone.publicKeyBlob)) == nil)
    }

    @Test func missingSecretIsReported() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let secrets = InMemorySecretStore()
        let first = try makeKeyStore(dir, secrets: secrets)
        let record = try await first.generate(.ed25519, name: "Orphan")
        try secrets.delete(for: record.id)
        let reloaded = try makeKeyStore(dir, secrets: secrets)
        await #expect(throws: KeyStoreError.missingSecret(record.id)) {
            try await reloaded.signingKey(forPublicKeyBlob: Array(record.publicKeyBlob))
        }
    }

    @Test func writePublicKeyFilesRestoresThem() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let store = try makeKeyStore(dir)
        let record = try await store.generate(.ed25519, name: "Restore")
        try FileManager.default.removeItem(at: dir.appending("pub"))
        try await store.writePublicKeyFiles()
        #expect(try String(contentsOf: store.publicKeyFileURL(for: record.id), encoding: .utf8) == record.authorizedKeysLine + "\n")
    }

    @Test func corruptMetadataThrows() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let support = dir.appending("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: support.appending(path: "keys.json"))
        #expect(throws: KeyStoreError.self) { try makeKeyStore(dir) }
        try Data(#"{"version": 2, "keys": []}"#.utf8).write(to: support.appending(path: "keys.json"))
        #expect(throws: KeyStoreError.self) { try makeKeyStore(dir) }
    }

    @Test(.enabled(if: SecureEnclave.isAvailable)) func secureEnclaveKeyStoresOnlyTheWrappedHandle() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let secrets = InMemorySecretStore()
        let store = try makeKeyStore(dir, secrets: secrets)
        let record = try await store.generate(.secureEnclaveP256, name: "Enclave", policy: .always)
        #expect(record.algorithm == .secureEnclaveP256)
        #expect(record.publicKey.keyType == "ecdsa-sha2-nistp256")
        let handle = try #require(try secrets.load(for: record.id))
        #expect(handle.count > 64) // a wrapped blob, not a raw 32-byte scalar

        let reloaded = try makeKeyStore(dir, secrets: secrets)
        let found = try #require(try await reloaded.signingKey(forPublicKeyBlob: Array(record.publicKeyBlob)))
        let signature = try found.key.signature(for: [9, 9], flags: 0)
        #expect(SignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: Array(record.publicKeyBlob), data: [9, 9]))
        try await store.delete(id: record.id)
        #expect(secrets.storedIDs.isEmpty)
    }
}
