import AeroCore
import AeroTheme
import AppKit
import KeyAgent
import SSHKit
import SwiftUI

struct OnboardingWelcomeStep: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                Text("AeroOps watches your Linux servers over SSH: live health cards, Docker containers and Kubernetes pods with their logs, and terminal tabs, all in one window. AI agents such as Claude Code can read the same data through a local MCP server, and they are told to ask you before running any command.")
                    .font(Aero.font(.body))
                    .foregroundStyle(Aero.text.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
                AeroCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        plan("key.horizontal.fill", "Create or import an SSH key")
                        plan("server.rack", "Add your first server and test the connection")
                        plan("sparkles", "Optionally connect an AI agent")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func plan(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(Aero.text.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Aero.aquaDeep)
                .frame(width: 22)
        }
        .font(Aero.font(.callout, weight: .medium))
    }
}

/// Generate a Secure Enclave or Ed25519 key, or import a key file, then copy its public line.
/// With "Use system ssh-agent instead" on, the step can be passed without a key.
struct OnboardingKeyStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var flow: OnboardingFlow

    @State private var isWorking = false
    @State private var error: String?
    @State private var importedFiles: [URL] = []

    var body: some View {
        Group {
            if let key = flow.currentKey(in: model.ssh.keys) {
                keySummary(key)
            } else {
                keyForm
            }
        }
        .trashImportedKeyDialog(files: $importedFiles) { error = $0 }
    }

    private static let agentCaption = "If your keys already live in 1Password, Secretive or another ssh-agent, ssh uses the agent in $SSH_AUTH_SOCK and AeroOps needs no key of its own. You can change this in Settings › Keys."

    private var keyForm: some View {
        Form {
            Section("New key") {
                KeyGenerationFields(draft: $flow.keyDraft)
            }
            Section {
                HStack(spacing: 10) {
                    if let error {
                        ValidationMessage(text: error)
                    } else if isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 8)
                    if flow.isChoosingKey, !model.ssh.keys.isEmpty {
                        Button("Cancel") { flow.isChoosingKey = false }
                            .buttonStyle(.aquaSecondary)
                    }
                    Button("Import Existing Key…", systemImage: "square.and.arrow.down", action: importKey)
                        .buttonStyle(.aquaSecondary)
                        .help("Import an unencrypted OpenSSH private key file, such as ~/.ssh/id_ed25519")
                        .disabled(isWorking)
                    Button("Generate Key", systemImage: "key.horizontal", action: generate)
                        .buttonStyle(.aqua)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!flow.keyDraft.canGenerate || isWorking)
                }
            }
            Section {
                SystemAgentToggle(caption: Self.agentCaption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(Aero.font(.body))
    }

    private func keySummary(_ key: SSHKeyRecord) -> some View {
        let isSecureEnclave = key.algorithm == .secureEnclaveP256
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassSection("Public key", systemImage: isSecureEnclave ? "cpu" : "key.horizontal.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(key.name)
                                .font(Aero.font(.headline, weight: .semibold))
                                .foregroundStyle(Aero.text.primary)
                                .lineLimit(1)
                            AeroTag(key.algorithm.displayName, tint: isSecureEnclave ? Aero.leaf : Aero.aqua)
                            if key.origin == .imported {
                                AeroTag("Imported", tint: Aero.neutral)
                            }
                        }
                        Text(key.fingerprint)
                            .font(Aero.monospacedFont(.callout))
                            .foregroundStyle(Aero.text.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: key.authorizedKeysLine)
                            .font(Aero.monospacedFont(.caption))
                            .foregroundStyle(Aero.text.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background { Well(tint: Aero.aqua) }
                            .accessibilityLabel("authorized_keys line")
                        Label("On each server, add this line to ~/.ssh/authorized_keys of the user AeroOps signs in as.", systemImage: "info.circle")
                            .font(Aero.font(.caption))
                            .foregroundStyle(Aero.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            CopyAuthorizedKeysButton(key: key)
                            Spacer(minLength: 8)
                            Button("Use Another Key…") {
                                error = nil
                                flow.isChoosingKey = true
                            }
                            .buttonStyle(.aquaSecondary)
                            .controlSize(.small)
                        }
                    }
                } accessory: {
                    if model.ssh.agentChoice == .system {
                        AeroTag("Not offered: system agent on", tint: Aero.neutral)
                    }
                }
                GlassSection("Another ssh-agent", systemImage: "person.badge.key") {
                    SystemAgentToggle(caption: Self.agentCaption)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func generate() {
        let draft = flow.keyDraft
        guard draft.canGenerate else { return }
        let ssh = model.ssh
        run {
            let record = try await ssh.generateKey(draft.type, name: draft.trimmedName, policy: draft.policy)
            flow.keyID = record.id
            flow.keyDraft = NewKeyDraft()
        }
    }

    private func importKey() {
        guard let url = KeyFileImport.chooseFiles(allowsMultipleSelection: false).first else { return }
        let ssh = model.ssh
        run {
            let record = try await ssh.importKey(contentsOf: url, policy: KeyFileImport.policy)
            flow.keyID = record.id
            importedFiles = [url]
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        error = nil
        Task {
            do {
                try await work()
                flow.isChoosingKey = false
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// The host editor for a first server, or "Import from ~/.ssh/config"; then a summary of the
/// servers added. Hosts added either way complete the step.
struct OnboardingServerStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var flow: OnboardingFlow

    @State private var editing: HostEditorRequest?
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(model.hosts.isEmpty ? "Already listed in ~/.ssh/config?" : "More servers in ~/.ssh/config?")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                Spacer(minLength: 8)
                Button("Import from ~/.ssh/config…", systemImage: "square.and.arrow.down") { isImporting = true }
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
                    .help("Pick hosts from your ssh config. AeroOps reads the file and never changes it.")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
            if model.hosts.isEmpty {
                HostEditorForm(
                    original: nil,
                    onSave: add,
                    initialDraft: flow.hostDraft,
                    onDraftChange: { flow.hostDraft = $0 }
                )
            } else {
                serverList
            }
        }
        .sheet(item: $editing) { request in
            HostEditorSheet(request: request)
        }
        .sshConfigImportSheet(isPresented: $isImporting) { ids in
            if let first = ids.first { flow.addedHostID = first }
        }
    }

    private var serverList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.hosts.prefix(6)) { host in
                    serverRow(host)
                }
                if model.hosts.count > 6 {
                    Text("and \(model.hosts.count - 6) more")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                }
                Label("Add more servers any time with Add Host in the sidebar. Continue when you’re ready.", systemImage: "info.circle")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func serverRow(_ host: RemoteHost) -> some View {
        AeroCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(Aero.font(.title3))
                    .foregroundStyle(Aero.aquaDeep)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: host.name)
                            .font(Aero.font(.headline, weight: .semibold))
                            .foregroundStyle(Aero.text.primary)
                            .lineLimit(1)
                        if host.id == flow.addedHostID {
                            AeroTag("Added", systemImage: "checkmark", tint: Aero.leaf)
                        }
                    }
                    Text(verbatim: host.connectionSummary)
                        .font(Aero.monospacedFont(.callout))
                        .foregroundStyle(Aero.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(keyDescription(for: host))
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                AeroTag(host.mcpTier.title, systemImage: host.mcpTier.systemImage, tint: host.mcpTier.tint)
                    .help("AI agent access: \(host.mcpTier.explanation)")
                Button("Edit…") { editing = .edit(host.id) }
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
                    .accessibilityLabel("Edit \(host.name)")
            }
        }
    }

    private func keyDescription(for host: RemoteHost) -> String {
        if model.ssh.agentChoice == .system { return "Signs in with the system ssh-agent" }
        guard let keyId = host.keyId else { return "No key chosen" }
        let name = model.availableKeys.first { $0.id == keyId }?.name ?? "an unknown key"
        return "Signs in with “\(name)”"
    }

    private func add(_ host: RemoteHost) throws(HostStoreError) {
        try model.addHost(host)
        flow.addedHostID = host.id
        flow.hostDraft = HostDraft()
    }
}

