import AeroCore
import AeroTheme
import SwiftUI

extension View {
    /// Presents the "Import from ~/.ssh/config" sheet while `isPresented` is true.
    ///
    /// The sheet reads the config (never writes it), lets the user pick hosts and adds them
    /// through ``AppModel/addHost(_:)``. `onImport` gets the ids of the hosts added, in config
    /// order, after the sheet closes; it isn't called when the user cancels or adds nothing.
    ///
    /// ```swift
    /// .sshConfigImportSheet(isPresented: $isImporting) { ids in selection = ids.first }
    /// ```
    func sshConfigImportSheet(
        isPresented: Binding<Bool>,
        onImport: @escaping @MainActor ([RemoteHost.ID]) -> Void = { _ in }
    ) -> some View {
        sheet(isPresented: isPresented) {
            SSHConfigImportSheet(onImport: onImport)
        }
    }
}

/// Lists the hosts in `~/.ssh/config` with checkboxes and adds the checked ones.
///
/// - New hosts start checked. Hosts with the same address, port and user as one already in
///   AeroOps (or an earlier entry in the config) start unchecked, marked as duplicates.
/// - Hosts AeroOps can't reach the way ssh would (`ProxyJump`, `ProxyCommand`) or whose
///   values it refuses are shown disabled, with the reason.
/// - `IdentityFile` paths are only shown: the user imports the key in Settings › Keys.
struct SSHConfigImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importer: SSHConfigImportModel
    @State private var showsIssues: Bool
    private let height: CGFloat
    private let onImport: @MainActor ([RemoteHost.ID]) -> Void

    /// - Parameters:
    ///   - importer: the sheet's state; by default reads `~/.ssh/config` (or the DEBUG
    ///     `-AeroOpsSSHConfigFile`).
    ///   - height: the sheet's height; snapshot runs pass a tall one to show every host.
    ///   - showsIssues: whether the skipped-lines list starts open.
    ///   - onImport: called with the added hosts' ids after the sheet closes.
    init(
        importer: SSHConfigImportModel = SSHConfigImportModel(),
        height: CGFloat = 580,
        showsIssues: Bool = false,
        onImport: @escaping @MainActor ([RemoteHost.ID]) -> Void = { _ in }
    ) {
        _importer = State(initialValue: importer)
        _showsIssues = State(initialValue: showsIssues)
        self.height = height
        self.onImport = onImport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 640, height: height)
        .background { Aero.sky.gradient.ignoresSafeArea() }
        .task { await importer.load(existingHosts: model.hosts) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import from SSH Config")
                .font(Aero.font(.title2, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
            Text("Hosts found in \(SSHConfigImport.displaySafe(importer.displayPath)). AeroOps only reads this file; it never changes it and never opens key files.")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = importer.importError {
                ValidationMessage(text: error)
            } else if importer.phase == .loaded, importer.selectableCount > 0 {
                Text("\(importer.selectedCount) of \(importer.candidates.count) selected")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
            }
            Spacer(minLength: 12)
            Button("Cancel") { dismiss() }
                .buttonStyle(.aquaSecondary)
                .keyboardShortcut(.cancelAction)
            Button(addTitle, action: add)
                .buttonStyle(.aqua)
                .keyboardShortcut(.defaultAction)
                .disabled(importer.selectedCount == 0)
        }
        .padding(16)
    }

    private var addTitle: String {
        switch importer.selectedCount {
        case 0, 1: "Add Host"
        case let count: "Add \(count) Hosts"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch importer.phase {
        case .loading:
            ProgressView("Reading \(SSHConfigImport.displaySafe(importer.displayPath))…")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            switch error {
            case .notFound:
                AeroEmptyState(
                    systemImage: "doc.questionmark",
                    title: "No SSH config",
                    message: "There is no file at \(SSHConfigImport.displaySafe(importer.displayPath)). Add hosts with Add Host instead."
                )
            case .unreadable(_, let reason):
                AeroEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Can't read the SSH config",
                    message: "\(SSHConfigImport.displaySafe(importer.displayPath)) could not be read: \(SSHConfigImport.displaySafe(reason))."
                )
            }
        case .loaded:
            if importer.candidates.isEmpty {
                AeroEmptyState(
                    systemImage: "server.rack",
                    title: "No hosts to import",
                    message: "The config has no Host entries with a plain name. Patterns such as “Host *” only set defaults for other hosts."
                ) {
                    issuesSection
                }
            } else {
                hostList
            }
        }
    }

    private var hostList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                GlassSection("\(importer.candidates.count) \(importer.candidates.count == 1 ? "host" : "hosts")", systemImage: "list.bullet.rectangle") {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(importer.candidates.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { Divider().padding(.leading, 44) }
                            HostImportRow(
                                candidate: candidate,
                                localUser: importer.localUserName,
                                isSelected: Binding(
                                    get: { importer.isSelected(candidate) },
                                    set: { importer.setSelected($0, candidate) }
                                )
                            )
                        }
                    }
                } accessory: {
                    HStack(spacing: 6) {
                        Button("Select All New") { importer.selectAllNew() }
                            .help("Check every host that isn't already in AeroOps")
                        Button("Select None") { importer.selectNone() }
                    }
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
                    .disabled(importer.selectableCount == 0)
                }
                issuesSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var issuesSection: some View {
        if !importer.issues.isEmpty {
            AeroCard(padding: 12) {
                DisclosureGroup(isExpanded: $showsIssues) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(importer.issues.enumerated()), id: \.offset) { _, issue in
                            Text(SSHConfigImport.displaySafe(issue.description, limit: 200))
                                .font(Aero.font(.caption))
                                .foregroundStyle(Aero.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } label: {
                    Label(issuesTitle, systemImage: "exclamationmark.bubble")
                        .font(Aero.font(.callout, weight: .medium))
                        .foregroundStyle(Aero.text.primary)
                }
            }
        }
    }

    private var issuesTitle: String {
        let count = importer.issues.count
        let lines = count == 1 ? "1 line was" : "\(count) lines were"
        return "\(lines) skipped in \(importer.fileCount == 1 ? "the config" : "\(importer.fileCount) config files")"
    }

    private func add() {
        let added = importer.importSelected(into: model)
        guard importer.importError == nil else { return }
        dismiss()
        if !added.isEmpty { onImport(added) }
    }
}

