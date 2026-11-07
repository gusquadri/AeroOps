import AeroCore
import Foundation
import KeyAgent
import Observation
import TermiusImport

/// State of the "Import from Termius" sheet.
///
/// Reads Termius's local database and its encryption key (macOS asks the user to allow the
/// Keychain read) off the main actor, lists the hosts, and adds the checked ones: keys go to
/// the in-app agent, passwords to the Keychain, hosts through ``AppModel/addHost(_:)``.
///
/// Termius's files and Keychain item are only read. Decrypted passwords and keys live in this
/// object's memory until it goes away with the sheet; they are never written to disk or logged.
@MainActor
@Observable
final class TermiusImportModel {
    enum Phase: Equatable {
        /// Explains the Keychain prompt before triggering it.
        case intro
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase = Phase.intro
    private(set) var candidates: [TermiusImportCandidate] = []
    /// Notes per candidate beyond the planner's: keys that can't be imported.
    private(set) var keyIssues: [TermiusImportCandidate.ID: String] = [:]
    /// Rows Termius's database had that couldn't be read.
    private(set) var skippedRows = 0
    var selection: Set<TermiusImportCandidate.ID> = []
    private(set) var isImporting = false
    private(set) var importError: String?

    private var keys: [TermiusKey.ID: TermiusKey] = [:]

    var localUserName: String { NSUserName() }

    var selectedCount: Int {
        candidates.count { selection.contains($0.id) && $0.candidate.isSelectable }
    }

    var selectableCount: Int { candidates.count(where: \.candidate.isSelectable) }

    /// Finds Termius, reads its key from the Keychain (macOS shows its Allow prompt) and plans
    /// the import against `existingHosts`.
    func load(existingHosts: [RemoteHost], from source: @escaping Source = TermiusImportModel.installed) async {
        phase = .loading
        importError = nil
        let localUser = localUserName
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.plan(existingHosts: existingHosts, localUser: localUser, source: source)
        }.value
        switch outcome {
        case .failure(let error):
            candidates = []
            keys = [:]
            selection = []
            phase = .failed(error.localizedDescription)
        case .success(let plan):
            candidates = plan.candidates
            keys = plan.keys
            keyIssues = plan.keyIssues
            skippedRows = plan.skippedRows
            selection = Set(plan.candidates.filter(\.candidate.isSelectedByDefault).map(\.id))
            phase = .loaded
        }
    }

    struct Plan: Sendable {
        var candidates: [TermiusImportCandidate]
        var keys: [TermiusKey.ID: TermiusKey]
        var keyIssues: [TermiusImportCandidate.ID: String]
        var skippedRows: Int
    }

    typealias Source = @Sendable () throws(TermiusImportError) -> TermiusData

    /// The local Termius install's data, decrypted with its key from the Keychain.
    nonisolated static func installed() throws(TermiusImportError) -> TermiusData {
        let install = try TermiusInstallation.find()
        return try install.load(localKey: install.readLocalKey())
    }

