import Foundation
import Testing
import AeroCore

/// `swift test` binaries cannot use the apps' Keychain access group, so these tests use
/// ``InMemoryKeychain``. ``SystemKeychain`` is checked by the signed app's `-AeroSelfTest sync`.
@Suite("HostStore")
@MainActor
struct HostStoreTests {
    let hosts = InMemoryKeychain()

    private func sampleHost(_ name: String = "web-01") -> RemoteHost {
        RemoteHost(name: name, address: "10.0.0.12", user: "deploy", tags: ["prod"])
    }

    private func device(tiers: InMemoryKeychain = InMemoryKeychain()) -> HostStore {
        HostStore(keychain: hosts, tiers: tiers)
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
}
