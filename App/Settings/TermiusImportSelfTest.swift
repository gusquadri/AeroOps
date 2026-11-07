#if DEBUG
import AeroCore
import AppKit
import CryptoKit
import Foundation
import KeyAgent
import TermiusImport

/// Runs the "Import from Termius" sheet's model on a Termius library built here, against an
/// app with in-memory hosts and Keychain: the checked hosts are added, the shared key is imported
/// once and linked, the password is saved, and duplicates and unsupported hosts are left out.
@MainActor
struct TermiusImportSelfTest {
    private struct Report: Encodable {
        var ok = true
        var failures: [String] = []
    }

    private static let keyID: TermiusKey.ID = 7

    func runAndQuit() async {
        let report = await run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: url, options: .atomic)
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED \(report.failures)")")
        NSApp.terminate(nil)
    }

    private func run() async -> Report {
        let model = Self.makeAppModel()
        try? model.addHost(RemoteHost(name: "prod", address: "10.0.0.1", user: "root"))
        let sheet = TermiusImportModel()
        let library = Self.library()
        await sheet.load(existingHosts: model.hosts) { library }
        var report = Report()
        report.failures += Self.check(sheet.phase == .loaded, "the library didn't load: \(sheet.phase)")
        report.failures += Self.check(sheet.selectedCount == 3, "\(sheet.selectedCount) hosts checked, expected 3: \(sheet.candidates.map(\.candidate.status))")
        let added = await sheet.importSelected(into: model)
        report.failures += Self.check(added.count == 3, "\(added.count) hosts added, expected 3")
        report.failures += Self.check(sheet.importError == nil, "import error: \(sheet.importError ?? "")")
        report.failures += Self.checkAdded(model)
        report.ok = report.failures.isEmpty
        return report
    }

    private static func checkAdded(_ model: AppModel) -> [String] {
        let byName = Dictionary(model.hosts.map { ($0.name, $0) }) { first, _ in first }
        let keyHosts = [byName["web"], byName["api"]].compactMap { $0 }
        let keyIDs = Set(keyHosts.compactMap(\.keyId))
        return check(model.ssh.keys.count == 1, "\(model.ssh.keys.count) keys in the agent, expected 1")
            + check(keyHosts.count == 2 && keyIDs.count == 1, "web and api don't share the imported key: \(keyIDs)")
            + check(byName["db"].map(model.ssh.hasPassword) == true, "db's password wasn't saved")
            + check(byName["db"]?.user == "postgres", "db's user is \(byName["db"]?.user ?? "missing")")
            + check(byName["jump"] == nil && model.hosts.count == 4, "hosts are \(model.hosts.map(\.name))")
    }

    private static func check(_ condition: Bool, _ failure: @autoclosure () -> String) -> [String] {
        condition ? [] : [failure()]
    }

    private static func makeAppModel() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "aeroops-termius-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AeroPaths(dotDirectory: root.appending(path: "dot", directoryHint: .isDirectory))
        let ssh = SSHServices(paths: paths, keychain: InMemoryKeychain(), defaults: nil)
        let model = AppModel(hostStore: .inMemory(), ssh: ssh)
        model.monitoring.isEnabled = false
        model.agents.isEnabled = false
        return model
    }

    private static func library() -> TermiusData {
        let key = TermiusKey(id: keyID, label: "laptop", privateKey: TermiusSecret(ed25519PEM()))
        return TermiusData(hosts: [
            TermiusHost(id: 1, label: "web", address: "10.0.0.2", username: "deploy", keyID: keyID, groups: ["Prod"]),
            TermiusHost(id: 2, label: "api", address: "10.0.0.4", username: "deploy", keyID: keyID),
            TermiusHost(id: 3, label: "db", address: "10.0.0.3", username: "postgres", password: TermiusSecret("selftest pw")),
            TermiusHost(id: 4, label: "prod copy", address: "10.0.0.1", username: "root"),
            TermiusHost(id: 5, label: "jump", address: "10.0.0.5", unsupported: .telnet),
        ], keys: [key])
    }

    /// A fresh Ed25519 key as PKCS#8 PEM, one of the formats Termius stores keys in.
    private static func ed25519PEM() -> String {
        let prefix: [UInt8] = [0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
        let der = Data(prefix + Curve25519.Signing.PrivateKey().rawRepresentation)
        return "-----BEGIN PRIVATE KEY-----\n\(der.base64EncodedString(options: .lineLength64Characters))\n-----END PRIVATE KEY-----\n"
    }
}
#endif
