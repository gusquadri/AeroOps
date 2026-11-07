import AeroCore
import AeroTheme
import SwiftUI

/// Add or edit a host: name, address, port, user, how to sign in, tags and monitoring. The Mac's Docker,
/// Kubernetes and MCP settings are not here yet; ``HostDraft`` keeps their values on save.
struct HostEditorScreen: View {
    enum Request: Identifiable, Hashable {
        case new
        /// A new host, saved last into the folder with this ID.
        case newIn(HostFolder.ID)
        case edit(RemoteHost.ID)

        var id: Self { self }

        var folder: HostFolder.ID? {
            if case .newIn(let id) = self { id } else { nil }
        }
    }

    let request: Request
    /// Called after the host is deleted (the host screen pops).
    var onDelete: () -> Void = {}

    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = HostDraft()
    @State private var baseline = HostDraft()
    @State private var hasSavedPassword = false
    @State private var revealAllIssues = false
    @State private var saveError: String?
    @State private var isConfirmingDelete = false
    @State private var isLoaded = false

    private var isNew: Bool {
        if case .edit = request { false } else { true }
    }

    var body: some View {
        let validation = draft.validate(
            otherHostNames: model.hosts.filter { $0.id != draft.id }.map(\.name),
            hasSavedPassword: hasSavedPassword
        )
        NavigationStack {
            Form {
                Section("Server") {
                    field(.name, validation) {
                        LabeledContent("Name") {
                            TextField("Name", text: $draft.name, prompt: Text("web-1"))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    field(.address, validation) {
                        LabeledContent("Address") {
                            TextField("Address", text: $draft.address, prompt: Text("server.example.com"))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    field(.port, validation) {
                        LabeledContent("Port") {
                            TextField("Port", text: $draft.port, prompt: Text("22"))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    field(.user, validation) {
                        LabeledContent("User") {
                            TextField("User", text: $draft.user, prompt: Text("deploy"))
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section {
                    Picker("Sign in with", selection: $draft.auth) {
                        Text("SSH key").tag(HostAuthMethod.key)
                        Text("Password").tag(HostAuthMethod.password)
                    }
                    .pickerStyle(.segmented)
                    switch draft.auth {
                    case .key: keyPicker
                    case .password: passwordField(validation)
                    }
                } header: {
                    Text("Sign in")
                }
                Section {
                    field(.tags, validation) {
                        TextField("Tags", text: $draft.tags, prompt: Text("prod, web, eu-west"))
                            .accessibilityLabel("Tags")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Separate tags with commas.")
                }
                Section {
                    Toggle("Monitor this server", isOn: $draft.monitored)
                } footer: {
                    Text("Polls CPU, memory and disks every few seconds while AeroOps is open. Off, the server keeps its card without metrics.")
                }
                if let saveError {
                    Section { ValidationMessage(text: saveError) }
                }
                if !isNew {
                    Section {
                        Button("Delete Server", role: .destructive) { isConfirmingDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { SkyBackground() }
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save(validation) }
                        .disabled(!isNew && draft == baseline)
                }
            }
            .confirmationDialog("Delete \(baseline.trimmedName)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Server", role: .destructive, action: delete)
            } message: {
                Text("AeroOps forgets the server and its saved password. Nothing changes on the server.")
            }
        }
        .interactiveDismissDisabled(draft != baseline)
        .onAppear(perform: load)
    }

    // MARK: - Fields

    /// A field with its validation message underneath.
    private func field(
        _ field: HostDraft.Field,
        _ validation: HostDraft.Validation,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            if let message = visibleIssue(field, validation) {
                ValidationMessage(text: message)
            }
        }
    }

    /// Issues show for fields the user has edited, for every field of an existing host, and for
    /// all fields after a Save attempt. A fresh form starts clean.
    private func visibleIssue(_ field: HostDraft.Field, _ validation: HostDraft.Validation) -> String? {
        guard let message = validation.message(for: field) else { return nil }
        let edited = draft.text(for: field) != baseline.text(for: field)
        return revealAllIssues || !isNew || edited ? message : nil
    }

    @ViewBuilder
    private var keyPicker: some View {
        Picker("Key", selection: $draft.keyId) {
            Text("Any AeroOps key").tag(String?.none)
            ForEach(model.keys) { key in
                Text(key.name).tag(String?.some(key.id.uuidString))
            }
            if let keyId = draft.keyId, model.key(id: keyId) == nil {
                Text("Missing key").tag(String?.some(keyId))
            }
        }
        Text(model.keys.isEmpty
             ? "Create a key in the Keys tab and add its public key to the server’s authorized_keys."
             : "The key AeroOps signs in with. “Any” tries each of your keys.")
            .font(Aero.font(.footnote))
            .foregroundStyle(Aero.text.secondary)
    }

    @ViewBuilder
    private func passwordField(_ validation: HostDraft.Validation) -> some View {
        field(.password, validation) {
            SecureField("Password", text: $draft.password, prompt: Text(hasSavedPassword ? "Saved" : "Required"))
                .textContentType(.password)
        }
        Text(hasSavedPassword
             ? "Saved in the Keychain. Type a new one to replace it."
             : "Kept in this device’s Keychain and sent only to this server.")
            .font(Aero.font(.footnote))
            .foregroundStyle(Aero.text.secondary)
    }

    // MARK: - Actions

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        if case .edit(let id) = request, let host = model.host(id: id) {
            draft = HostDraft(host: host)
            hasSavedPassword = model.hasSavedPassword(for: id)
        }
        baseline = draft
    }

    private func save(_ validation: HostDraft.Validation) {
        guard validation.isValid else {
            revealAllIssues = true
            return
        }
        let host = draft.makeHost()
        let password = host.auth == .password && !draft.password.isEmpty ? draft.password : nil
        do {
            try model.save(host, password: password, folder: request.folder)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try model.deleteHost(id: draft.id)
            dismiss()
            onDelete()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview("Add") {
    HostEditorScreen(request: .new)
        .environment(MobileModel.preview())
}

#Preview("Edit") {
    let model = MobileModel.preview()
    HostEditorScreen(request: .edit(model.hosts[0].id))
        .environment(model)
}
