import Foundation
import Testing
import AeroCore

@Suite("HostStore folders and order")
@MainActor
struct HostFolderTests {
    let hosts = InMemoryKeychain()

    private func device() -> HostStore {
        HostStore(keychain: hosts, tiers: InMemoryKeychain())
    }

    private func store(with names: [String]) throws -> (HostStore, [RemoteHost]) {
        let store = device()
        let added = names.map { RemoteHost(name: $0, address: "10.0.0.1", user: "deploy") }
        for host in added { try store.add(host) }
        return (store, added)
    }

    @Test("dropping a host onto another reorders, forward and back, and survives a relaunch")
    func reorder() throws {
        let (store, h) = try store(with: ["a", "b", "c", "d"])
        try store.moveHost(h[0].id, onto: h[2].id)
        #expect(store.hosts.map(\.name) == ["b", "c", "a", "d"])
        try store.moveHost(h[3].id, onto: h[1].id)
        #expect(store.hosts.map(\.name) == ["d", "b", "c", "a"])
        try store.moveHost(h[1].id, onto: h[0].id)
        #expect(store.hosts.map(\.name) == ["d", "c", "a", "b"])
        #expect(device().hosts.map(\.name) == ["d", "c", "a", "b"])
    }

    @Test("a host added after a move goes last")
    func addAfterMove() throws {
        let (store, h) = try store(with: ["a", "b"])
        try store.moveHost(h[0].id, toFolder: nil)
        try store.add(RemoteHost(name: "c", address: "10.0.0.3", user: "deploy"))
        #expect(store.hosts.map(\.name) == ["b", "a", "c"])
    }

    @Test("many moves into the same gap keep the order")
    func repeatedMidpoints() throws {
        let (store, h) = try store(with: ["a", "b", "c"])
        for _ in 0..<80 {
            try store.moveHost(h[2].id, toFolder: nil, before: h[1].id)
            try store.moveHost(h[1].id, toFolder: nil, before: h[2].id)
        }
        #expect(store.hosts.map(\.name) == ["a", "b", "c"])
        #expect(device().hosts.map(\.name) == ["a", "b", "c"])
    }

    @Test("hosts move into and out of folders, which sync and keep their order")
    func folders() throws {
        let (mac, h) = try store(with: ["a", "b", "c"])
        let prod = try mac.addFolder(named: "  Production ")
        let lab = try mac.addFolder(named: "Lab")
        #expect(prod.name == "Production")
        try mac.moveHost(h[2].id, toFolder: prod.id)
        try mac.moveHost(h[0].id, toFolder: prod.id)
        #expect(mac.hosts(inFolder: prod.id).map(\.name) == ["c", "a"])
        #expect(mac.hosts(inFolder: nil).map(\.name) == ["b"])
        #expect(mac.folderID(ofHost: h[0].id) == prod.id)

        try mac.moveHost(h[0].id, onto: h[2].id)
        #expect(mac.hosts(inFolder: prod.id).map(\.name) == ["a", "c"])
        try mac.moveHost(h[1].id, onto: h[2].id)
        #expect(mac.hosts(inFolder: prod.id).map(\.name) == ["a", "b", "c"])

        try mac.moveFolder(lab.id, before: prod.id)
        let phone = device()
        #expect(phone.folders.map(\.name) == ["Lab", "Production"])
        #expect(phone.hosts(inFolder: prod.id).map(\.name) == ["a", "b", "c"])

        try phone.renameFolder(id: lab.id, to: "Staging")
        #expect(mac.reload())
        #expect(mac.folders.map(\.name) == ["Staging", "Production"])
    }

    @Test("editing a host keeps its folder and position")
    func updateKeepsPlacement() throws {
        let (store, h) = try store(with: ["a", "b"])
        let folder = try store.addFolder(named: "Prod")
        try store.moveHost(h[1].id, toFolder: folder.id)
        try store.moveHost(h[0].id, toFolder: folder.id)
        var b = h[1]
        b.port = 2222
        try store.update(b)
        #expect(device().hosts(inFolder: folder.id).map(\.name) == ["b", "a"])
    }

    @Test("deleting a folder keeps its hosts, last and in order")
    func deleteFolder() throws {
        let (store, h) = try store(with: ["a", "b", "c"])
        let folder = try store.addFolder(named: "Prod")
        try store.moveHost(h[1].id, toFolder: folder.id)
        try store.moveHost(h[0].id, toFolder: folder.id)
        try store.deleteFolder(id: folder.id)
        #expect(store.folders.isEmpty)
        #expect(store.hosts(inFolder: nil).map(\.name) == ["c", "b", "a"])
        #expect(hosts.items().count == 3)
    }

    @Test("a host whose folder was deleted elsewhere is in no folder")
    func orphan() throws {
        let (mac, h) = try store(with: ["a"])
        let folder = try mac.addFolder(named: "Prod")
        try mac.moveHost(h[0].id, toFolder: folder.id)
        try hosts.delete("folder." + folder.id.uuidString)
        #expect(mac.reload())
        #expect(mac.folderID(ofHost: h[0].id) == nil)
        #expect(mac.hosts(inFolder: nil).map(\.name) == ["a"])
    }

    @Test("blank names and unknown folders are refused")
    func invalid() throws {
        let (store, h) = try store(with: ["a"])
        #expect(throws: HostStoreError.invalidFolderName) { try store.addFolder(named: "   ") }
        #expect(throws: HostStoreError.invalidFolderName) {
            try store.addFolder(named: String(repeating: "x", count: HostFolder.maxNameLength + 1))
        }
        let missing = UUID()
        #expect(throws: HostStoreError.notFound(missing)) { try store.moveHost(h[0].id, toFolder: missing) }
        #expect(throws: HostStoreError.notFound(missing)) { try store.add(RemoteHost(name: "b", address: "x", user: "u"), toFolder: missing) }
        #expect(store.folders.isEmpty)
        #expect(store.hosts.count == 1)
    }

    @Test("records from before folders load in the order they were added")
    func legacyRecords() throws {
        let old = RemoteHost(name: "old", address: "10.0.0.1", user: "deploy")
        let older = RemoteHost(name: "older", address: "10.0.0.2", user: "deploy")
        for (host, added) in [(old, Date(timeIntervalSinceReferenceDate: 200)), (older, Date(timeIntervalSinceReferenceDate: 100))] {
            let json = try JSONSerialization.data(withJSONObject: [
                "host": try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)),
                "addedAt": added.timeIntervalSinceReferenceDate,
            ])
            hosts.save(KeychainItem(account: host.id.uuidString, record: json, syncs: true), secret: Data())
        }
        let store = device()
        #expect(store.hosts.map(\.name) == ["older", "old"])
        try store.add(RemoteHost(name: "new", address: "10.0.0.3", user: "deploy"))
        #expect(store.hosts.map(\.name) == ["older", "old", "new"])
    }
}
