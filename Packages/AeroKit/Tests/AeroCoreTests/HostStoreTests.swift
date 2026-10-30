import Foundation
import Testing
import AeroCore

/// `swift test` binaries cannot use the apps' Keychain access group, so these tests use
/// ``InMemoryKeychain``. ``SystemKeychain`` is checked by the signed app's `-AeroSelfTest sync`.
@Suite("HostStore")
@MainActor
struct HostStoreTests {
    let hosts = InMemoryKeychain()
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "AeroOpsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func sampleHost(_ name: String = "web-01") -> RemoteHost {
        RemoteHost(name: name, address: "10.0.0.12", user: "deploy", tags: ["prod"])
    }

    private func device(tiers: InMemoryKeychain = InMemoryKeychain(), legacyFile: URL? = nil) -> HostStore {
        HostStore(keychain: hosts, tiers: tiers, legacyFile: legacyFile)
    }

    private func writeLegacyFile(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: HostStore.legacyFileName)
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test("add, update, delete round trip and survive a relaunch, oldest first")
    func roundTripAndRelaunch() throws {
        let tiers = InMemoryKeychain()
        let store = device(tiers: tiers)
        var a = sampleHost("a")
        let b = sampleHost("b")
        try store.add(a)
        try store.add(b)
        a.port = 2222
        a.mcpTier = .readExec
        try store.update(a)

        let relaunched = device(tiers: tiers)
        #expect(relaunched.hosts == [a, b])
        #expect(relaunched.loadError == nil)

        try relaunched.delete(id: b.id)
        #expect(device(tiers: tiers).hosts == [a])
        #expect(hosts.items().map(\.account) == [a.id.uuidString])
        #expect(tiers.items().map(\.account) == [a.id.uuidString])
    }

    @Test("hosts sync, but each device keeps its own MCP tier and arrivals start at off")
    func tierStaysOnEachDevice() throws {
        let mac = device()
        let phone = device()
        var host = sampleHost()
        host.mcpTier = .readExec
        try mac.add(host)
        #expect(hosts.items().map(\.syncs) == [true])
        #expect(!hosts.items()[0].record.contains(Data("readExec".utf8)))

        #expect(phone.reload())
        #expect(phone.hosts.map(\.mcpTier) == [.off])
        host.port = 2200
        try mac.update(host)
        #expect(phone.reload())
        #expect(phone.hosts.map(\.port) == [2200])
        #expect(phone.hosts.map(\.mcpTier) == [.off])
        #expect(mac.reload() == false)
        #expect(mac.hosts == [host])

        try phone.delete(id: host.id)
        #expect(mac.reload())
        #expect(mac.hosts.isEmpty)
    }

    @Test("duplicate add and unknown update/delete throw without changing anything")
    func invalidMutations() throws {
        let store = device()
        let host = sampleHost()
        try store.add(host)
        #expect(throws: HostStoreError.duplicateID(host.id)) { try store.add(host) }
        let stranger = sampleHost("stranger")
        #expect(throws: HostStoreError.notFound(stranger.id)) { try store.update(stranger) }
        #expect(throws: HostStoreError.notFound(stranger.id)) { try store.delete(id: stranger.id) }
        #expect(store.hosts.map(\.id) == [host.id])
        #expect(hosts.items().count == 1)
    }

    @Test("an older AeroOps's hosts.json moves over once, with its order and tiers")
    func legacyFileMoves() throws {
        let first = RemoteHost(name: "first", address: "a", user: "u", mcpTier: .readExec)
        let second = RemoteHost(name: "second", address: "b", user: "u", mcpTier: .off)
        let encoded = try String(decoding: JSONEncoder().encode([first, second]), as: UTF8.self)
        let file = try writeLegacyFile(#"{"version":1,"hosts":\#(encoded),"future":{}}"#)

        let tiers = InMemoryKeychain()
        let store = device(tiers: tiers, legacyFile: file)
        #expect(store.hosts == [first, second])
        #expect(store.loadError == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(device(tiers: tiers, legacyFile: file).hosts == [first, second])
    }

    @Test("a bare array is accepted; an unreadable hosts.json stays in place and is reported")
    func legacyFileVariants() throws {
        let id = UUID()
        let file = try writeLegacyFile(#"[{"id":"\#(id.uuidString)","name":"n","address":"a","user":"u","zzz":1}]"#)
        #expect(device(legacyFile: file).hosts.map(\.id) == [id])

        let garbage = try writeLegacyFile(#"{"version":1,"hosts":[{"name":"no id"}]}"#)
        let store = device(legacyFile: garbage)
        #expect(store.hosts.map(\.id) == [id])
        guard case .legacyFileUnreadable = store.loadError else {
            Issue.record("expected legacyFileUnreadable, got \(String(describing: store.loadError))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: garbage.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(kept.count == 1 && kept.allSatisfy { $0.hasPrefix("hosts.corrupt-") })
        #expect(store.loadError?.localizedDescription.contains(kept[0]) == true)

        store.reload()
        #expect(store.loadError == nil)
    }

    @Test("a hosts.json that cannot be read stays in place")
    func legacyFileUnreadableStays() throws {
        let file = directory.appending(path: HostStore.legacyFileName)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        guard case .legacyFileUnreadable = device(legacyFile: file).loadError else {
            Issue.record("expected legacyFileUnreadable")
            return
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
