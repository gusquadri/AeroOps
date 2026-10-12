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

/// Importing an existing OpenSSH private key file: an open panel at `~/.ssh`, then
/// ``SSHServices/importKey(contentsOf:policy:)`` reads the file into memory and stores the key in
/// the Keychain. Afterwards offer ``SwiftUI/View/trashImportedKeyDialog(file:onError:)``.
@MainActor
enum KeyFileImport {
    /// Touch ID policy for imported keys; it can be changed in Settings › Keys.
    static let policy: SigningPolicy = .oncePerSession

    /// Shows the open panel. Returns the chosen file, or `nil` when the user cancels.
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import SSH Key"
        panel.message = "Choose an unencrypted OpenSSH private key (for example id_ed25519). Passphrase-protected keys are not supported yet."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: ".ssh", directoryHint: .isDirectory)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

extension View {
    /// After an import, offers to move the unencrypted key file to the Trash. Set `file` to the
    /// imported file to ask; `onError` gets a message when the move fails.
    func trashImportedKeyDialog(file: Binding<URL?>, onError: @escaping @MainActor (String) -> Void) -> some View {
        modifier(TrashImportedKeyDialog(file: file, onError: onError))
    }
}

private struct TrashImportedKeyDialog: ViewModifier {
    @Binding var file: URL?
    let onError: @MainActor (String) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Move “\(file?.lastPathComponent ?? "")” to the Trash?",
            isPresented: isPresent($file),
            presenting: file
        ) { url in
            Button("Move to Trash", role: .destructive) { moveToTrash(url) }
            Button("Keep File", role: .cancel) {}
        } message: { _ in
            Text("The key is now in your Keychain and served by AeroOps’ agent. Moving the unencrypted file to the Trash leaves no readable copy of the private key on disk. Its .pub file is left alone.")
        }
    }

    private func moveToTrash(_ url: URL) {
        let onError = onError
        Task {
            do {
                _ = try await NSWorkspace.shared.recycle([url])
            } catch {
                onError("Could not move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
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
