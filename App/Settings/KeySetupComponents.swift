import AeroTheme
import AppKit
import CryptoKit
import KeyAgent
import SSHKit
import SwiftUI

// Key setup pieces shared by Settings › Keys and onboarding's "Your key" step, so both create,
// import and describe keys the same way. Private keys never pass through here: generation and
// import go through ``SSHServices``, which keeps them in the Keychain or the Secure Enclave.

// MARK: - Generate

/// What the user chose for a new key: name, type and Touch ID policy.
struct NewKeyDraft: Hashable {
    var name = ""
    var type: KeyGenerationType = .recommended
    var policy: SigningPolicy = .oncePerSession

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A name is set and the chosen type is available on this Mac.
    var canGenerate: Bool {
        !trimmedName.isEmpty && (type != .secureEnclaveP256 || SecureEnclave.isAvailable)
    }
}

extension KeyGenerationType {
    /// The type offered first: Secure Enclave when this Mac has one, else Ed25519.
    static var recommended: KeyGenerationType {
        SecureEnclave.isAvailable ? .secureEnclaveP256 : .ed25519
    }
}

/// The name, type and Touch ID rows for a new key, with their explanations. Place inside a `Form`.
struct KeyGenerationFields: View {
    @Binding var draft: NewKeyDraft

    var body: some View {
        TextField("Name", text: $draft.name, prompt: Text("MacBook key"))
        Picker("Type", selection: $draft.type) {
            ForEach(KeyGenerationType.allCases, id: \.self) { type in
                Text(type.title).tag(type)
            }
        }
        .pickerStyle(.radioGroup)
        Text(draft.type.explanation)
            .font(Aero.font(.caption))
            .foregroundStyle(Aero.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Picker("Touch ID", selection: $draft.policy) {
            ForEach(SigningPolicy.allCases, id: \.self) { policy in
                Text(policy.title).tag(policy)
            }
        }
        Text(draft.policy.explanation)
            .font(Aero.font(.caption))
            .foregroundStyle(Aero.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Import

/// Importing existing OpenSSH private key files: an open panel at `~/.ssh`, then
/// ``SSHServices/importKey(contentsOf:policy:)`` reads each file into memory and stores the key
/// in the Keychain. Afterwards offer ``SwiftUI/View/trashImportedKeyDialog(files:onError:)``.
@MainActor
enum KeyFileImport {
    /// Touch ID policy for imported keys; it can be changed in Settings › Keys.
    static let policy: SigningPolicy = .oncePerSession

    /// Shows the open panel. Returns the chosen files, or none when the user cancels. Files that
    /// are never private keys (`.pub`, `known_hosts`, `config`…) are greyed out.
    static func chooseFiles(allowsMultipleSelection: Bool) -> [URL] {
        let panel = NSOpenPanel()
        let filter = KeyFilePanelFilter()
        panel.delegate = filter
        panel.title = allowsMultipleSelection ? "Import SSH Keys" : "Import SSH Key"
        panel.message = allowsMultipleSelection
            ? "Choose one or more unencrypted OpenSSH private keys (for example id_ed25519, not id_ed25519.pub). Passphrase-protected keys are not supported yet."
            : "Choose an unencrypted OpenSSH private key (for example id_ed25519, not id_ed25519.pub). Passphrase-protected keys are not supported yet."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: ".ssh", directoryHint: .isDirectory)
        let response = withExtendedLifetime(filter) { panel.runModal() }
        return response == .OK ? panel.urls : []
    }

    /// Imports each file in turn. One file that fails does not stop the others.
    static func importFiles(_ urls: [URL], into ssh: SSHServices) async -> Outcome {
        var outcome = Outcome()
        for url in urls {
            do {
                let record = try await ssh.importKey(contentsOf: url, policy: policy)
                outcome.imported.append((url, record))
            } catch {
                outcome.failures.append((url, error.localizedDescription))
            }
        }
        return outcome
    }

    struct Outcome {
        var imported: [(file: URL, key: SSHKeyRecord)] = []
        var failures: [(file: URL, message: String)] = []

        /// The failures for display, each prefixed with its file name when several files were
        /// chosen; `nil` when every file was imported.
        var failureMessage: String? {
            guard !failures.isEmpty else { return nil }
            if imported.isEmpty && failures.count == 1 { return failures[0].message }
            return failures.map { "\($0.file.lastPathComponent): \($0.message)" }.joined(separator: "\n")
        }
    }

    /// Names in `~/.ssh` that never hold a private key.
    static func isNeverPrivateKey(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return url.pathExtension == "pub"
            || name.hasPrefix("known_hosts")
            || name.hasPrefix("authorized_keys")
            || ["config", "environment", "rc", ".DS_Store"].contains(name)
    }
}

/// Greys out ``KeyFileImport/isNeverPrivateKey(_:)`` files in the open panel, so the `.pub`
/// listed right after each key cannot be picked by mistake.
private final class KeyFilePanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.hasDirectoryPath || !KeyFileImport.isNeverPrivateKey(url)
    }
}

extension View {
    /// After an import, offers to move the unencrypted key files to the Trash. Set `files` to
    /// the imported files to ask; `onError` gets a message when the move fails.
    func trashImportedKeyDialog(files: Binding<[URL]>, onError: @escaping @MainActor (String) -> Void) -> some View {
        modifier(TrashImportedKeyDialog(files: files, onError: onError))
    }
}

private struct TrashImportedKeyDialog: ViewModifier {
    @Binding var files: [URL]
    let onError: @MainActor (String) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { !files.isEmpty }, set: { if !$0 { files = [] } }),
            presenting: files
        ) { urls in
            Button("Move to Trash", role: .destructive) { moveToTrash(urls) }
            Button(urls.count == 1 ? "Keep File" : "Keep Files", role: .cancel) {}
        } message: { urls in
            Text(urls.count == 1
                ? "The key is now in your Keychain and served by AeroOps’ agent. Moving the unencrypted file to the Trash leaves no readable copy of the private key on disk. Its .pub file is left alone."
                : "The keys are now in your Keychain and served by AeroOps’ agent. Moving the unencrypted files to the Trash leaves no readable copy of the private keys on disk. Their .pub files are left alone.")
        }
    }

    private var title: String {
        files.count == 1
            ? "Move “\(files[0].lastPathComponent)” to the Trash?"
            : "Move \(files.count) key files to the Trash?"
    }

    private func moveToTrash(_ urls: [URL]) {
        let onError = onError
        Task {
            do {
                _ = try await NSWorkspace.shared.recycle(urls)
            } catch {
                onError("Could not move \(urls.map(\.lastPathComponent).formatted(.list(type: .and))) to the Trash: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - System agent

/// "Use system ssh-agent instead": ssh then signs with the agent in `$SSH_AUTH_SOCK` and AeroOps'
/// keys are not offered (``SSHServices/setAgentChoice(_:)``, remembered across launches).
struct SystemAgentToggle: View {
    @Environment(AppModel.self) private var model
    /// The explanation under the label.
    var caption = "ssh then uses the agent in $SSH_AUTH_SOCK (for example 1Password or Secretive) and the keys above are not offered. Turn this on only if your keys live in another agent."

    var body: some View {
        let ssh = model.ssh
        Toggle(isOn: Binding(
            get: { ssh.agentChoice == .system },
            set: { useSystem in Task { await ssh.setAgentChoice(useSystem ? .system : .inApp) } }
        )) {
            Text("Use system ssh-agent instead")
                .font(Aero.font(.callout, weight: .medium))
                .foregroundStyle(Aero.text.primary)
            Text(caption)
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Helpers

/// A `Binding<Bool>` that is true while `item` is set and clears it when dismissed.
func isPresent<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
    item.isSet
}

private extension Optional {
    /// Whether a value is present; setting `false` clears it.
    var isSet: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}
