#if DEBUG
import AeroCore
import AppKit
import Foundation

@MainActor
struct HostSearchSelfTest {
    private struct Report: Encodable {
        var ok = true
        var failures: [String] = []
    }

    private let web = RemoteHost(name: "web-01", address: "192.0.2.10", user: "selftest")
    private let database = RemoteHost(name: "Café DB", address: "db.example.com", user: "selftest")
    private let edge = RemoteHost(name: "edge", address: "198.51.100.7", user: "selftest")

    func runAndQuit() {
        let report = run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: url, options: .atomic)
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED \(report.failures)")")
        NSApp.terminate(nil)
    }

    private func run() -> Report {
        let model = AppModel.preview(hosts: [web, database, edge], statuses: [.online, .online, .online])
        model.selection = web.id
        var report = Report()
        for (search, expected) in cases {
            model.hostSearch = search
            let shown = model.searchedHosts
            if shown.map(\.id) != expected.map(\.id) {
                report.failures.append("“\(search)” showed \(shown.map(\.name)), expected \(expected.map(\.name))")
            }
        }
        if model.selection != web.id {
            report.failures.append("searching changed the selection")
        }
        report.ok = report.failures.isEmpty
        return report
    }

    private var cases: [(String, [RemoteHost])] {
        [
            ("", [web, database, edge]),
            ("WEB", [web]),
            ("cafe", [database]),
            ("192.0.2", [web]),
            ("example.com", [database]),
            ("no-such-host", []),
            ("  ", [web, database, edge]),
        ]
    }
}
#endif
