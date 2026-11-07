import AeroCore
import CryptoKit
import Foundation
import Testing
@testable import KeyAgent

/// `swift test` binaries are ad-hoc signed, which cannot use the team's Keychain access group, so
/// these tests use ``InMemoryKeychain``. ``SystemKeychain`` is checked by the signed app's
/// `-AeroSelfTest sync`.
@Suite("KeyStore")
struct KeyStoreTests {
    @Test func generateEd25519StoresOneSyncingItemAndThePublicKeyFile() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let keychain = InMemoryKeychain()
        let store = try makeKeyStore(dir, keychain: keychain)

        let record = try await store.generate(.ed25519, name: "Laptop", policy: .always)
        #expect(record.algorithm == .ed25519)
        #expect(record.origin == .generated)
        #expect(record.comment == "Laptop")
        #expect(record.syncs)
        #expect(record.fingerprint == SSHPublicKey.fingerprint(of: record.publicKeyBlob))
        let item = try #require(keyItems(keychain).first)
        #expect(keyItems(keychain).count == 1)
        #expect(item.account == record.id.uuidString)
        #expect(item.syncs)
        let secret = try #require(keychain.secret(for: item.account))
        #expect(secret.count == 32)
        #expect(!item.record.contains(secret))

        let pub = store.publicKeyFileURL(for: record.id)
        #expect(pub.lastPathComponent == "\(record.id.uuidString).pub")
        #expect(try String(contentsOf: pub, encoding: .utf8) == record.authorizedKeysLine + "\n")
        #expect(try await store.authorizedKeysLine(for: record.id) == record.authorizedKeysLine)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appending("pub").path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func aNewStoreServesTheSameKeysFromTheKeychain() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let keychain = InMemoryKeychain()
        let first = try makeKeyStore(dir, keychain: keychain)
        let ed = try await first.generate(.ed25519, name: "One", policy: .oncePerSession)

