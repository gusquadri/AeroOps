import Foundation
import Testing
@testable import TermiusImport

/// Rows shaped like Termius's, with the fields Termius encrypts sealed by a test key.
@Suite("Termius rows → hosts")
struct TermiusDataTests {
    static let cipher = try! TermiusFieldCipher(key: [UInt8](repeating: 0x42, count: 32))

    static func sealed(_ text: String) -> JSValue {
        let nonce = [UInt8](repeating: UInt8(truncatingIfNeeded: text.hashValue), count: 23) + [UInt8(text.utf8.count & 0xFF)]
        return .string(cipher.seal(text, nonce: nonce))
    }

    static func ref(_ local: Int) -> JSValue { .object(["id": .null, "local_id": .number(Double(local))]) }
    static func serverRef(_ id: Int) -> JSValue { .object(["id": .number(Double(id)), "local_id": .null]) }

    static func row(_ local: Int, id: Int? = nil, _ fields: [String: JSValue]) -> JSValue {
        var all = fields
        all["local_id"] = .number(Double(local))
        all["id"] = id.map { .number(Double($0)) } ?? .null
        return .object(all)
    }

    static func data(_ rows: [TermiusData.Table: [JSValue]]) throws -> TermiusData {
        try TermiusData(rows: rows, cipher: cipher)
    }

    @Test func linksConfigsIdentitiesKeysTagsAndGroups() throws {
        let data = try Self.data([
            .hosts: [
                Self.row(1, id: 901, ["label": Self.sealed("web-1"), "address": Self.sealed("web1.example.com"),
                                      "ssh_config": Self.ref(10), "group": Self.ref(31)]),
            ],
            .sshConfigs: [
                Self.row(10, ["port": .number(2222), "identity": Self.ref(20)]),
                Self.row(11, ["port": .null]),
                Self.row(12, ["port": .number(2200)]),
            ],
            .sshIdentities: [
                Self.row(20, ["username": Self.sealed("deploy"), "password": Self.sealed("pw"), "ssh_key": Self.ref(40)]),
            ],
            .keys: [
                Self.row(40, ["label": Self.sealed("work key"), "private_key": Self.sealed("-----BEGIN OPENSSH PRIVATE KEY-----\n…")]),
            ],
            .groups: [
                Self.row(30, ["label": Self.sealed("Prod"), "ssh_config": Self.ref(12)]),
                Self.row(31, ["label": Self.sealed("EU"), "parent_group": Self.ref(30), "ssh_config": Self.ref(11)]),
            ],
            .tags: [Self.row(50, ["label": Self.sealed("nginx")])],
            .tagHosts: [Self.row(60, ["host": Self.serverRef(901), "tag": Self.ref(50)])],
        ])

        let host = try #require(data.hosts.first)
        #expect(host.label == "web-1")
        #expect(host.address == "web1.example.com")
        #expect(host.port == 2222)
        #expect(host.username == "deploy")
        #expect(host.password?.reveal() == "pw")
        #expect(host.keyID == 40)
        #expect(host.groups == ["Prod", "EU"])
        #expect(host.tags == ["nginx"])
        #expect(host.unsupported == nil)
        let key = try #require(data.keys[40])
        #expect(key.label == "work key")
        #expect(key.privateKey.reveal().hasPrefix("-----BEGIN OPENSSH"))
    }

    @Test func inheritsFromGroupsNearestFirst() throws {
        let data = try Self.data([
            .hosts: [
                Self.row(1, ["address": .string("10.0.0.5"), "ssh_config": Self.ref(10), "group": Self.ref(31)]),
                Self.row(2, ["address": .string("10.0.0.6"), "group": Self.ref(31)]),
            ],
            .sshConfigs: [
                Self.row(10, ["port": .number(0)]),
                Self.row(11, ["port": .number(2201), "identity": Self.ref(21)]),
                Self.row(12, ["port": .number(2202), "identity": Self.ref(22)]),
            ],
            .sshIdentities: [
                Self.row(21, ["password": Self.sealed("group pw")]),
                Self.row(22, ["username": Self.sealed("root"), "password": Self.sealed("top pw")]),
            ],
            .groups: [
                Self.row(30, ["label": .string("Top"), "ssh_config": Self.ref(12)]),
                Self.row(31, ["label": .string("Mid"), "parent_group": Self.ref(30), "ssh_config": Self.ref(11)]),
            ],
        ])
        for host in data.hosts {
            #expect(host.port == 2201)
            #expect(host.username == "root")
            #expect(host.password?.reveal() == "group pw")
            #expect(host.groups == ["Top", "Mid"])
            #expect(host.label == "")
            #expect(host.displayName == host.address)
        }
    }

    @Test func groupCyclesStop() throws {
        let data = try Self.data([
            .hosts: [Self.row(1, ["address": .string("a"), "group": Self.ref(30)])],
            .groups: [
                Self.row(30, ["label": .string("A"), "parent_group": Self.ref(31)]),
                Self.row(31, ["label": .string("B"), "parent_group": Self.ref(30)]),
            ],
        ])
        #expect(data.hosts.first?.groups == ["B", "A"])
    }

