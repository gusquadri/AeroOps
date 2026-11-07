import AeroTheme
import KeyAgent
import SwiftUI
import UIKit

/// The keys AeroOps signs in with. Their secrets stay in this device's Keychain (or Secure
/// Enclave); only the public key is shown, copied or shared, to add to a server's
/// authorized_keys.
struct KeysScreen: View {
    /// Closes the screen when it is a sheet (the split layout's).
    var onDone: (() -> Void)?
    @Environment(MobileModel.self) private var model
    @State private var isCreating = false
    @State private var path: [SSHKeyRecord.ID] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background { SkyBackground() }
                .navigationTitle("Keys")
                .toolbar {
                    if let onDone {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done", action: onDone)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Key", systemImage: "plus") { isCreating = true }
                            .disabled(!model.hasKeyStore)
                    }
                }
                .navigationDestination(for: SSHKeyRecord.ID.self) { id in
                    KeyDetailScreen(id: id)
                }
        }
        .sheet(isPresented: $isCreating) {
            NewKeySheet()
        }
        .task(id: model.keys.first?.id) { openDebugScreen() }
    }

    private func openDebugScreen() {
        switch MobileDebugOptions.screen {
        case .newKey: isCreating = true
        case .key: if let first = model.keys.first { path = [first.id] }
        default: break
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.keyStoreError, model.keys.isEmpty {
            AeroEmptyState(systemImage: "exclamationmark.triangle", title: "Keys are unavailable", message: error)
        } else if model.keys.isEmpty {
            AeroEmptyState(
                systemImage: "key.horizontal",
                title: "No keys yet",
                message: "Create a key, then add its public key to your servers’ authorized_keys. The private key never leaves this device."
            ) {
                Button("New Key", systemImage: "plus") { isCreating = true }
                    .buttonStyle(.aqua)
            }
        } else {
            List(model.keys) { key in
                NavigationLink(value: key.id) {
                    KeyRow(key: key)
                }
                .listRowBackground(Aero.glass.fill)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct KeyRow: View {
    let key: SSHKeyRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: key.algorithm == .secureEnclaveP256 ? "cpu" : "key.horizontal.fill")
                .font(Aero.font(.title3))
                .foregroundStyle(Aero.aquaDeep)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(key.name)
                    .font(Aero.font(.headline))
                    .foregroundStyle(Aero.text.primary)
                Text("\(key.algorithm.displayName) · \(key.policy.title)")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct NewKeySheet: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "AeroOps \(UIDevice.current.name)"
    @State private var type = KeyGenerationType.recommended
    @State private var policy = SigningPolicy.oncePerSession
    @State private var isGenerating = false
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(KeyGenerationType.allCases.filter { $0 != .secureEnclaveP256 || model.canUseSecureEnclave }, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                } header: {
                    Text("Type")
                } footer: {
                    Text(type.explanation)
                }
                Section {
                    Picker("Ask", selection: $policy) {
                        ForEach(SigningPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Before signing in")
                } footer: {
                    Text(policy.explanation)
                }
                if let error {
                    Section { ValidationMessage(text: error) }
                }
            }
            .scrollContentBackground(.hidden)
            .background { SkyBackground() }
            .navigationTitle("New Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Button("Create", action: generate)
                            .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isGenerating)
    }

    private func generate() {
        isGenerating = true
        Task {
            defer { isGenerating = false }
            do {
                try await model.generateKey(type, name: trimmedName, policy: policy)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct KeyDetailScreen: View {
    let id: SSHKeyRecord.ID
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        if let key = model.keys.first(where: { $0.id == id }) {
            details(key)
        } else {
            AeroEmptyState(systemImage: "key.horizontal", title: "Key deleted", message: "This key is no longer in AeroOps.")
        }
    }

    private func details(_ key: SSHKeyRecord) -> some View {
        let users = model.hosts.filter { $0.keyId == key.id.uuidString }
        return Form {
            summary(key)
            publicKey(key.authorizedKeysLine)
            settings(key)
            if let error {
                Section { ValidationMessage(text: error) }
            }
            Section {
                Button("Delete Key", role: .destructive) { isConfirmingDelete = true }
            } footer: {
                if !users.isEmpty {
                    Text("Used by \(users.map(\.name).formatted()).")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { SkyBackground() }
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete “\(key.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Key", role: .destructive) { delete(key) }
        } message: {
            Text(Self.deletionMessage(key))
        }
    }

    private func summary(_ key: SSHKeyRecord) -> some View {
        Section {
            LabeledContent("Type", value: key.algorithm.displayName)
            LabeledContent("Created", value: key.createdAt.formatted(date: .abbreviated, time: .shortened))
            VStack(alignment: .leading, spacing: 4) {
                Text("Fingerprint")
                Text(key.fingerprint)
                    .font(Aero.monospacedFont(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func publicKey(_ line: String) -> some View {
        Section {
            Text(line)
                .font(Aero.monospacedFont(.caption))
                .textSelection(.enabled)
            Button(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = line
                copied = true
            }
            ShareLink("Share Public Key", item: line)
        } header: {
            Text("Public key")
        } footer: {
            Text("Add this line to ~/.ssh/authorized_keys on each server.")
        }
    }

    @ViewBuilder
    private func settings(_ key: SSHKeyRecord) -> some View {
        Section {
            Picker("Ask", selection: binding(key.policy) { try await model.setPolicy($0, for: key.id) }) {
                ForEach(SigningPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Before signing in")
        } footer: {
            Text(key.policy.explanation)
        }
        Section {
            if key.canSync {
                Toggle("iCloud Keychain", isOn: binding(key.syncs) { try await model.setSyncs($0, for: key.id) })
            }
        } footer: {
            Text(key.canSync
                 ? "Syncs this key to your other devices, including AeroOps on your Mac."
                 : "Secure Enclave keys stay on this device.")
        }
    }

    private static func deletionMessage(_ key: SSHKeyRecord) -> String {
        let consequence = "Servers that only accept this key will refuse AeroOps."
        if key.algorithm == .secureEnclaveP256 {
            return "The key is destroyed and can’t be recovered. \(consequence)"
        }
        return "The private key is removed from \(key.syncs ? "the Keychain on all your devices" : "this device’s Keychain"). \(consequence)"
    }

    /// Shows `value`; a change runs `change` and shows its error.
    private func binding<Value: Sendable>(_ value: Value, _ change: @escaping @MainActor (Value) async throws -> Void) -> Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                Task {
                    do {
                        try await change(newValue)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        )
    }

    private func delete(_ key: SSHKeyRecord) {
        Task {
            do {
                try await model.deleteKey(key.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#Preview("Keys") {
    let model = MobileModel.preview()
    KeysScreen()
        .environment(model)
        .task { try? await model.generateKey(.ed25519, name: "iPhone", policy: .oncePerSession) }
}

#Preview("Keys · empty") {
    KeysScreen()
        .environment(MobileModel.preview())
}
