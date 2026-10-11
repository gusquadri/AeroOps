import Foundation
import Testing
import AeroCore

@Suite("HostStore")
@MainActor
struct HostStoreTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AeroOpsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func sampleHost(_ name: String = "web-01") -> RemoteHost {
        RemoteHost(name: name, address: "10.0.0.12", user: "deploy", tags: ["prod"])
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test("missing file loads as empty without error")
    func emptyStart() {
        let store = HostStore(directory: directory)
        #expect(store.hosts.isEmpty)
        #expect(store.loadError == nil)
        #expect(store.fileURL.lastPathComponent == "hosts.json")
    }

    @Test("add, update, delete round trip and survive a relaunch")
    func roundTripAndRelaunch() throws {
        let store = HostStore(directory: directory)
        var a = sampleHost("a")
        let b = sampleHost("b")
        try store.add(a)
        try store.add(b)
        a.port = 2222
        a.mcpTier = .readExec
        try store.update(a)

        // "Relaunch": a new instance reading the same file.
        let relaunched = HostStore(directory: directory)
        #expect(relaunched.hosts == [a, b])
        #expect(relaunched.host(id: a.id)?.port == 2222)

        try relaunched.delete(id: b.id)
        #expect(HostStore(directory: directory).hosts == [a])
    }

    @Test("written file is the versioned, human-readable envelope")
    func fileFormat() throws {
        let store = HostStore(directory: directory)
        try store.add(sampleHost())
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains(#""version" : 1"#))
        #expect(text.contains(#""hosts" : ["#))
        #expect(text.hasSuffix("\n"))
    }

    @Test("duplicate add and unknown update/delete throw without changing anything")
    func invalidMutations() throws {
        let store = HostStore(directory: directory)
        let host = sampleHost()
        try store.add(host)
        #expect(throws: HostStoreError.duplicateID(host.id)) { try store.add(host) }
        let stranger = sampleHost("stranger")
        #expect(throws: HostStoreError.notFound(stranger.id)) { try store.update(stranger) }
        #expect(throws: HostStoreError.notFound(stranger.id)) { try store.delete(id: stranger.id) }
        #expect(store.hosts == [host])
        #expect(HostStore(directory: directory).hosts == [host])
    }

    @Test("corrupt file is moved aside, store starts empty, and saving works again")
    func corruptFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: directory.appending(path: "hosts.json"))

        let store = HostStore(directory: directory)
        #expect(store.hosts.isEmpty)
        guard case .corruptFile(let backup?, _) = store.loadError else {
            Issue.record("expected corruptFile with a backup, got \(String(describing: store.loadError))")
            return
        }
        #expect(try Data(contentsOf: backup) == garbage, "original bytes preserved")
        #expect(backup.lastPathComponent.hasPrefix("hosts.corrupt-"))

        let host = sampleHost()
        try store.add(host)
        #expect(HostStore(directory: directory).hosts == [host])
        #expect(try Data(contentsOf: backup) == garbage, "backup not overwritten by the save")
        #expect(try files().count == 2)
    }

    @Test("structurally wrong JSON counts as corrupt too")
    func wrongShape() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"hosts":[{"name":"no id"}]}"#.utf8).write(to: directory.appending(path: "hosts.json"))
        let store = HostStore(directory: directory)
        #expect(store.hosts.isEmpty)
        if case .corruptFile = store.loadError {} else { Issue.record("expected corruptFile") }
    }

    @Test("bare array and missing version are accepted; unknown keys ignored")
    func tolerantFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let host = #"{"id":"\#(id.uuidString)","name":"n","address":"a","user":"u","zzz":1}"#
        try Data("[\(host)]".utf8).write(to: directory.appending(path: "hosts.json"))
        #expect(HostStore(directory: directory).hosts.map(\.id) == [id])

        try Data(#"{"hosts":[\#(host)],"future":{}}"#.utf8).write(to: directory.appending(path: "hosts.json"))
        let store = HostStore(directory: directory)
        #expect(store.hosts.map(\.id) == [id])
        #expect(store.loadError == nil)
    }

    @Test("unreadable file blocks writes so it is never overwritten")
    func unreadableBlocksWrites() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A directory where the file should be: exists, but cannot be read as data.
        try FileManager.default.createDirectory(
            at: directory.appending(path: "hosts.json"), withIntermediateDirectories: true)
        let store = HostStore(directory: directory)
        #expect(store.hosts.isEmpty)
        #expect(store.loadError != nil)
        #expect(throws: HostStoreError.self) { try store.add(sampleHost()) }
    }
}
