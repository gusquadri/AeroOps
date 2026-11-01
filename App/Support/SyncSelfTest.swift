#if DEBUG
import AeroCore
import AppKit
import CryptoKit
import Foundation
import KeyAgent
import Security
import SSHKit

/// `-AeroSelfTest sync`: proves in the signed app that keys, passwords, hosts and pinned host keys
/// go to iCloud Keychain (`swift test` binaries cannot use the shared access group).
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest sync -AeroSelfTestOutput /tmp/aeroops-sync.json
/// ```
///
/// Two key stores over one Keychain service stand in for the Mac and the iPhone: a key made in
/// one reaches the other on reload, stops syncing and syncs again as a single item, and leaves
/// both when deleted. A Secure Enclave key stays on this Mac, and a saved password syncs. A host
/// syncs while its MCP tier stays on this Mac, and a pin made in one host-key store reaches the
/// other's known_hosts copy. Everything lives in self-test services and is deleted at the end;
/// real keys, passwords, hosts and pins are not touched. Writes a JSON report (`"ok": true` on
/// success) and quits.
///
/// Not covered: the items arriving on another device. Check that by hand on a real iPhone.
@MainActor
struct SyncSelfTest {
    static let keyService = "app.aeroops.keys.selftest.sync"
    static let passwordService = "app.aeroops.passwords.selftest.sync"
    static let hostService = "app.aeroops.hosts.selftest.sync"
    static let pinService = "app.aeroops.host-keys.selftest.sync"

    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    struct Report: Codable {
        var ok = false
        var steps: [Step] = []
    }

    @MainActor
    private final class Recorder {
        var report = Report()

        func check(_ name: String, _ body: () async throws -> String) async {
            let step: Step
            do {
                step = Step(name: name, ok: true, detail: try await body())
            } catch {
                step = Step(name: name, ok: false, detail: error.localizedDescription)
            }
            report.steps.append(step)
            print("[selftest] \(step.ok ? "PASS" : "FAIL") \(name): \(step.detail)")
        }
    }

    private struct Failure: LocalizedError {
        var errorDescription: String?
    }

