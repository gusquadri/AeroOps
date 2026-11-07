import AeroCore
import Foundation
import Testing
@testable import TermiusImport

@Suite("Termius import plan")
struct TermiusImportPlanTests {
    static func host(
        _ id: Int64, label: String = "", address: String, port: Int? = nil, user: String? = "root",
        password: String? = nil, key: Int64? = nil, groups: [String] = [], tags: [String] = [],
        unsupported: TermiusHost.Unsupported? = nil
    ) -> TermiusHost {
        TermiusHost(id: id, label: label, address: address, port: port, username: user, password: password.map(TermiusSecret.init),
                    keyID: key, groups: groups, tags: tags, unsupported: unsupported)
    }

    static func plan(_ hosts: [TermiusHost], keys: [TermiusKey] = [], existing: [RemoteHost] = []) throws -> [TermiusImportCandidate] {
        var data = try TermiusData(rows: [:], cipher: TermiusFieldCipher(key: [UInt8](repeating: 0, count: 32)))
        data.hosts = hosts
        data.keys = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })
        return TermiusImport.candidates(from: data, existingHosts: existing, localUser: "me")
    }

    static let key = TermiusKey(id: 7, label: "laptop", privateKey: TermiusSecret("KEY"), passphrase: nil)

    @Test func authPrefersTheKey() throws {
        let plan = try Self.plan([
            Self.host(1, label: "both", address: "a.example", password: "pw", key: 7),
            Self.host(2, label: "password", address: "b.example", password: "pw"),
            Self.host(3, label: "neither", address: "c.example"),
            Self.host(4, label: "missing key", address: "d.example", key: 99),
        ], keys: [Self.key])

        #expect(plan.map(\.candidate.host.auth) == [.key, .password, .key, .key])
        #expect(plan.map(\.keyID) == [7, nil, nil, nil])
        #expect(plan.map { $0.password?.reveal() } == [nil, "pw", nil, nil])
        #expect(plan[0].notes.count == 2)
        #expect(plan[0].notes[0].contains("laptop"))
        #expect(plan[1].notes == ["The password is saved to your Keychain."])
        #expect(plan[2].notes.isEmpty)
        #expect(plan.allSatisfy { $0.candidate.host.keyId == nil })
    }

    @Test func namesPortsAndUsers() throws {
        let plan = try Self.plan([
            Self.host(1, label: "  web ", address: "10.0.0.1", port: 2222),
            Self.host(2, label: "web", address: "10.0.0.2"),
            Self.host(3, address: "10.0.0.3", user: nil),
            Self.host(4, label: "pct", address: "fe80::1%en0"),
        ])
        #expect(plan.map(\.candidate.host.name) == ["web", "web 2", "10.0.0.3", "pct"])
        #expect(plan[0].candidate.host.port == 2222)
        #expect(plan[1].candidate.host.port == RemoteHost.defaultPort)
        #expect(plan[2].candidate.host.user == "me")
        #expect(plan[2].candidate.usesLocalUser)
        #expect(plan[3].candidate.host.address == "fe80::1%en0")
        #expect(plan.map(\.termiusID) == [1, 2, 3, 4])
    }

    @Test func duplicatesOfExistingHosts() throws {
        let existing = RemoteHost(name: "prod", address: "10.0.0.1", user: "root")
        let plan = try Self.plan([
            Self.host(1, label: "prod copy", address: "10.0.0.1"),
            Self.host(2, label: "again", address: "10.0.0.9"),
            Self.host(3, label: "again 2", address: "10.0.0.9"),
        ], existing: [existing])
        #expect(plan[0].candidate.status == .alreadyAdded(existingName: "prod"))
        #expect(plan[1].candidate.status == .ready)
        #expect(plan[2].candidate.status == .sameAsEarlier(alias: "again"))
        #expect(plan.map(\.candidate.isSelectedByDefault) == [false, true, false])
    }

    @Test func unsupportedHostsKeepTheirReason() throws {
        let plan = try Self.plan([
            Self.host(1, label: "t", address: "t.example", unsupported: .telnet),
            Self.host(2, label: "c", address: "c.example", unsupported: .hostChain),
            Self.host(3, label: "p", address: "p.example", unsupported: .proxy),
            Self.host(4, label: "h", address: "h.example", unsupported: .hardwareKey),
        ])
        for (candidate, unsupported) in zip(plan, [TermiusHost.Unsupported.telnet, .hostChain, .proxy, .hardwareKey]) {
            #expect(candidate.candidate.status == .unsupported(reason: TermiusImport.reason(unsupported)))
            #expect(!candidate.candidate.isSelectable)
        }
    }

    @Test func groupsAndTagsBecomeTags() throws {
        let plan = try Self.plan([
            Self.host(1, label: "x", address: "x.example", groups: ["Prod EU", "web/edge"], tags: ["nginx", "NGINX", "  ", "a b"]),
        ])
        #expect(plan[0].candidate.host.tags == ["Prod-EU/web-edge", "nginx", "a-b"])
        #expect(plan[0].groups == ["Prod EU", "web/edge"])
    }

    @Test(arguments: [
        ("Prod EU", "Prod-EU"),
        ("  trim  ", "trim"),
        ("emoji 🚀 ok", "emoji-ok"),
        ("/slashes/", "slashes"),
        ("---", nil),
        (String(repeating: "a", count: 40), String(repeating: "a", count: 32)),
    ] as [(String, String?)])
    func cleansTags(raw: String, expected: String?) {
        #expect(TermiusImport.cleanTag(raw) == expected)
    }
}
