import Testing
import AeroCore

@Suite("Host search")
struct HostSearchTests {
    private let hosts = [
        RemoteHost(name: "Web-01", address: "192.168.1.10", user: "deploy"),
        RemoteHost(name: "Café DB", address: "db.example.com", user: "postgres"),
        RemoteHost(name: "edge", address: "10.0.0.7", user: "root"),
    ]

    @Test("a blank query matches every host, in order")
    func blankQuery() {
        #expect(hosts.matching(search: "") == hosts)
        #expect(hosts.matching(search: "  \n") == hosts)
    }

    @Test("matches the name ignoring case and diacritics")
    func name() {
        #expect(hosts.matching(search: "web").map(\.name) == ["Web-01"])
        #expect(hosts.matching(search: "cafe").map(\.name) == ["Café DB"])
    }

    @Test("matches the address: IP prefixes, fragments and hostnames")
    func address() {
        #expect(hosts.matching(search: "192.168").map(\.name) == ["Web-01"])
        #expect(hosts.matching(search: "0.0.7").map(\.name) == ["edge"])
        #expect(hosts.matching(search: "example.com").map(\.name) == ["Café DB"])
        #expect(hosts.matching(search: " 10 ").map(\.name) == ["Web-01", "edge"])
    }
}
