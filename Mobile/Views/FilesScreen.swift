import AeroCore
import AeroTheme
import SSHKit
import SwiftUI
import UniformTypeIdentifiers

/// One host's files over SFTP, from its home folder: open folders, go up, make, rename and
/// delete items, upload from the document picker, and download copies to share or save to
/// Files. The folder and the transfers stay when the screen closes.
struct FilesScreen: View {
    let id: RemoteHost.ID
    @Environment(MobileModel.self) private var model

    var body: some View {
        if let host = model.host(id: id) {
            if model.isPreview {
                FileBrowserView(host: host, browser: model.demoFileBrowser(for: host))
            } else {
                FileBrowserView(host: host, browser: model.fileBrowser(for: host))
            }
        } else {
            AeroEmptyState(systemImage: "server.rack", title: "Server removed", message: "This server is no longer in AeroOps.")
        }
    }
}

private struct FileBrowserView<Backend: FileTransferBackend>: View {
    let host: RemoteHost
    let browser: MobileFileBrowser<Backend>

    @State private var isImporting = false
    @State private var isCreatingFolder = false
    @State private var folderName = ""
    @State private var renaming: FileItem?
    @State private var newName = ""
    @State private var deleting: [FileItem] = []
    /// The file whose actions are shown (tapping a file).
    @State private var chosen: FileItem?

    private var pane: FilePaneModel<Backend> { browser.pane }