/// One host in an import sheet: checkbox, name, `user@address:port`, a status chip and notes.
/// Shared by the ssh_config and Termius imports.
struct HostImportRow: View {
    /// A remark under the host, e.g. what else is imported with it.
    struct Note: Hashable {
        var text: String
        var systemImage: String
        var isWarning = false
    }

    let candidate: SSHConfigImportCandidate
    let localUser: String
    /// Where the hosts come from, as the notes name it: “the config”, “Termius”.
    var source = "the config"
    var extraNotes: [Note] = []
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: $isSelected) {
                Text("Import \(safe(candidate.host.name))")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!candidate.isSelectable)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(safe(candidate.host.name))
                        .font(Aero.font(.body, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if candidate.isRenamed {
                        Text("“\(safe(candidate.alias))” in \(source)")
                            .font(Aero.font(.caption))
                            .foregroundStyle(Aero.text.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    statusTag
                }
                Text(target)
                    .font(Aero.monospacedFont(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                notes
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if candidate.isSelectable { isSelected.toggle() }
        }
        .opacity(candidate.isSelectable ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }

    private var target: String {
        let host = candidate.host
        let address = host.address.contains(":") ? "[\(host.address)]" : host.address
        let port = host.port == RemoteHost.defaultPort ? "" : ":\(host.port)"
        return safe("\(host.user)@\(address)\(port)")
    }

    @ViewBuilder
    private var statusTag: some View {
        switch candidate.status {
        case .ready:
            AeroTag("New", tone: .healthy)
        case .alreadyAdded(let existing):
            AeroTag("Already added", systemImage: "checkmark.circle", tint: Aero.neutral)
                .help("Same address, port and user as “\(safe(existing))”")
        case .sameAsEarlier(let alias):
            AeroTag("Duplicate", systemImage: "square.on.square", tint: Aero.neutral)
                .help("Same address, port and user as “\(safe(alias))” above")
        case .unsupported:
            AeroTag("Can't import", tone: .error)
        }
    }

    @ViewBuilder
    private var notes: some View {
        switch candidate.status {
        case .unsupported(let reason):
            note(reason, systemImage: "nosign", tint: Aero.coral)
        case .alreadyAdded(let existing):
            note("Same address, port and user as “\(existing)”, already in AeroOps.", systemImage: "info.circle", tint: Aero.neutral)
        case .sameAsEarlier(let alias):
            note("Same address, port and user as “\(alias)” above.", systemImage: "info.circle", tint: Aero.neutral)
        case .ready:
            EmptyView()
        }
        if candidate.isSelectable {
            if candidate.usesLocalUser {
                note("No user in \(source), so ssh would log in as your account name “\(localUser)”.", systemImage: "person", tint: Aero.aquaDeep)
            }
            ForEach(extraNotes, id: \.self) { extra in
                note(extra.text, systemImage: extra.systemImage, tint: extra.isWarning ? Aero.sun : Aero.aquaDeep)
            }
            if !candidate.identityFiles.isEmpty {
                let files = candidate.identityFiles.map { "“\(safe($0, limit: 60))”" }.formatted(.list(type: .and))
                let summary = candidate.identityFiles.count == 1 ? "IdentityFile \(files) isn't" : "IdentityFiles \(files) aren't"
                note("\(summary) imported: add the key in Settings › Keys, then pick it for this host.",
                     systemImage: "key", tint: Aero.sun)
            }
        }
    }

    private func note(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(safe(text, limit: 400))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(Aero.font(.caption))
        .foregroundStyle(Aero.text.secondary)
    }

    private func safe(_ text: String, limit: Int = 120) -> String {
        SSHConfigImport.displaySafe(text, limit: limit)
    }
}

#Preview("Import sheet") {
    SSHConfigImportSheet()
        .environment(AppModel.preview())
}