    @Test func linkedIdentitiesAndContentFallback() throws {
        let content = Self.cipher.seal(#"{"label":"from content","address":"ignored"}"#, nonce: [UInt8](repeating: 1, count: 24))
        let data = try Self.data([
            .hosts: [Self.row(1, ["address": .string("db.internal"), "content": .string(content), "ssh_config": Self.ref(10)])],
            .sshConfigs: [Self.row(10, [:])],
            .sshIdentities: [Self.row(20, ["username": .string("postgres")])],
            .sshConfigIdentities: [Self.row(70, ["ssh_config": Self.ref(10), "identity": Self.ref(20)])],
        ])
        let host = try #require(data.hosts.first)
        #expect(host.label == "from content")
        #expect(host.address == "db.internal")
        #expect(host.username == "postgres")
    }

    @Test func skipsDeletedRowsAndHostsWithoutAddress() throws {
        let data = try Self.data([
            .hosts: [
                Self.row(1, ["address": .string("kept")]),
                Self.row(2, ["address": .string("gone"), "status": .string("DELETE")]),
                Self.row(3, ["address": .string("")]),
                .string("not a row"),
            ],
        ])
        #expect(data.hosts.map(\.address) == ["kept"])
    }

    @Test func marksWhatAeroOpsCantConnectTo() throws {
        let data = try Self.data([
            .hosts: [
                Self.row(1, ["address": .string("telnet"), "telnet_config": Self.ref(90)]),
                Self.row(2, ["address": .string("chained"), "ssh_config": Self.ref(11)]),
                Self.row(3, ["address": .string("proxied"), "ssh_config": Self.ref(12)]),
                Self.row(4, ["address": .string("yubikey"), "ssh_config": Self.ref(13)]),
                Self.row(5, ["address": .string("yubikey+pw"), "ssh_config": Self.ref(14)]),
            ],
            .sshConfigs: [
                Self.row(11, [:]),
                Self.row(12, ["proxycommand": Self.ref(80)]),
                Self.row(13, ["identity": Self.ref(23)]),
                Self.row(14, ["identity": Self.ref(24)]),
            ],
            .sshIdentities: [
                Self.row(23, ["hardware_key": Self.ref(95)]),
                Self.row(24, ["hardware_key": Self.ref(95), "password": Self.sealed("fallback")]),
            ],
            .hostChains: [Self.row(85, ["ssh_config": Self.ref(11)])],
        ])
        #expect(data.hosts.map(\.unsupported) == [.telnet, .hostChain, .proxy, .hardwareKey, nil])
    }

    @Test func wrongKeyIsReported() throws {
        let other = try TermiusFieldCipher(key: [UInt8](repeating: 1, count: 32))
        let rows: [TermiusData.Table: [JSValue]] = [.hosts: [Self.row(1, ["address": Self.sealed("x")])]]
        #expect(throws: TermiusImportError.wrongLocalKey) { try TermiusData(rows: rows, cipher: other) }
    }

    @Test(arguments: [
        ("167772161", "10.0.0.1"),
        ("3232235777", "192.168.1.1"),
        ("  web.example  ", "web.example"),
        ("255", "255"),
        ("4294967296", "4294967296"),
        ("2001:db8::1", "2001:db8::1"),
        ("10.0.0.1", "10.0.0.1"),
    ])
    func normalizesAddresses(raw: String, expected: String) {
        #expect(TermiusData.normalizedAddress(raw) == expected)
    }

    @Test func readsTheDatabaseFromDisk() throws {
        let fixture = try LevelDBFixture()
        defer { fixture.remove() }
        let host = IndexedDBFixture.row(.object([
            ("local_id", .int(1)), ("id", .null),
            ("label", .string(Self.cipher.seal("box", nonce: [UInt8](repeating: 5, count: 24)))),
            ("address", .string("box.lan")),
            ("ssh_config", .object([("id", .null), ("local_id", .int(10))])),
        ]))
        let config = IndexedDBFixture.row(.object([("local_id", .int(10)), ("id", .null), ("port", .int(2022))]))
        let entries = IndexedDBFixture.database("hosts", id: 1, rows: [host])
            + IndexedDBFixture.database("ssh_configs", id: 2, rows: [config])
        try fixture.write(tableEntries: entries.map { ($0.0, Optional($0.1)) }, logEntries: [])
        let support = fixture.directory.appendingPathComponent("home/Library/Application Support/Termius/IndexedDB/file__0.indexeddb.leveldb")
        try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).filter { $0 != "home" }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.moveItem(at: fixture.directory.appendingPathComponent(name), to: support.appendingPathComponent(name))
        }

        let install = try TermiusInstallation.find(home: fixture.directory.appendingPathComponent("home"))
        #expect(install.keychainService == "Termius")
        let data = try install.load(localKey: Data(repeating: 0x42, count: 32).base64EncodedString())
        #expect(data.hosts.map(\.label) == ["box"])
        #expect(data.hosts.first?.port == 2022)

        #expect(throws: TermiusImportError.notInstalled) {
            try TermiusInstallation.find(home: fixture.directory.appendingPathComponent("nobody"))
        }
    }
}