    nonisolated static func plan(existingHosts: [RemoteHost], localUser: String, source: Source) -> Result<Plan, TermiusImportError> {
        do throws(TermiusImportError) {
            let data = try source()
            let existingNames = existingHosts.map(\.name)
            var candidates = TermiusImport.candidates(from: data, existingHosts: existingHosts, localUser: localUser)
            var keyIssues: [TermiusImportCandidate.ID: String] = [:]
            var checkedKeys: [TermiusKey.ID: KeyImportError?] = [:]
            for index in candidates.indices {
                candidates[index].candidate = SSHConfigImportModel.checkedWithEditorRules(
                    candidates[index].candidate, existingNames: existingNames, password: candidates[index].password?.reveal() ?? "")
                guard let keyID = candidates[index].keyID, let key = data.keys[keyID] else { continue }
                let issue = checkedKeys[keyID] ?? KeyStore.importIssue(key.privateKey.reveal())
                checkedKeys[keyID] = issue
                if let issue {
                    keyIssues[candidates[index].id] = Self.describe(issue)
                }
            }
            return .success(Plan(candidates: candidates, keys: data.keys, keyIssues: keyIssues, skippedRows: data.skippedRows))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func describe(_ issue: KeyImportError) -> String {
        switch issue {
        case .encrypted:
            "Its key is protected by a passphrase, so it isn't imported. Add the key in Settings › Keys after removing the passphrase."
        case .unsupportedKeyType(let type):
            "Its key type (\(SSHConfigImport.displaySafe(type, limit: 40))) isn't supported, so it isn't imported."
        default:
            "Its key couldn't be read, so it isn't imported."
        }
    }

    func isSelected(_ candidate: TermiusImportCandidate) -> Bool {
        candidate.candidate.isSelectable && selection.contains(candidate.id)
    }

    func setSelected(_ selected: Bool, _ candidate: TermiusImportCandidate) {
        guard candidate.candidate.isSelectable else { return }
        if selected { selection.insert(candidate.id) } else { selection.remove(candidate.id) }
    }

    func selectAllNew() {
        selection = Set(candidates.filter(\.candidate.isSelectedByDefault).map(\.id))
    }

    func selectNone() {
        selection = []
    }

    /// The row's notes: what is imported along with the host, and keys that aren't.
    func notes(for candidate: TermiusImportCandidate) -> [HostImportRow.Note] {
        guard candidate.candidate.isSelectable else { return [] }
        var notes = groupNotes(candidate) + authNotes(candidate)
        if candidate.keyID == nil, candidate.password == nil {
            notes.append(.init(text: "No key or password in Termius: pick a key for it after importing.", systemImage: "key", isWarning: true))
        }
        return notes
    }

    private func groupNotes(_ candidate: TermiusImportCandidate) -> [HostImportRow.Note] {
        guard !candidate.groups.isEmpty else { return [] }
        let path = candidate.groups.map { SSHConfigImport.displaySafe($0, limit: 30) }.joined(separator: " › ")
        return [.init(text: "In the Termius group \(path).", systemImage: "folder")]
    }

    private func authNotes(_ candidate: TermiusImportCandidate) -> [HostImportRow.Note] {
        if let issue = keyIssues[candidate.id] {
            return [.init(text: issue, systemImage: "key", isWarning: true)]
        }
        let image = candidate.keyID == nil ? "lock" : "key"
        return candidate.notes.map { .init(text: $0, systemImage: image) }
    }

    /// Adds the checked hosts in Termius order and returns their ids. Each key is imported once
    /// (an already stored key is reused); a key that fails leaves its hosts without a key.
    /// Passwords are saved before their host is added and removed again if the add fails.
    @discardableResult
    func importSelected(into model: AppModel) async -> [RemoteHost.ID] {
        guard !isImporting else { return [] }
        isImporting = true
        importError = nil
        defer { isImporting = false }
        let total = selectedCount
        var run = ImportRun()
        do {
            for candidate in candidates where isSelected(candidate) {
                try await importHost(candidate, into: model, run: &run)
            }
        } catch {
            importError = run.stopped(by: error, total: total)
            return run.added
        }
        importError = run.summary
        return run.added
    }

    /// What one import has done so far.
    private struct ImportRun {
        var importedKeys: [TermiusKey.ID: String] = [:]
        var failedKeys: Set<TermiusKey.ID> = []
        var added: [RemoteHost.ID] = []
        var skipped: [String] = []
        var problems: [String] = []

        func stopped(by error: Error, total: Int) -> String {
            added.isEmpty
                ? "No hosts were added: \(error.localizedDescription)"
                : "Added \(added.count) of \(total) hosts, then stopped: \(error.localizedDescription)"
        }

        var summary: String? {
            var all = problems
            if !skipped.isEmpty {
                let names = skipped.map { "“\(SSHConfigImport.displaySafe($0, limit: 40))”" }.formatted(.list(type: .and))
                all.append("Skipped \(names): another host now has that name.")
            }
            return all.isEmpty ? nil : all.joined(separator: " ")
        }
    }

    /// Skips a host whose name is taken by now; throws when adding it fails, which stops the import.
    private func importHost(_ candidate: TermiusImportCandidate, into model: AppModel, run: inout ImportRun) async throws {
        var host = HostDraft(host: candidate.candidate.host).makeHost()
        guard HostDraft.nameIssue(host.name, otherHostNames: model.hosts.map(\.name)) == nil else {
            run.skipped.append(host.name)
            return
        }
        if let keyID = await keyID(for: candidate, into: model, run: &run) { host.keyId = keyID }
        let savedPassword = savePassword(of: candidate, for: &host, into: model, run: &run)
        do {
            try model.addHost(host)
            run.added.append(host.id)
        } catch {
            if savedPassword { try? model.ssh.deletePassword(for: host.id) }
            throw error
        }
    }

    /// The agent's id for the candidate's key, importing it the first time it comes up.
    private func keyID(for candidate: TermiusImportCandidate, into model: AppModel, run: inout ImportRun) async -> String? {
        guard let keyID = candidate.keyID, keyIssues[candidate.id] == nil, !run.failedKeys.contains(keyID) else { return nil }
        if let imported = run.importedKeys[keyID] { return imported }
        guard let key = keys[keyID] else { return nil }
        guard let imported = await importKey(key, into: model, run: &run) else {
            run.failedKeys.insert(keyID)
            return nil
        }
        run.importedKeys[keyID] = imported
        return imported
    }

    private func importKey(_ key: TermiusKey, into model: AppModel, run: inout ImportRun) async -> String? {
        let name = key.label.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let record = try await model.ssh.importKey(
                text: key.privateKey.reveal(), name: name.isEmpty ? "Termius key" : name, policy: KeyFileImport.policy)
            return record.id.uuidString
        } catch KeyStoreError.duplicateKey(let existing, _) {
            return existing.uuidString
        } catch {
            run.problems.append("A key couldn't be imported: \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves a password host's password to the Keychain; when that fails the host falls back to key auth.
    private func savePassword(of candidate: TermiusImportCandidate, for host: inout RemoteHost, into model: AppModel, run: inout ImportRun) -> Bool {
        guard host.auth == .password, let password = candidate.password?.reveal() else { return false }
        do {
            try model.ssh.setPassword(password, for: host.id)
            return true
        } catch {
            run.problems.append("The password for “\(SSHConfigImport.displaySafe(host.name, limit: 40))” couldn't be saved: \(error.localizedDescription)")
            host.auth = .key
            return false
        }
    }

    /// Drops the decrypted keys and passwords.
    func forgetSecrets() {
        keys = [:]
        for index in candidates.indices { candidates[index].password = nil }
    }
}
