import AeroCore
import AeroTheme
import SwiftUI

/// Add / edit form for every ``RemoteHost`` field, with inline validation and Test connection.
///
/// Used inline in Settings › Hosts and in the main window's ``HostEditorSheet``. The caller
/// decides what saving means through `onSave`; a thrown ``HostStoreError`` is shown in the footer.
/// Give the form `.id(host.id)` so its state resets when the edited host changes.
struct HostEditorForm: View {
    @Environment(AppModel.self) private var model

    let original: RemoteHost?
    let onSave: (RemoteHost) throws(HostStoreError) -> Void
    let onCancel: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var draft: HostDraft
    @State private var baseline: HostDraft
    @State private var revealAllIssues = false
    @State private var saveError: HostStoreError?
    @State private var test = TestState.idle
    @State private var testTask: Task<Void, Never>?

    private enum TestState: Equatable {
        case idle
        case running
        case finished(ConnectionTestResult)
    }

    /// - Parameters:
    ///   - original: The host to edit, or `nil` to create one.
    ///   - onSave: Persists the validated, normalised host.
    ///   - onCancel: Shows a Cancel button (sheets). Without it the form offers Revert instead.
    ///   - onDelete: Shows a Delete button.
    init(
        original: RemoteHost?,
        onSave: @escaping (RemoteHost) throws(HostStoreError) -> Void,
        onCancel: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        let draft = original.map(HostDraft.init(host:)) ?? HostDraft()
        _draft = State(initialValue: draft)
        _baseline = State(initialValue: draft)
    }

    private var isNew: Bool { original == nil }
    private var hasChanges: Bool { draft != baseline }

