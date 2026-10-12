#if DEBUG
import AeroCore
import AppKit
import Foundation
import KeyAgent
import SSHKit

/// `-AeroSelfTest files`: proves the Files tab's SFTP browsing and transfers end to end in the
/// built app, without clicking, against the dev SSH servers (`dev@localhost:2222`, and the
/// BusyBox one at `dev@localhost:2223`; `docker compose -f dev/compose.yml up -d`).
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest files \
///   -AeroSelfTestOutput /tmp/aeroops-files.json \
///   -AeroSelfTestAuthorizeScript dev/add-key.sh \   # authorizes the new .pub on the dev servers
///   [-AeroSelfTestKeepRoot YES]                      # keep the temporary root for inspection
/// ```
///
/// Uses ``Phase2SelfTest``'s temporary root and Keychain service. Per server, through
/// ``FileService`` and the remote ``FilePaneModel`` as the Files tab drives them: the first listing
/// asks for host-key trust → trust (the sheet's button) → home listed → New Folder → go to it by
/// typed path → upload a local tree (nested folders, non-ASCII names, an empty file, a 3 MB file,
/// links to a file and to a folder) → upload again (expects a conflict; Replace) → download it back
/// and compare byte for byte → download again (expects a conflict; Skip) → rename, refused
/// rename onto an existing name, delete → remove the test folder. Then shutdown (sessions closed),
/// revoke and delete the key, remove the root. Writes a JSON report (`"ok": true` on success) and
/// quits.
@MainActor
struct FilesSelfTest {
    static var isRequested: Bool { UserDefaults.standard.string(forKey: "AeroSelfTest") == "files" }

    /// Size of the large file, enough for many SFTP read/write requests in flight.
    nonisolated static let largeFileBytes = 3 * 1024 * 1024 + 123

    let model: AppModel

    // MARK: - Report

    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    struct Report: Codable {
        var ok = false
        var root = ""
        var keyFingerprint: String?
        var steps: [Step] = []
    }

    private final class Recorder {
        var report = Report()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            report.steps.append(Step(name: name, ok: ok, detail: detail))
            print("[selftest] \(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }
    }

    // MARK: - Run