    var body: some View {
        @Bindable var pane = browser.pane
        List {
            Section {
                locationRow
            }
            .listRowBackground(Aero.glass.fill)
            if let error = pane.loadError {
                Section {
                    SessionIssueView(host: host, error: error) { pane.refresh() }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if !browser.queue.transfers.isEmpty {
                Section {
                    ForEach(browser.queue.transfers.reversed()) { transfer in
                        TransferRow(transfer: transfer, downloads: browser.downloads[transfer.id] ?? []) {
                            browser.queue.cancel(transfer)
                        }
                        .swipeActions {
                            if transfer.phase.isOver {
                                Button("Remove", systemImage: "xmark") { browser.remove(transfer) }
                            }
                        }
                    }
                } header: {
                    transfersHeader
                }
                .listRowBackground(Aero.glass.fill)
            }
            Section {
                items
            }
            .listRowBackground(Aero.glass.fill)
        }
        .scrollContentBackground(.hidden)
        .background { SkyBackground() }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Actions", systemImage: "ellipsis.circle") {
                    Button("New Folder…", systemImage: "folder.badge.plus") {
                        folderName = ""
                        isCreatingFolder = true
                    }
                    Button("Upload Files…", systemImage: "square.and.arrow.up.on.square") { isImporting = true }
                    Divider()
                    Button("Home Folder", systemImage: "house") { pane.goHome() }
                    Toggle("Show Hidden Files", systemImage: "eye", isOn: $pane.showsHidden)
                }
                .disabled(pane.directory == nil)
            }
        }
        .refreshable { pane.refresh() }
        .task { pane.start() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): browser.upload(urls)
            case .failure(let error): pane.actionError = error.localizedDescription
            }
        }
        .confirmationDialog(
            chosen?.name ?? "",
            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
            titleVisibility: .visible,
            presenting: chosen
        ) { item in
            itemActions(item)
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $folderName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                let name = folderName
                Task { await pane.createFolder(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In \(pane.displayPath)")
        }
        .alert(
            "Rename “\(renaming?.name ?? "")”",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { item in
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                let name = newName
                Task { await pane.rename(item, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let items = deleting
                Task { await pane.delete(items) }
            }
        } message: {
            Text("Folders are deleted with everything in them. This can’t be undone.")
        }
        .confirmationDialog(
            "Some items already exist",
            isPresented: Binding(get: { browser.conflict != nil }, set: { if !$0 { browser.conflict = nil } }),
            titleVisibility: .visible,
            presenting: browser.conflict
        ) { conflict in
            Button("Replace") { conflict.resolve(false) }
            Button("Skip Existing") { conflict.resolve(true) }
            Button("Cancel", role: .cancel) {}
        } message: { conflict in
            Text("\(conflict.names.formatted(.list(type: .and))) already \(conflict.names.count == 1 ? "exists" : "exist") in \(conflict.destination).")
        }
        .alert(
            "Couldn’t do that",
            isPresented: Binding(get: { pane.actionError != nil }, set: { if !$0 { pane.actionError = nil } }),
            presenting: pane.actionError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: Location

    private var locationRow: some View {
        HStack(spacing: 10) {
            Button("Up", systemImage: "arrow.up") { pane.goUp() }
                .labelStyle(.iconOnly)
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
                .disabled(!pane.canGoUp)
            Text(pane.directory == nil ? "Connecting to \(host.name)…" : pane.displayPath)
                .font(Aero.font(.callout, weight: .medium))
                .foregroundStyle(Aero.text.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if pane.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: Items

    @ViewBuilder
    private var items: some View {
        let visible = pane.visibleItems
        if pane.directory == nil {
            if pane.loadError == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting…")
                        .foregroundStyle(Aero.text.secondary)
                }
            }
        } else if visible.isEmpty {
            Text(pane.items.isEmpty ? "This folder is empty." : "Only hidden items here.")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
        } else {
            ForEach(visible) { item in
                Button {
                    open(item)
                } label: {
                    FileRow(item: item)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = [item] }
                    Button("Rename", systemImage: "pencil") { startRenaming(item) }
                }
                .swipeActions(edge: .leading) {
                    if !item.isFolder {
                        Button("Download", systemImage: "arrow.down.circle") { browser.download([item]) }
                            .tint(Aero.aqua)
                    }
                }
                .contextMenu {
                    itemActions(item)
                }
            }
        }
    }

    @ViewBuilder
    private func itemActions(_ item: FileItem) -> some View {
        Button("Download", systemImage: "arrow.down.circle") { browser.download([item]) }
        Button("Rename…", systemImage: "pencil") { startRenaming(item) }
        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = [item] }
    }

    private func open(_ item: FileItem) {
        Task {
            if await !pane.open(item) { chosen = item }
        }
    }

    private func startRenaming(_ item: FileItem) {
        newName = item.name
        renaming = item
    }

    private var deleteTitle: String {
        deleting.count == 1 ? "Delete “\(deleting[0].name)”?" : "Delete \(deleting.count) items?"
    }

    // MARK: Transfers

    private var transfersHeader: some View {
        HStack {
            Text("Transfers · \(browser.queue.summary)")
            Spacer()
            Button("Clear") { browser.clearFinished() }
                .font(Aero.font(.caption, weight: .semibold))
                .disabled(!browser.queue.transfers.contains { $0.phase.isOver })
        }
    }
}

private struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(Aero.font(.title3))
                .foregroundStyle(item.isFolder ? Aero.aqua : Aero.text.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Aero.font(.body))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isFolder {
                Image(systemName: "chevron.right")
                    .font(Aero.font(.footnote, weight: .semibold))
                    .foregroundStyle(Aero.text.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }

    private var details: String {
        let parts = item.isFolder ? [item.modifiedText] : [item.sizeText, item.modifiedText]
        return (parts + [item.permissionsText]).joined(separator: " · ")
    }
}

private struct TransferRow: View {
    let transfer: FileTransfer
    /// The downloaded copies, once a download finished.
    let downloads: [URL]
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.symbol)
                .font(Aero.font(.title3))
                .foregroundStyle(transfer.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title)
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("to \(transfer.destination)")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.phase.isActive {
                    Group {
                        if let fraction = transfer.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }
                    .tint(Aero.aqua)
                }
                Text(transfer.statusText)
                    .font(Aero.font(.caption))
                    .foregroundStyle(transfer.hasProblem ? Aero.coral : Aero.text.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if !transfer.phase.isOver {
                Button("Cancel", systemImage: "stop.circle", action: onCancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
            } else if !downloads.isEmpty {
                ShareLink(items: downloads) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.aqua)
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(transfer.details)
    }
}
