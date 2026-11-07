import AeroCore
import Foundation
import Observation

/// State of the "Import from ~/.ssh/config" sheet: reads the config off the main actor, lists
/// the hosts it found, tracks which are checked, and adds the checked ones through
/// ``AppModel/addHost(_:)``.
///
/// The config is only read. `IdentityFile`s are shown as a note and never opened: imported
/// hosts have no key and authenticate through the in-app agent once the user picks one.
@MainActor
@Observable
final class SSHConfigImportModel {
    enum Phase: Equatable {
        case loading
        case loaded
        /// The top-level file is missing or unreadable.
        case failed(SSHConfigLoadError)
    }

    /// The config being read: `~/.ssh/config`, or a fixture in debug runs.
    let locations: SSHConfigLocations
    private(set) var phase = Phase.loading
    /// Every concrete host in the config, in file order.
    private(set) var candidates: [SSHConfigImportCandidate] = []
    /// Problems in the config (skipped lines, `Match` blocks, include loops).
    private(set) var issues: [SSHClientConfig.Issue] = []
    /// How many files were read, the top-level one included.
    private(set) var fileCount = 0
    /// Checked candidates, by ``SSHConfigImportCandidate/id``.
    var selection: Set<SSHConfigImportCandidate.ID> = []
    /// Why the last import stopped or skipped hosts, if it did.
    private(set) var importError: String?

    init(locations: SSHConfigLocations = SSHConfigImportModel.defaultLocations) {
        self.locations = locations
    }

    /// `~/.ssh/config`; in debug builds `-AeroOpsSSHConfigFile <path>` points at a fixture
    /// instead, so snapshot and demo runs never read the real one.
    static var defaultLocations: SSHConfigLocations {
        #if DEBUG
        if let file = DebugLaunchOptions.sshConfigFile {
            return .standalone(configFile: file)
        }
        #endif
        return .user()
    }

    /// `~/.ssh/config` as the user would write it.
    var displayPath: String {
        (locations.configFile as NSString).abbreviatingWithTildeInPath
    }

    var selectedCount: Int {
        candidates.count { selection.contains($0.id) && $0.isSelectable }
    }

    var selectableCount: Int { candidates.count(where: \.isSelectable) }

    /// Hosts that use the local account name because the config has no `User`.
    var localUserName: String { NSUserName() }

    // MARK: - Loading

    /// Reads and plans the import against `existingHosts`. Safe to call again to re-read.
    func load(existingHosts: [RemoteHost]) async {
        phase = .loading
        importError = nil
        let locations = locations
        let localUser = localUserName
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.plan(locations: locations, existingHosts: existingHosts, localUser: localUser)
        }.value
        switch outcome {
        case .failure(let error):
            candidates = []
            issues = []
            fileCount = 0
            selection = []
            phase = .failed(error)
        case .success(let plan):
            candidates = plan.candidates
            issues = plan.issues
            fileCount = plan.fileCount
            selection = Set(plan.candidates.filter(\.isSelectedByDefault).map(\.id))
            phase = .loaded
        }
    }

    struct Plan: Sendable {
        var candidates: [SSHConfigImportCandidate]
        var issues: [SSHClientConfig.Issue]
        var fileCount: Int
    }

    /// Parses the config and plans the import. Runs off the main actor.
    nonisolated static func plan(
        locations: SSHConfigLocations, existingHosts: [RemoteHost], localUser: String
    ) -> Result<Plan, SSHConfigLoadError> {
        let config: SSHClientConfig
        do {
            config = try SSHClientConfig.load(locations)
        } catch {
            return .failure(error)
        }
        let existingNames = existingHosts.map(\.name)
        let candidates = SSHConfigImport.candidates(from: config, existingHosts: existingHosts, localUser: localUser)
            .map { checkedWithEditorRules($0, existingNames: existingNames) }
        return .success(Plan(candidates: candidates, issues: config.issues, fileCount: config.filesRead.count))
    }

    /// The host editor's validation as a last gate: a host that the editor wouldn't save is
    /// never added. (The planner applies the same rules; this keeps the two from drifting.)
    nonisolated static func checkedWithEditorRules(
        _ candidate: SSHConfigImportCandidate, existingNames: [String], password: String = ""
    ) -> SSHConfigImportCandidate {
        guard candidate.isSelectable else { return candidate }
        var draft = HostDraft(host: candidate.host)
        draft.password = password
        let validation = draft.validate(otherHostNames: existingNames)
        guard let message = HostDraft.Field.allCases.lazy.compactMap(validation.message(for:)).first else {
            return candidate
        }
        var refused = candidate
        refused.status = .unsupported(reason: message)
        return refused
    }

    // MARK: - Selection

    func isSelected(_ candidate: SSHConfigImportCandidate) -> Bool {
        candidate.isSelectable && selection.contains(candidate.id)
    }

    func setSelected(_ selected: Bool, _ candidate: SSHConfigImportCandidate) {
        guard candidate.isSelectable else { return }
        if selected {
            selection.insert(candidate.id)
        } else {
            selection.remove(candidate.id)
        }
    }

    /// Checks every host that isn't already in AeroOps (or earlier in the config).
    func selectAllNew() {
        selection = Set(candidates.filter(\.isSelectedByDefault).map(\.id))
    }

    func selectNone() {
        selection = []
    }

    // MARK: - Import

    /// Adds the checked hosts to `model`, in config order, and returns their ids. Stops at the
    /// first store error (the Keychain refused the write); hosts whose name was taken
    /// since the sheet opened are skipped. Either way ``importError`` says what happened.
    @discardableResult
    func importSelected(into model: AppModel) -> [RemoteHost.ID] {
        importError = nil
        var added: [RemoteHost.ID] = []
        var skipped: [String] = []
        for candidate in candidates where isSelected(candidate) {
            let host = HostDraft(host: candidate.host).makeHost()
            if HostDraft.nameIssue(host.name, otherHostNames: model.hosts.map(\.name)) != nil {
                skipped.append(host.name)
                continue
            }
            do {
                try model.addHost(host)
                added.append(host.id)
            } catch {
                importError = added.isEmpty
                    ? "No hosts were added: \(error.localizedDescription)"
                    : "Added \(added.count) of \(selectedCount) hosts, then stopped: \(error.localizedDescription)"
                return added
            }
        }
        if !skipped.isEmpty {
            let names = skipped.map { "“\(SSHConfigImport.displaySafe($0, limit: 40))”" }.formatted(.list(type: .and))
            importError = "Skipped \(names): another host now has that name."
        }
        return added
    }
}