        let second = try makeKeyStore(dir, keychain: keychain)
        #expect(await second.keys == [ed])
        let found = try #require(try await second.signingKey(forPublicKeyBlob: Array(ed.publicKeyBlob)))
        #expect(found.record == ed)
        let signature = try found.key.signature(for: [1, 2, 3], flags: 0)
        #expect(SignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: Array(ed.publicKeyBlob), data: [1, 2, 3]))
        #expect(try await second.signingKey(forPublicKeyBlob: [0, 0, 0, 1, 0x41]) == nil)
    }

    @Test func keysFromAnotherDeviceArriveAndLeaveOnReload() async throws {
        let mac = try TempDirectory()
        let phone = try TempDirectory()
        defer { mac.remove(); phone.remove() }
        let keychain = InMemoryKeychain()
        let macStore = try makeKeyStore(mac, keychain: keychain)
        let phoneStore = try makeKeyStore(phone, keychain: keychain)

        let key = try await macStore.generate(.ed25519, name: "Shared")
        #expect(try await phoneStore.reload())
        #expect(await phoneStore.keys == [key])
        #expect(FileManager.default.fileExists(atPath: phoneStore.publicKeyFileURL(for: key.id).path))
        #expect(try await phoneStore.reload() == false)

        try await macStore.delete(id: key.id)
        #expect(try await phoneStore.reload())
        #expect(await phoneStore.keys.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: phoneStore.publicKeyFileURL(for: key.id).path))
    }

    @Test func syncCanBeTurnedOffAndOn() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let keychain = InMemoryKeychain()
        let store = try makeKeyStore(dir, keychain: keychain)
        let record = try await store.generate(.ed25519, name: "Mine", syncs: false)
        #expect(!record.syncs)
        #expect(keyItems(keychain).map(\.syncs) == [false])

        try await store.setSyncs(id: record.id, true)
        #expect(keyItems(keychain).map(\.syncs) == [true])
        #expect(try await makeKeyStore(dir, keychain: keychain).keys.map(\.syncs) == [true])
        #expect(keychain.secret(for: record.id.uuidString)?.count == 32)
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

    @Test func aStoreOpenedBeforeTheFirstUnlockGetsItsKeysLater() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let keychain = LockableKeychain()
        let record = try await makeKeyStore(dir, keychain: keychain.inner).generate(.ed25519, name: "Mine")
        keychain.setLocked(true)

        let store = try KeyStore(keychain: keychain, publicKeysDirectory: dir.appending("pub"))
        #expect(await store.keys.isEmpty)
        await #expect(throws: KeyStoreError.keychain(.interactionRequired(operation: "test"))) { try await store.reload() }

        keychain.setLocked(false)
        #expect(try await store.reload())
        #expect(await store.keys == [record])
    }

    @Test func aSigningPolicyBelongsToItsDevice() async throws {
        let macDirectory = try TempDirectory()
        let phoneDirectory = try TempDirectory()
        defer {
            macDirectory.remove()
            phoneDirectory.remove()
        }
        let macKeychain = InMemoryKeychain()
        let mac = try makeKeyStore(macDirectory, keychain: macKeychain)
        let relaxed = try await mac.generate(.ed25519, name: "Relaxed", policy: .always)
        let strict = try await mac.generate(.ed25519, name: "Strict", policy: .everySignature)

        let phoneKeychain = InMemoryKeychain()
        for item in macKeychain.items() where item.syncs {
            phoneKeychain.save(item, secret: try #require(macKeychain.secret(for: item.account)))
        }
        let phone = try makeKeyStore(phoneDirectory, keychain: phoneKeychain)
        #expect(await phone.key(id: relaxed.id)?.policy == .oncePerSession)
        #expect(await phone.key(id: strict.id)?.policy == .everySignature)
        #expect(await mac.key(id: relaxed.id)?.policy == .always)

        try await phone.setPolicy(id: strict.id, .always)
        #expect(try await phone.reload() == false)
        #expect(await phone.key(id: strict.id)?.policy == .always)
        #expect(await mac.key(id: strict.id)?.policy == .everySignature)

        let forged = KeychainItem(account: relaxed.id.uuidString + ".policy", record: Data("always".utf8), syncs: true)
        phoneKeychain.save(forged, secret: Data())
        try await phone.reload()
        #expect(await phone.key(id: relaxed.id)?.policy == .oncePerSession)

        phoneKeychain.delete(strict.id.uuidString)
        try await phone.reload()
        #expect(phoneKeychain.secret(for: strict.id.uuidString + ".policy") == nil)
    }

    @Test func renameAndPolicyPersist() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let keychain = InMemoryKeychain()
        let store = try makeKeyStore(dir, keychain: keychain)
        let record = try await store.generate(.ed25519, name: "Old", policy: .always)
        try await store.rename(id: record.id, to: "New")
        try await store.setPolicy(id: record.id, .everySignature)
        let reloaded = try makeKeyStore(dir, keychain: keychain)
        let key = try #require(await reloaded.key(id: record.id))
        #expect(key.name == "New")
        #expect(key.policy == .everySignature)
        #expect(key.comment == "Old")
        await #expect(throws: KeyStoreError.keyNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)) {
            try await store.rename(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, to: "x")
        }
    }

    @Test func deleteRemovesTheItemAndThePublicKeyFile() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let keychain = InMemoryKeychain()
        let store = try makeKeyStore(dir, keychain: keychain)
        let keep = try await store.generate(.ed25519, name: "Keep")
        let gone = try await store.generate(.ed25519, name: "Gone")

        try await store.delete(id: gone.id)
        #expect(keyItems(keychain).map(\.account) == [keep.id.uuidString])
        #expect(!FileManager.default.fileExists(atPath: store.publicKeyFileURL(for: gone.id).path))
        #expect(FileManager.default.fileExists(atPath: store.publicKeyFileURL(for: keep.id).path))
        #expect(await store.keys == [keep])
        #expect(try await makeKeyStore(dir, keychain: keychain).keys == [keep])
        #expect(try await store.signingKey(forPublicKeyBlob: Array(gone.publicKeyBlob)) == nil)
    }

    @Test func missingSecretIsReported() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let keychain = InMemoryKeychain()
        let record = try await makeKeyStore(dir, keychain: keychain).generate(.ed25519, name: "Orphan")
        let stale = try makeKeyStore(dir, keychain: keychain)
        keychain.delete(record.id.uuidString)
        await #expect(throws: KeyStoreError.missingSecret(record.id)) {
            try await stale.signingKey(forPublicKeyBlob: Array(record.publicKeyBlob))
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

    @Test(.enabled(if: SecureEnclave.isAvailable)) func secureEnclaveKeyStaysOnThisDevice() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let keychain = InMemoryKeychain()
        let store = try makeKeyStore(dir, keychain: keychain)
        let record = try await store.generate(.secureEnclaveP256, name: "Enclave", policy: .always)
        #expect(record.algorithm == .secureEnclaveP256)
        #expect(record.publicKey.keyType == "ecdsa-sha2-nistp256")
        #expect(!record.syncs && !record.canSync)
        #expect(keyItems(keychain).map(\.syncs) == [false])
        let handle = try #require(keychain.secret(for: record.id.uuidString))
        #expect(handle.count > 64)
        await #expect(throws: KeyStoreError.deviceBound(record.id)) { try await store.setSyncs(id: record.id, true) }

        let reloaded = try makeKeyStore(dir, keychain: keychain)
        let found = try #require(try await reloaded.signingKey(forPublicKeyBlob: Array(record.publicKeyBlob)))
        let signature = try found.key.signature(for: [9, 9], flags: 0)
        #expect(SignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: Array(record.publicKeyBlob), data: [9, 9]))
        try await store.delete(id: record.id)
        #expect(keychain.items().isEmpty)
    }
}