    func runAndQuit() async {
        let report = await run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                try? data.write(to: url, options: .atomic)
            }
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED")")
        NSApp.terminate(nil)
    }

    func run() async -> Report {
        let r = Recorder()
        let ssh = model.ssh
        r.report.root = Phase2SelfTest.root.path(percentEncoded: false)

        let key: SSHKeyRecord
        do {
            key = try await ssh.generateKey(.ed25519, name: "AeroOps files self-test", policy: .always)
            r.report.keyFingerprint = key.fingerprint
            r.step("generate key", true, "\(key.algorithm.displayName) \(key.fingerprint)")
        } catch {
            r.step("generate key", false, error.localizedDescription)
            return await finish(r, key: nil, hosts: [])
        }
        let pub = ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
        if let script = Phase2SelfTest.authorizeScript {
            let (status, output) = await Phase2SelfTest.runProcess(script, arguments: [pub.path(percentEncoded: false)])
            r.step("authorize key", status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            r.step("authorize key", true, "skipped: no -AeroSelfTestAuthorizeScript (key must already be authorized)")
        }

        let source: URL
        do {
            source = try Self.makeSourceTree(in: Phase2SelfTest.root)
            r.step("local tree", true, source.path(percentEncoded: false))
        } catch {
            r.step("local tree", false, error.localizedDescription)
            return await finish(r, key: key, hosts: [])
        }

        let hosts = [
            RemoteHost(name: "Files dev", address: "localhost", port: 2222, user: "dev", keyId: key.id.uuidString),
            RemoteHost(name: "Files BusyBox", address: "localhost", port: 2223, user: "dev", keyId: key.id.uuidString),
        ]
        for host in hosts {
            do {
                try model.addHost(host)
            } catch {
                r.step("\(host.name): add host", false, error.localizedDescription)
                continue
            }
            await check(r, host: host, source: source)
        }
        return await finish(r, key: key, hosts: hosts)
    }

    // MARK: - Per host

    private func check(_ r: Recorder, host: RemoteHost, source: URL) async {
        let files = model.fileService
        let pane = files.remotePane(for: host)
        let label = host.name
        let sourceName = source.lastPathComponent

        // 1. First contact: the listing stops and the trust sheet's request appears.
        pane.start()
        let asked = await waitUntil(seconds: 30) { files.trustRequest?.host.id == host.id && !pane.isLoading }
        guard asked, let request = files.trustRequest else {
            return r.step("\(label): trust asked", false, "no trust request; load error: \(Self.describe(pane.loadError))")
        }
        let untrusted = (pane.loadError as? FileBrowserError) == .untrustedHost
        r.step("\(label): trust asked", untrusted, "\(request.offered.count) key(s) offered; pane error untrustedHost \(untrusted)")
        do {
            try await files.trust(request)
        } catch {
            return r.step("\(label): trust", false, error.localizedDescription)
        }

        // 2. Home listed over SFTP.
        let started = Date.now
        guard await waitUntil(seconds: 30, { pane.directory != nil && !pane.isLoading }), let home = pane.directory else {
            return r.step("\(label): list home", false, Self.describe(pane.loadError))
        }
        r.step(
            "\(label): list home", pane.loadError == nil && pane.backend.session.status == .connected,
            "\(home.string): \(pane.items.count) items in \(Self.milliseconds(since: started)) ms, session \(pane.backend.session.status)"
        )

        // 3. New Folder, then go there by typed path (resolves `~/`).
        let folderName = "aeroops-files-selftest-\(UUID().uuidString.prefix(8).lowercased())"
        await pane.createFolder(named: folderName)
        let created = await waitUntil(seconds: 20) { !pane.isLoading && pane.items.contains { $0.name == folderName } }
        r.step("\(label): new folder", created && pane.actionError == nil, pane.actionError ?? "\(folderName) listed and selected \(pane.selection.count == 1)")
        guard created else { return }
        pane.go(to: "~/\(folderName)")
        let entered = await waitUntil(seconds: 20) { !pane.isLoading && pane.directory?.name == folderName }
        guard entered, let folder = pane.directory else {
            return r.step("\(label): go to path", false, Self.describe(pane.loadError))
        }
        r.step("\(label): go to path", pane.items.isEmpty && pane.canGoBack, "\(folder.string), empty \(pane.items.isEmpty)")

        // 4. Upload the tree; the pane lists it when the transfer ends.
        var before = files.transfers.count
        await files.upload([source.path(percentEncoded: false)], to: host, into: folder)
        guard let upload = await waitForTransfer(r, "\(label): upload", after: before) else { return }
        let refreshed = await waitUntil(seconds: 10) { pane.items.contains { $0.name == sourceName } }
        r.step(
            "\(label): upload",
            upload.phase == .finished && upload.failures.isEmpty && upload.fileCount == 6 && upload.skipped.count == 1
                && upload.copiedBytes == upload.totalBytes && refreshed,
            "\(Self.summary(upload)); pane refreshed \(refreshed)"
        )

        // 5. Again: the folder exists, so a conflict is asked; Replace copies into it.
        before = files.transfers.count
        await files.upload([source.path(percentEncoded: false)], to: host, into: folder)
        if let conflict = files.conflict, conflict.names == [sourceName] {
            files.conflict = nil
            conflict.resolve(.replace)
            if let again = await waitForTransfer(r, "\(label): upload again", after: before) {
                r.step(
                    "\(label): upload again (Replace)", again.phase == .finished && again.failures.isEmpty && again.fileCount == 6,
                    "conflict on \(conflict.names); \(Self.summary(again))"
                )
            }
        } else {
            files.conflict = nil
            r.step("\(label): upload again (Replace)", false, "expected a conflict on \(sourceName), got \(files.conflict?.names ?? [])")
        }

        // 6. Download it back and compare with the source.
        let downloads = Phase2SelfTest.root.appending(path: "down-\(host.port)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let remoteTree = folder.appending(component: sourceName)
        before = files.transfers.count
        files.download([remoteTree], from: host, into: downloads.path(percentEncoded: false))
        if let download = await waitForTransfer(r, "\(label): download", after: before) {
            let differences = Self.differences(source: source, copy: downloads.appending(path: sourceName, directoryHint: .isDirectory))
            r.step(
                "\(label): download", download.phase == .finished && download.failures.isEmpty && differences.isEmpty,
                differences.isEmpty ? "\(Self.summary(download)); identical to the source" : "differences: \(differences)"
            )
        }

        // 7. Again: Skip leaves the copy alone and queues nothing.
        let queued = files.transfers.count
        files.download([remoteTree], from: host, into: downloads.path(percentEncoded: false))
        if let conflict = files.conflict, conflict.names == [sourceName] {
            files.conflict = nil
            conflict.resolve(.skip)
            r.step("\(label): download again (Skip)", files.transfers.count == queued, "conflict on \(conflict.names); nothing queued \(files.transfers.count == queued)")
        } else {
            files.conflict = nil
            r.step("\(label): download again (Skip)", false, "expected a conflict on \(sourceName)")
        }

        // 8. Rename; renaming onto an existing name is refused; delete.
        if let uploaded = pane.items.first(where: { $0.name == sourceName }) {
            await pane.rename(uploaded, to: "renamed")
            let renamed = await waitUntil(seconds: 10) { !pane.isLoading && pane.items.map(\.name) == ["renamed"] }
            await pane.createFolder(named: "other")
            _ = await waitUntil(seconds: 10) { !pane.isLoading && pane.items.count == 2 }
            var refused = false
            if let item = pane.items.first(where: { $0.name == "renamed" }) {
                await pane.rename(item, to: "other")
                refused = pane.actionError != nil
                pane.actionError = nil
            }
            r.step("\(label): rename", renamed && refused, "renamed \(renamed); rename onto an existing folder refused \(refused)")
            await pane.delete(pane.items)
            let emptied = await waitUntil(seconds: 20) { !pane.isLoading && pane.items.isEmpty }
            r.step("\(label): delete", emptied && pane.actionError == nil, pane.actionError ?? "folder emptied \(emptied)")
        } else {
            r.step("\(label): rename", false, "\(sourceName) not listed")
        }

        // 9. Remove the test folder.
        pane.goUp()
        _ = await waitUntil(seconds: 10) { !pane.isLoading && pane.directory == home }
        if let item = pane.items.first(where: { $0.name == folderName }) {
            await pane.delete([item])
            let gone = await waitUntil(seconds: 20) { !pane.isLoading && !pane.items.contains { $0.name == folderName } }
            r.step("\(label): clean up", gone, "\(folderName) removed \(gone)")
        } else {
            r.step("\(label): clean up", false, "\(folderName) not listed in \(pane.directory?.string ?? "?")")
        }
    }

    /// The transfer queued after the first `count`, once over.
    private func waitForTransfer(_ r: Recorder, _ name: String, after count: Int) async -> FileTransfer? {
        let files = model.fileService
        guard await waitUntil(seconds: 5, { files.transfers.count > count }) else {
            r.step(name, false, "no transfer queued")
            return nil
        }
        let transfer = files.transfers[count]
        guard await waitUntil(seconds: 120, { transfer.phase.isOver }) else {
            r.step(name, false, "still \(transfer.phase) after 120 s")
            return nil
        }
        return transfer
    }

    // MARK: - Finish

    private func finish(_ r: Recorder, key: SSHKeyRecord?, hosts: [RemoteHost]) async -> Report {
        let ssh = model.ssh
        let sessions = hosts.compactMap { model.host(id: $0.id) }.map { model.fileService.remotePane(for: $0).backend.session }

        _ = await model.shutdownServices()
        let closed = sessions.allSatisfy { $0.status == .idle }
        r.step("shutdown", closed, "SFTP sessions closed \(closed)")

        if let key {
            if let script = Phase3SelfTest.revokeScript, Phase2SelfTest.authorizeScript != nil {
                let pub = ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
                let (status, output) = await Phase2SelfTest.runProcess(script, arguments: [pub.path(percentEncoded: false)])
                r.step("revoke key", status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do {
                try await ssh.deleteKey(key.id)
                r.step("delete key", true, key.fingerprint)
            } catch {
                r.step("delete key", false, error.localizedDescription)
            }
        }
        if !Phase2SelfTest.keepsRoot {
            try? FileManager.default.removeItem(at: Phase2SelfTest.root)
        }
        r.report.ok = !r.report.steps.isEmpty && r.report.steps.allSatisfy(\.ok)
        return r.report
    }

    // MARK: - Helpers

    /// `Upload ü/`: files at two depths, non-ASCII names, an empty file, a large one, a link to a
    /// file (copied as the file) and a link to a folder (skipped).
    nonisolated static func makeSourceTree(in root: URL) throws -> URL {
        let fm = FileManager.default
        let source = root.appending(path: "Upload ü", directoryHint: .isDirectory)
        try fm.createDirectory(at: source.appending(path: "sub/nested", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: source.appending(path: "a.txt"))
        try Data().write(to: source.appending(path: "empty.txt"))
        var large = Data(count: largeFileBytes)
        large.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try large.write(to: source.appending(path: "large.bin"))
        try Data("deep\n".utf8).write(to: source.appending(path: "sub/nested/deep.txt"))
        try Data("ünïcödé\n".utf8).write(to: source.appending(path: "sub/ünïcödé name.txt"))
        try fm.createSymbolicLink(atPath: source.appending(path: "link to a.txt").path(percentEncoded: false), withDestinationPath: "a.txt")
        try fm.createSymbolicLink(atPath: source.appending(path: "link to sub").path(percentEncoded: false), withDestinationPath: "sub")
        return source
    }

    /// How `copy` differs from `source` as a transfer should copy it: every file (links to files
    /// as files) with the same bytes, every folder, nothing else.
    nonisolated static func differences(source: URL, copy: URL) -> [String] {
        let fm = FileManager.default
        var problems: [String] = []
        func walk(_ relative: String) {
            let sourceDirectory = relative.isEmpty ? source : source.appending(path: relative, directoryHint: .isDirectory)
            let copyDirectory = relative.isEmpty ? copy : copy.appending(path: relative, directoryHint: .isDirectory)
            let names = (try? fm.contentsOfDirectory(atPath: sourceDirectory.path(percentEncoded: false))) ?? []
            let copied = Set((try? fm.contentsOfDirectory(atPath: copyDirectory.path(percentEncoded: false))) ?? [])
            var expected = Set<String>()
            for name in names {
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                let sourcePath = source.appending(path: path).path(percentEncoded: false)
                let copyPath = copy.appending(path: path).path(percentEncoded: false)
                let isLink = (try? fm.attributesOfItem(atPath: sourcePath)[.type] as? FileAttributeType) == .typeSymbolicLink
                var isFolder: ObjCBool = false
                guard fm.fileExists(atPath: sourcePath, isDirectory: &isFolder) else { continue }
                if isLink, isFolder.boolValue { continue }
                expected.insert(name)
                let copyType = try? fm.attributesOfItem(atPath: copyPath)[.type] as? FileAttributeType
                if isFolder.boolValue {
                    if copyType == .typeDirectory { walk(path) } else { problems.append("\(path): not a folder") }
                } else if copyType != .typeRegular {
                    problems.append("\(path): not a regular file (\(copyType?.rawValue ?? "missing"))")
                } else if fm.contents(atPath: sourcePath) != fm.contents(atPath: copyPath) {
                    problems.append("\(path): contents differ")
                }
            }
            for extra in copied.subtracting(expected).sorted() {
                problems.append("\(relative.isEmpty ? extra : "\(relative)/\(extra)"): unexpected")
            }
        }
        walk("")
        return problems
    }

    private static func summary(_ transfer: FileTransfer) -> String {
        let seconds = transfer.started.map { (transfer.ended ?? .now).timeIntervalSince($0) } ?? 0
        var text = "\(transfer.phase): \(transfer.fileCount) files, \(transfer.copiedBytes)/\(transfer.totalBytes) bytes in \(String(format: "%.2f", seconds)) s"
        if !transfer.failures.isEmpty { text += ", failures \(transfer.failures.map { "\($0.path): \($0.message)" })" }
        if !transfer.skipped.isEmpty { text += ", skipped \(transfer.skipped)" }
        return text
    }

    private static func describe(_ error: (any Error)?) -> String {
        error.map { "\($0.localizedDescription) (\($0))" } ?? "none"
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date.now.timeIntervalSince(date) * 1000)
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
#endif
