import AeroCore
import AeroTheme
import SwiftUI
import TermiusImport

extension View {
    /// Presents the "Import from Termius" sheet while `isPresented` is true.
    ///
    /// The sheet reads Termius's local data (never writes it), lets the user pick hosts and adds
    /// them with their keys and passwords. `onImport` gets the ids of the hosts added, in Termius
    /// order, after the sheet closes; it isn't called when the user cancels or adds nothing.
    func termiusImportSheet(
        isPresented: Binding<Bool>,
        onImport: @escaping @MainActor ([RemoteHost.ID]) -> Void = { _ in }
    ) -> some View {
        sheet(isPresented: isPresented) {
            TermiusImportSheet(onImport: onImport)
        }
    }
}

/// Lists the hosts saved in the Termius app on this Mac and adds the checked ones.
///
/// - It first explains that macOS will ask to allow access to Termius's Keychain item, which
///   holds the key Termius encrypts its data with, and only reads after the user continues.
/// - New hosts start checked; duplicates of hosts already in AeroOps start unchecked.
/// - Telnet hosts, host chains, proxies and hardware keys are shown disabled, with the reason.
/// - Keys are imported into the in-app agent and passwords saved to the Keychain on Add.
struct TermiusImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importer = TermiusImportModel()
    private let onImport: @MainActor ([RemoteHost.ID]) -> Void

    init(onImport: @escaping @MainActor ([RemoteHost.ID]) -> Void = { _ in }) {
        self.onImport = onImport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 640, height: 580)
        .background { Aero.sky.gradient.ignoresSafeArea() }
        .onDisappear { importer.forgetSecrets() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import from Termius")
                .font(Aero.font(.title2, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
            Text("Hosts saved in the Termius app on this Mac, with their keys and passwords. AeroOps only reads Termius’s data; it never changes it.")
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
            switch importer.phase {
            case .intro, .failed:
                Button(importer.phase == .intro ? "Continue" : "Try Again", action: load)
                    .buttonStyle(.aqua)
                    .keyboardShortcut(.defaultAction)
            case .loading, .loaded:
                Button(addTitle, action: add)
                    .buttonStyle(.aqua)
                    .keyboardShortcut(.defaultAction)
                    .disabled(importer.phase != .loaded || importer.selectedCount == 0 || importer.isImporting)
            }
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
        case .intro:
            AeroEmptyState(
                systemImage: "key.viewfinder",
                title: "Allow access to Termius’s key",
                message: "Termius encrypts its hosts with a key in your login Keychain. When you continue, macOS asks whether AeroOps may use the “Termius” Keychain item: choose Allow. Quit Termius first if it is open."
            )
        case .loading:
            ProgressView("Reading Termius’s hosts…")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            AeroEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Can't read Termius",
                message: SSHConfigImport.displaySafe(message, limit: 300)
            )
        case .loaded:
            if importer.candidates.isEmpty {
                AeroEmptyState(
                    systemImage: "server.rack",
                    title: "No hosts to import",
                    message: "Termius has no saved hosts on this Mac."
                )
            } else {
                hostList
            }
        }
    }

    private var hostList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GlassSection("\(importer.candidates.count) \(importer.candidates.count == 1 ? "host" : "hosts")", systemImage: "list.bullet.rectangle") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(importer.candidates.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { Divider().padding(.leading, 44) }
                            HostImportRow(
                                candidate: candidate.candidate,
                                localUser: importer.localUserName,
                                source: "Termius",
                                extraNotes: importer.notes(for: candidate),
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
                if importer.skippedRows > 0 {
                    Label("\(importer.skippedRows) Termius \(importer.skippedRows == 1 ? "entry" : "entries") couldn't be read and \(importer.skippedRows == 1 ? "is" : "are") not listed.",
                          systemImage: "exclamationmark.bubble")
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func load() {
        Task { await importer.load(existingHosts: model.hosts) }
    }

    private func add() {
        Task {
            let added = await importer.importSelected(into: model)
            guard importer.importError == nil else { return }
            dismiss()
            if !added.isEmpty { onImport(added) }
        }
    }
}

#Preview("Termius import") {
    TermiusImportSheet()
        .environment(AppModel.preview())
}