    func runAndQuit() async {
        let report = await run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: url, options: .atomic)
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED")")
        NSApp.terminate(nil)
    }

    func run() async -> Report {
        let r = Recorder()
        let root = URL.temporaryDirectory.appending(path: "aero-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        let keychain = KeyStore.systemKeychain(service: Self.keyService)
        let passwords = SystemKeychain(service: Self.passwordService, label: "AeroOps sync self-test password")
        let hosts = SystemKeychain(service: Self.hostService, label: "AeroOps sync self-test host")
        let tiers = SystemKeychain(service: Self.hostService + ".mcp-tiers", label: "AeroOps sync self-test tier")
        let pins = HostKeyStore.systemKeychain(service: Self.pinService)
        Self.removeAll(keychain, passwords, hosts, tiers, pins)
        await r.check("a key syncs between stores") { try await keySyncs(keychain, root: root) }
        await r.check("a Secure Enclave key stays on this Mac") { try await enclaveKeyStays(keychain, root: root) }
        await r.check("a saved password syncs") { try passwordSyncs(passwords) }
        await r.check("items open behind a locked screen") { try lockedScreenAccess(passwords) }
        await r.check("a host syncs, its MCP tier stays here") { try hostSyncs(hosts, tiers: tiers) }
        await r.check("a pinned host key syncs") { try await pinSyncs(pins, root: root) }
        Self.removeAll(keychain, passwords, hosts, tiers, pins)
        try? FileManager.default.removeItem(at: root)
        r.report.ok = r.report.steps.allSatisfy { $0.ok }
        return r.report
    }

    private func keySyncs(_ keychain: SystemKeychain, root: URL) async throws -> String {
        let mac = try KeyStore(keychain: keychain, publicKeysDirectory: root.appending(path: "mac"))
        let phone = try KeyStore(keychain: keychain, publicKeysDirectory: root.appending(path: "phone"))
        let key = try await mac.generate(.ed25519, name: "AeroOps sync self-test", policy: .always)
        try Self.expect(Self.keyItems(keychain).map(\.syncs) == [true], "the new key's item is not synchronizable")
        try await phone.reload()
        try Self.expect(await phone.keys.map(\.id) == [key.id], "the other store did not get the key")
        try await mac.setSyncs(id: key.id, false)
        try Self.expect(Self.keyItems(keychain).map(\.syncs) == [false], "turning sync off did not leave one local item")
        try await mac.setSyncs(id: key.id, true)
        try Self.expect(Self.keyItems(keychain).map(\.syncs) == [true], "turning sync on did not leave one synchronizable item")
        try Self.expect(keychain.secret(for: key.id.uuidString)?.count == 32, "the private key did not survive the changes")
        try await mac.delete(id: key.id)
        try await phone.reload()
        try Self.expect(await phone.keys.isEmpty, "the deleted key is still in the other store")
        return key.fingerprint
    }

    private func enclaveKeyStays(_ keychain: SystemKeychain, root: URL) async throws -> String {
        guard SecureEnclave.isAvailable else { return "skipped: no Secure Enclave" }
        let store = try KeyStore(keychain: keychain, publicKeysDirectory: root.appending(path: "enclave"))
        let key = try await store.generate(.secureEnclaveP256, name: "AeroOps sync self-test enclave", policy: .always)
        let syncs = try Self.keyItems(keychain).map(\.syncs)
        try await store.delete(id: key.id)
        try Self.expect(syncs == [false], "the Secure Enclave key's item syncs")
        return "its item stays on this Mac"
    }

    private func passwordSyncs(_ keychain: SystemKeychain) throws -> String {
        let vault = HostPasswordVault(keychain: keychain)
        let host = UUID()
        try vault.save("AeroOps sync self-test", for: host)
        let items = try keychain.items()
        try vault.delete(for: host)
        try Self.expect(items.map(\.account) == [host.uuidString] && items.allSatisfy { $0.syncs }, "the password is not synchronizable")
        try Self.expect(keychain.items().isEmpty, "the password was not deleted")
        return "saved as a synchronizable item"
    }

    private func lockedScreenAccess(_ keychain: SystemKeychain) throws -> String {
        let synced = KeychainItem(account: UUID().uuidString, syncs: true)
        let local = KeychainItem(account: UUID().uuidString, syncs: false)
        try keychain.save(synced, secret: Data())
        try keychain.save(local, secret: Data())
        defer { Self.removeAll(keychain) }
        let classes = try Self.accessibilityClasses(service: Self.passwordService)
        try Self.expect(classes == [kSecAttrAccessibleAfterFirstUnlock as String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String], "classes: \(classes)")
        return classes.joined(separator: ", ")
    }

    private static func accessibilityClasses(service: String) throws -> Set<String> {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny, kSecAttrAccessGroup: SystemKeychain.sharedAccessGroup,
            kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try expect(status == errSecSuccess, "SecItemCopyMatching failed: \(status)")
        let items = result as? [[String: Any]] ?? []
        return Set(items.compactMap { $0[kSecAttrAccessible as String] as? String })
    }

    private static func keyItems(_ keychain: SystemKeychain) throws -> [KeychainItem] {
        try keychain.items().filter { UUID(uuidString: $0.account) != nil }
    }

    private func hostSyncs(_ hosts: SystemKeychain, tiers: SystemKeychain) throws -> String {
        let mac = HostStore(keychain: hosts, tiers: tiers)
        let phone = HostStore(keychain: hosts, tiers: InMemoryKeychain())
        let host = RemoteHost(name: "AeroOps sync self-test", address: "192.0.2.1", user: "selftest", mcpTier: .readExec)
        try mac.add(host)
        let synced = try hosts.items()
        let local = try tiers.items()
        phone.reload()
        let arrived = phone.hosts
        try mac.delete(id: host.id)
        let left = try hosts.items().count + tiers.items().count
        let leaksTier = synced.contains { $0.record.contains(Data("readExec".utf8)) }
        try Self.expect(synced.map(\.syncs) == [true] && !leaksTier, "the host item does not sync, or carries the tier")
        try Self.expect(local.map(\.syncs) == [false], "the MCP tier item syncs")
        try Self.expect(arrived.map(\.id) == [host.id] && arrived.map(\.mcpTier) == [.off], "the other store got \(arrived)")
        try Self.expect(left == 0, "the host was not deleted")
        return "the host syncs; its MCP tier stays on this Mac"
    }

    private func pinSyncs(_ pins: SystemKeychain, root: URL) async throws -> String {
        let macFile = root.appending(path: "mac_known_hosts")
        let mac = HostKeyStore(keychain: pins, knownHostsFile: macFile)
        let phone = HostKeyStore(keychain: pins, knownHostsFile: root.appending(path: "phone_known_hosts"))
        let host = RemoteHost(name: "AeroOps sync self-test", address: "192.0.2.1", user: "selftest")
        let key = SampleHostKeys.ed25519(seed: 1)
        try await phone.trust(key, for: host)
        let syncs = try pins.items().map(\.syncs)
        let changed = try await mac.refreshKnownHostsFile()
        let mirrored = try String(contentsOf: macFile, encoding: .utf8)
        try await phone.forget(host)
        try Self.expect(syncs == [true], "the pin's item is not synchronizable")
        try Self.expect(changed && mirrored.contains(key.base64), "the other store's known_hosts did not get the pin")
        try Self.expect(try pins.items().isEmpty, "the pin was not forgotten")
        return "the pin syncs and reaches the other store's known_hosts"
    }

    private static func expect(_ condition: Bool, _ failure: String) throws {
        if !condition { throw Failure(errorDescription: failure) }
    }

    private static func removeAll(_ stores: SystemKeychain...) {
        for store in stores {
            for item in (try? store.items()) ?? [] { try? store.delete(item.account) }
        }
    }
}
#endif
