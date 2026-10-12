import AeroCore
import Foundation
import KeyAgent
import Observation

/// One run of the onboarding sheet: the current step and what the user has entered so far, so
/// Back and Continue never lose an unsaved key name or server form.
///
/// Keys and hosts themselves are created immediately through ``SSHServices`` and ``AppModel``;
/// the flow only remembers which ones were set up here.
@MainActor
@Observable
final class OnboardingFlow {
    enum Step: Int, CaseIterable, Identifiable, Comparable {
        case welcome, key, server, agents, done

        var id: Self { self }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Short label for the step indicator.
        var label: String {
            switch self {
            case .welcome: "Welcome"
            case .key: "Key"
            case .server: "Server"
            case .agents: "AI agents"
            case .done: "Done"
            }
        }

        var title: String {
            switch self {
            case .welcome: "Welcome to AeroOps"
            case .key: "Your SSH key"
            case .server: "Your first server"
            case .agents: "Connect AI agents"
            case .done: "You’re all set"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome:
                "A few steps get you from an empty window to a live server card."
            case .key:
                "AeroOps signs in with a key kept in your Keychain or the Secure Enclave. The private key never leaves this Mac."
            case .server:
                "Add a server you can reach over SSH. Test Connection checks the address, user and key before you add it."
            case .agents:
                "Optional: let Claude Code, Codex and other MCP clients read your servers through AeroOps."
            case .done:
                "Everything here can be changed later in Settings."
            }
        }

        var next: Step? { Step(rawValue: rawValue + 1) }
        var previous: Step? { Step(rawValue: rawValue - 1) }
    }

    var step: Step
    /// The "Generate key" fields.
    var keyDraft = NewKeyDraft()
    /// The key generated or imported in this run.
    var keyID: UUID?
    /// Shows the generate and import choices although a key exists ("Use Another Key…").
    var isChoosingKey = false
    /// The unsaved server form.
    var hostDraft = HostDraft()
    /// The server added in this run.
    var addedHostID: RemoteHost.ID?

    /// The key last put into ``hostDraft`` by ``preselectKey(_:)``, so a key the user picked
    /// themselves is never replaced.
    @ObservationIgnored private var preselectedKeyID: String?

    init(step: Step = .welcome) {
        self.step = step
    }

    /// The key the key step shows: the one set up in this run, else an existing one. `nil`
    /// while the user is choosing another key or there is none.
    func currentKey(in keys: [SSHKeyRecord]) -> SSHKeyRecord? {
        guard !isChoosingKey else { return nil }
        return keys.first { $0.id == keyID } ?? keys.first
    }

    /// The user started typing a server but hasn't added it.
    var hasUnsavedServer: Bool {
        !hostDraft.trimmedName.isEmpty || !hostDraft.trimmedAddress.isEmpty || !hostDraft.trimmedUser.isEmpty
    }

    /// Selects `key` in the server form unless the user picked a key there themselves.
    func preselectKey(_ key: UUID?) {
        guard hostDraft.keyId == preselectedKeyID else { return }
        hostDraft.keyId = key?.uuidString
        preselectedKeyID = hostDraft.keyId
    }
}
