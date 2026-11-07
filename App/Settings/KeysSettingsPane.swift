import AeroCore
import AeroTheme
import AppKit
import CryptoKit
import KeyAgent
import SSHKit
import SwiftUI

/// Settings › Keys: the keys AeroOps' agent serves, with generate, import, rename, Touch ID
/// policy, delete and "Copy authorized_keys line", plus the agent's status and the "Use system
/// ssh-agent instead" fallback.
///
/// Private keys never reach the UI: only ``SSHKeyRecord`` metadata does. Imported files (several
/// at once if chosen together) are read into memory, stored in the Keychain, and the user is
/// offered to move them to the Trash.
struct KeysSettingsPane: View {
    @Environment(AppModel.self) private var model

    @State private var isGenerating = false
    @State private var renaming: SSHKeyRecord?
    @State private var newName = ""
    @State private var deletionCandidate: SSHKeyRecord?
    @State private var importedFiles: [URL] = []
    @State private var actionError: String?

    var body: some View {
        let ssh = model.ssh
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let actionError {
                    ValidationMessage(text: actionError)
                }
                if let storeError = ssh.keyStoreError {
                    ValidationMessage(text: "Key store: \(storeError)")
                }
                if ssh.keys.isEmpty {
                    emptyKeys
                } else {
                    ForEach(ssh.keys) { key in
                        KeyCard(
                            key: key,
                            hostNames: hostNames(using: key),
                            isUnused: ssh.agentChoice == .system,
                            onPolicy: { policy in perform { try await ssh.setPolicy(policy, forKey: key.id) } },
                            onSyncs: { syncs in perform { try await ssh.setSyncs(syncs, forKey: key.id) } },
                            onRename: {
                                newName = key.name
                                renaming = key
                            },
                            onDelete: { deletionCandidate = key }
                        )
                    }
                }
                AgentSection()
            }
            .padding(20)
        }
        .background { Aero.sky.gradient.ignoresSafeArea() }
        .sheet(isPresented: $isGenerating) {
            GenerateKeySheet()
        }
        .alert("Rename Key", isPresented: isPresent($renaming), presenting: renaming) { key in
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != key.name else { return }
                perform { try await ssh.renameKey(key.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deletionCandidate?.name ?? "")”?",
            isPresented: isPresent($deletionCandidate),
            presenting: deletionCandidate
        ) { key in
            Button("Delete Key", role: .destructive) {
                perform { try await ssh.deleteKey(key.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text(deletionMessage(for: key))
        }
        .trashImportedKeyDialog(files: $importedFiles) { actionError = $0 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH keys")
                    .font(Aero.font(.title2, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                Text("Private keys stay in the Keychain or the Secure Enclave and are used only through AeroOps’ own ssh-agent.")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Import…", systemImage: "square.and.arrow.down", action: importKeys)
                .buttonStyle(.aquaSecondary)
                .help("Import one or more unencrypted OpenSSH private key files")
            Button("Generate…", systemImage: "plus") { isGenerating = true }
                .buttonStyle(.aqua)
        }
    }

    private var emptyKeys: some View {
        AeroCard(padding: 24) {
            VStack(spacing: 10) {
                Image(systemName: "key.horizontal")
                    .font(Aero.font(size: 36, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Aero.aqua)
                    .accessibilityHidden(true)
                Text("No keys yet")
                    .font(Aero.font(.title3, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                Text("Generate an Ed25519 or Secure Enclave key, or import an existing OpenSSH key. Then copy its authorized_keys line to your servers.")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func hostNames(using key: SSHKeyRecord) -> [String] {
        model.hosts.filter { $0.keyId == key.id.uuidString }.map(\.name)
    }

    private func deletionMessage(for key: SSHKeyRecord) -> String {
        let hosts = hostNames(using: key)
        let usage = hosts.isEmpty
            ? "No host uses this key."
            : "Used by \(hosts.formatted(.list(type: .and))). These hosts can't connect until you choose another key."
        let loss = key.algorithm == .secureEnclaveP256
            ? "The Secure Enclave key is destroyed and cannot be recovered."
            : "The private key is removed from the Keychain\(key.syncs ? " on all your devices" : "") and cannot be recovered."
        return "\(usage) \(loss)"
    }

    private func importKeys() {
        let urls = KeyFileImport.chooseFiles(allowsMultipleSelection: true)
        guard !urls.isEmpty else { return }
        let ssh = model.ssh
        actionError = nil
        Task {
            let outcome = await KeyFileImport.importFiles(urls, into: ssh)
            actionError = outcome.failureMessage
            importedFiles = outcome.imported.map(\.file)
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        actionError = nil
        Task {
            do {
                try await work()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// One key: name, type, fingerprint, created date, hosts using it, Touch ID policy, and actions.
private struct KeyCard: View {
    let key: SSHKeyRecord
    let hostNames: [String]
    /// The system agent is in use, so AeroOps' keys are not offered to servers.
    let isUnused: Bool
    /// Main-actor isolated (and so Sendable): it becomes the Touch ID picker binding's setter.
    let onPolicy: @MainActor (SigningPolicy) -> Void
    /// The iCloud Keychain toggle binding's setter.
    let onSyncs: @MainActor (Bool) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        AeroCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: key.algorithm == .secureEnclaveP256 ? "cpu" : "key.horizontal.fill")
                        .font(Aero.font(.title3))
                        .foregroundStyle(Aero.aquaDeep)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text(key.name)
                        .font(Aero.font(.headline, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                        .lineLimit(1)
                    AeroTag(key.algorithm.displayName, tint: key.algorithm == .secureEnclaveP256 ? Aero.leaf : Aero.aqua)
                    if key.origin == .imported {
                        AeroTag("Imported", tint: Aero.neutral)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Button("Rename…", systemImage: "pencil", action: onRename)
                        Button("Copy authorized_keys Line", systemImage: "doc.on.doc") { Clipboard.copy(key.authorizedKeysLine) }
                        Button("Copy Fingerprint", systemImage: "number") { Clipboard.copy(key.fingerprint) }
                        Divider()
                        Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Rename, copy or delete this key")
                }

                Text(key.fingerprint)
                    .font(Aero.monospacedFont(.callout))
                    .foregroundStyle(Aero.text.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(details)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Picker("Touch ID", selection: Binding(get: { key.policy }, set: onPolicy)) {
                        ForEach(SigningPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help(key.policy.explanation)
                    if key.canSync {
                        Toggle("iCloud Keychain", isOn: Binding(get: { key.syncs }, set: onSyncs))
                            .toggleStyle(.checkbox)
                            .help("Sync this key to your other devices with iCloud Keychain")
                    }
                    Spacer(minLength: 8)
                    CopyAuthorizedKeysButton(key: key)
                }
                .font(Aero.font(.callout))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(key.name)
    }

    private var details: String {
        var parts = ["Created \(key.createdAt.formatted(date: .abbreviated, time: .omitted))"]
        parts.append(hostNames.isEmpty ? "Not used by any host" : "Used by \(hostNames.formatted(.list(type: .and)))")
        if !key.canSync { parts.append("Stays on this Mac") }
        if isUnused { parts.append("Not offered while the system ssh-agent is in use") }
        return parts.joined(separator: " · ")
    }
}

/// "Copy authorized_keys Line": puts the key's public line on the pasteboard and confirms.
struct CopyAuthorizedKeysButton: View {
    let key: SSHKeyRecord
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy authorized_keys Line", systemImage: copied ? "checkmark" : "doc.on.doc") {
            Clipboard.copy(key.authorizedKeysLine)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .buttonStyle(.aquaSecondary)
        .controlSize(.small)
        .help("Paste this line into ~/.ssh/authorized_keys on the server:\n\(key.authorizedKeysLine)")
    }
}

/// The general pasteboard, for public data only (authorized_keys lines, fingerprints).
@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Agent status, recent peer and signing events, and the system-agent fallback toggle.
private struct AgentSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ssh = model.ssh
        GlassSection("ssh-agent", systemImage: "person.badge.key") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusOrb(tone: tone(ssh.agentStatus), size: 10)
                    Text(statusText(ssh.agentStatus))
                        .font(Aero.font(.callout, weight: .medium))
                        .foregroundStyle(Aero.text.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !ssh.agentEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(ssh.agentEvents.suffix(4).reversed().enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(event.date.formatted(date: .omitted, time: .standard))
                                    .monospacedDigit()
                                    .foregroundStyle(Aero.text.secondary)
                                Text(event.summary)
                                    .foregroundStyle(Aero.text.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(Aero.font(.caption))
                        }
                    }
                }

                SystemAgentToggle()
            }
        } accessory: {
            if !ssh.agentEvents.isEmpty {
                AeroTag("\(ssh.agentEvents.count) recent events", tint: Aero.neutral)
            }
        }
    }

    private func tone(_ status: SSHServices.AgentStatus) -> OrbTone {
        switch status {
        case .running: .healthy
        case .usingSystemAgent: .neutral
        case .stopped: .warning
        case .failed: .error
        }
    }

    private func statusText(_ status: SSHServices.AgentStatus) -> String {
        switch status {
        case .running(let socket): "Running on \(socket)"
        case .usingSystemAgent: "Stopped: ssh uses the system ssh-agent"
        case .stopped: "Stopped"
        case .failed(let reason): "Not running: \(reason)"
        }
    }
}

extension AgentEvent {
    /// One line for the UI.
    var summary: String {
        switch kind {
        case .connected(let peer):
            peer.isTrustedAppSSH ? "ssh connected (started by AeroOps)" : "Client connected: \(peer.summary)"
        case .rejected(let reason):
            "Client rejected: \(reason)"
        case .signed(_, let keyName, let algorithm, let user, _):
            "Signed with “\(keyName)” (\(algorithm))" + (user.map { " for \($0)" } ?? "")
        case .signFailed(_, let reason):
            "Signing refused: \(reason)"
        case .identitiesListed(let count):
            "Listed \(count) keys"
        case .sessionBound(let fingerprint, _):
            "Session bound to \(fingerprint)"
        case .refused(let request):
            "Refused \(request)"
        case .disconnected:
            "Disconnected"
        }
    }
}

/// Name, type and Touch ID policy for a new key.
private struct GenerateKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = NewKeyDraft()
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Generate Key")
                .font(Aero.font(.title2, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
                .padding([.horizontal, .top], 20)
            Form {
                KeyGenerationFields(draft: $draft)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .font(Aero.font(.body))

            HStack(spacing: 12) {
                if let error {
                    ValidationMessage(text: error)
                } else if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 12)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.aquaSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Generate", action: generate)
                    .buttonStyle(.aqua)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canGenerate || isWorking)
            }
            .padding(16)
        }
        .frame(width: 480, height: 470)
        .background { Aero.sky.gradient.ignoresSafeArea() }
    }

    private func generate() {
        isWorking = true
        error = nil
        let ssh = model.ssh
        let draft = draft
        Task {
            do {
                _ = try await ssh.generateKey(draft.type, name: draft.trimmedName, policy: draft.policy)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// The Keys pane with sample keys (generated in memory).
private struct KeysPanePreview: View {
    @State private var model = AppModel.preview()
    var withKeys = true

    var body: some View {
        KeysSettingsPane()
            .environment(model)
            .frame(width: 780, height: 600)
            .task {
                if withKeys { await model.ssh.loadSampleData() }
            }
    }
}

#Preview("Keys pane") {
    KeysPanePreview()
}

#Preview("Keys pane · empty") {
    KeysPanePreview(withKeys: false)
}

#Preview("Generate key") {
    GenerateKeySheet()
        .environment(AppModel.preview())
}