    var body: some View {
        let validation = draft.validate(otherHostNames: model.hosts.lazy.filter { $0.id != draft.id }.map(\.name))
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    field(.name, validation) {
                        TextField("Name", text: $draft.name, prompt: Text("web-01"))
                    }
                    field(.address, validation) {
                        TextField("Address", text: $draft.address, prompt: Text("10.0.0.12 or web-01.example.com"))
                    }
                    field(.port, validation) {
                        TextField("Port", text: $draft.port, prompt: Text("22"))
                    }
                    field(.user, validation) {
                        TextField("User", text: $draft.user, prompt: Text("deploy"))
                    }
                    keyPicker
                }
                Section("Organisation") {
                    field(.tags, validation, help: "Separate tags with commas.") {
                        TextField("Tags", text: $draft.tags, prompt: Text("prod, web, eu-west"))
                    }
                    if validation.message(for: .tags) == nil, !draft.parsedTags.isEmpty {
                        TagRow(tags: draft.parsedTags, limit: 8)
                    }
                }
                Section("Containers") {
                    field(.kubectlPrefix, validation, help: "Replaces “kubectl”, e.g. “sudo -n k3s kubectl” on k3s. Leave empty for plain kubectl.") {
                        TextField("kubectl prefix", text: $draft.kubectlPrefix, prompt: Text("kubectl"))
                    }
                    Toggle(isOn: $draft.dockerSudo) {
                        Text("Run docker with sudo -n")
                        Text("For users outside the docker group. Needs passwordless sudo for docker.")
                    }
                }
                Section("AI agents (MCP)") {
                    Picker("Access", selection: $draft.mcpTier) {
                        ForEach(MCPTier.allCases, id: \.self) { tier in
                            Text(tier.title).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(draft.mcpTier.explanation)
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                }
                Section("Connection test") {
                    testRow(validation)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .font(Aero.font(.body))

            Divider()
            footer(validation)
        }
        .onChange(of: connectionKey) { resetTest() }
        .onDisappear { testTask?.cancel() }
    }

    // MARK: - Rows

    /// A field with its validation message (or help text) underneath.
    private func field<Control: View>(
        _ field: HostDraft.Field,
        _ validation: HostDraft.Validation,
        help: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            control()
            if let message = visibleIssue(field, validation) {
                ValidationMessage(text: message)
            } else if let help {
                Text(help)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
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

    private var keyPicker: some View {
        Picker(selection: $draft.keyId) {
            Text("None").tag(String?.none)
            ForEach(model.availableKeys) { key in
                Text(key.name).tag(String?.some(key.id))
            }
            if let keyId = draft.keyId, !model.availableKeys.contains(where: { $0.id == keyId }) {
                Text("Unknown key (\(keyId))").tag(String?.some(keyId))
            }
        } label: {
            Text("Key")
            Text(model.availableKeys.isEmpty
                 ? "Keys you create or import in Settings › Keys will be offered here."
                 : "The key AeroOps’ agent offers to this host.")
        }
        .disabled(model.availableKeys.isEmpty && draft.keyId == nil)
    }

    @ViewBuilder
    private func testRow(_ validation: HostDraft.Validation) -> some View {
        HStack(spacing: 10) {
            Button("Test Connection", systemImage: "bolt.horizontal.circle") { runTest() }
                .buttonStyle(.aquaSecondary)
                .disabled(!validation.canTestConnection || test == .running)
            Group {
                switch test {
                case .idle:
                    Text(validation.canTestConnection
                         ? "Checks that AeroOps can sign in with these settings."
                         : "Enter a valid address, port and user first.")
                        .foregroundStyle(Aero.text.secondary)
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Testing…").foregroundStyle(Aero.text.secondary)
                case .finished(let result):
                    StatusOrb(tone: result.succeeded ? .healthy : .error, size: 10)
                    Text(result.message)
                }
            }
            .font(Aero.font(.callout))
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.default, value: test)
    }

    private func footer(_ validation: HostDraft.Validation) -> some View {
        HStack(spacing: 12) {
            if let onDelete {
                Button("Delete Host…", role: .destructive, action: onDelete)
                    .buttonStyle(.aquaSecondary)
            }
            if let saveError {
                ValidationMessage(text: saveError.localizedDescription)
            } else if revealAllIssues, !validation.isValid {
                ValidationMessage(text: "Fix the highlighted fields to save.")
            }
            Spacer(minLength: 12)
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.aquaSecondary)
                    .keyboardShortcut(.cancelAction)
            } else if hasChanges {
                Button("Revert", action: revert)
                    .buttonStyle(.aquaSecondary)
            }
            Button(isNew ? "Add Host" : "Save", action: { save(validation) })
                .buttonStyle(.aqua)
                .keyboardShortcut(.defaultAction)
                .disabled(!isNew && !hasChanges)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func save(_ validation: HostDraft.Validation) {
        guard validation.isValid else {
            revealAllIssues = true
            return
        }
        let host = draft.makeHost()
        do {
            try onSave(host)
            saveError = nil
            revealAllIssues = false
            draft = HostDraft(host: host)
            baseline = draft
        } catch {
            saveError = error
        }
    }

    private func revert() {
        draft = baseline
        revealAllIssues = false
        saveError = nil
    }

    /// Address, port, user and key: changing any of them invalidates a test result.
    private var connectionKey: [String] {
        [draft.address, draft.port, draft.user, draft.keyId ?? ""]
    }

    private func runTest() {
        testTask?.cancel()
        let host = draft.makeHost()
        let tester = model.connectionTester
        test = .running
        testTask = Task {
            let result = await tester.testConnection(to: host)
            guard !Task.isCancelled else { return }
            test = .finished(result)
        }
    }

    private func resetTest() {
        testTask?.cancel()
        testTask = nil
        test = .idle
    }
}

/// An inline validation or error message: coral warning icon and readable text.
struct ValidationMessage: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Aero.coral)
        }
        .font(Aero.font(.caption))
        .foregroundStyle(Aero.text.secondary)
    }
}

/// The main window's host editor: ``HostEditorForm`` in a sheet, for Add Host and the
/// sidebar's Edit… command.
struct HostEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: HostEditorRequest

    var body: some View {
        VStack(spacing: 0) {
            switch request {
            case .new:
                header("Add Host")
                HostEditorForm(original: nil, onSave: save, onCancel: { dismiss() })
            case .edit(let id):
                if let host = model.host(id: id) {
                    header("Edit \(host.name)")
                    HostEditorForm(original: host, onSave: save, onCancel: { dismiss() })
                } else {
                    AeroEmptyState(systemImage: "questionmark.circle", title: "Host not found", message: "This host was deleted.") {
                        Button("Close") { dismiss() }
                            .buttonStyle(.aquaSecondary)
                    }
                }
            }
        }
        .frame(width: 560, height: 700)
        .background { Aero.sky.gradient.ignoresSafeArea() }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Aero.font(.title2, weight: .semibold))
            .foregroundStyle(Aero.text.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
    }

    private func save(_ host: RemoteHost) throws(HostStoreError) {
        if model.host(id: host.id) == nil {
            try model.addHost(host)
        } else {
            try model.updateHost(host)
        }
        dismiss()
    }
}

#Preview("Editor · new host") {
    HostEditorSheet(request: .new)
        .environment(AppModel.preview())
}

#Preview("Editor · existing host") {
    HostEditorSheet(request: .edit(SampleData.hosts[2].id))
        .environment(AppModel.preview())
}