/// The MCP config snippets (copied, never written to an agent's files) and the access tiers.
struct OnboardingAgentsStep: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassSection("Access per server", systemImage: "server.rack") {
                    MCPTierGuide()
                }
                ConnectAgentSection()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The three MCP access tiers, with the default marked.
struct MCPTierGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MCPTier.allCases, id: \.self) { tier in
                HStack(spacing: 10) {
                    AeroTag(tier.title, systemImage: tier.systemImage, tint: tier.tint)
                        .frame(width: 120, alignment: .leading)
                    Text(tier.explanation)
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if tier == .default {
                        AeroTag("Default", tint: Aero.neutral)
                    }
                }
            }
            Text("Every server starts at Read. Change it under “AI agents (MCP)” in the server’s editor. Agents never see your keys, every call is logged, and agents are told to ask you before running a command.")
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OnboardingDoneStep: View {
    @Environment(AppModel.self) private var model
    let flow: OnboardingFlow

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.seal.fill")
                    .font(Aero.font(size: 56, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Aero.leaf)
                    .accessibilityHidden(true)
                AeroCard(padding: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        keyRow
                        serverRow
                        row(
                            systemImage: "sparkles",
                            title: "AI agents",
                            detail: "Config snippets are in Settings › MCP whenever you want them.",
                            done: true
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var keyRow: some View {
        if model.ssh.agentChoice == .system {
            row(systemImage: "person.badge.key", title: "System ssh-agent", detail: "ssh signs with the agent in $SSH_AUTH_SOCK.", done: true)
        } else if let key = flow.currentKey(in: model.ssh.keys) {
            row(systemImage: "key.horizontal.fill", title: "Key “\(key.name)”", detail: "\(key.algorithm.displayName) · \(key.fingerprint)", done: true)
        } else {
            row(systemImage: "key.horizontal", title: "No key yet", detail: "Create or import one in Settings › Keys.", done: false)
        }
    }

    @ViewBuilder
    private var serverRow: some View {
        if let host = flow.addedHostID.flatMap(model.host(id:)) ?? model.hosts.first {
            let others = model.hosts.count - 1
            row(
                systemImage: "server.rack",
                title: host.name + (others > 0 ? " and \(others) more" : ""),
                detail: "\(host.connectionSummary) · AI agents: \(host.mcpTier.title)",
                done: true
            )
        } else {
            row(systemImage: "server.rack", title: "No server yet", detail: "Add one with Add Host in the sidebar.", done: false)
        }
    }

    private func row(systemImage: String, title: String, detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(Aero.font(.title3))
                .foregroundStyle(Aero.aquaDeep)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(Aero.font(.headline, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                Text(verbatim: detail)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            StatusOrb(tone: done ? .healthy : .neutral, size: 10)
                .accessibilityLabel(done ? "Set up" : "Not set up")
        }
    }
}
