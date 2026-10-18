import AeroCore
import AeroTheme
import AppKit
import SSHKit
import SwiftUI

/// Files tab: this Mac's files on the left, the selected host's over SFTP on the right, and the
/// transfer queue below. Copy with the Upload and Download buttons, the context menus, or by
/// dragging between the panes (or from Finder onto the host's pane).
struct FilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hosts.isEmpty {
            AeroEmptyState(
                systemImage: "folder",
                title: "Files",
                message: "Add a host to browse its files over SFTP beside this Mac's, and copy files and folders either way."
            ) {
                AddHostButton()
            }
        } else {
            FilesBrowser(files: model.fileService, host: model.selectedHost)
        }
    }
}

/// The two panes and the transfer queue.
private struct FilesBrowser: View {
    @Environment(AppModel.self) private var model
    @Bindable var files: FileService
    let host: RemoteHost?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                FilePaneView(pane: files.local, configuration: localConfiguration)
                remoteSide
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            if !files.transfers.isEmpty {
                TransferList(files: files)
            }
        }
        .padding(16)
        // Zero minimums, as in the Containers tab: content-dependent minimums loop NSSplitView.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .sheet(item: $files.trustRequest) { request in
            HostKeyTrustSheet(
                host: request.host,
                offered: request.offered,
                onTrust: { try await files.trust(request) },
                onCancel: { files.cancelTrust() }
            )
        }
        .confirmationDialog(
            conflictTitle,
            isPresented: Binding(get: { files.conflict != nil }, set: { if !$0 { files.conflict = nil } }),
            presenting: files.conflict
        ) { conflict in
            Button("Replace") { conflict.resolve(.replace) }
            Button("Skip") { conflict.resolve(.skip) }
            Button("Cancel", role: .cancel) {}
        } message: { conflict in
            Text("\(Self.list(conflict.names)) already \(conflict.names.count == 1 ? "exists" : "exist") in \(conflict.destination). Replace overwrites files with the same name and copies into existing folders; Skip leaves them as they are.")
        }
    }

    // MARK: Remote side

    @ViewBuilder private var remoteSide: some View {
        if let host {
            if files.canBrowse(host) {
                let pane = files.remotePane(for: host)
                FilePaneView(pane: pane, configuration: remoteConfiguration(host, pane: pane), hostID: host.id)
                    .id(host.id)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    PaneHeader(title: host.name, systemImage: "server.rack", subtitle: host.connectionSummary)
                    FileIssueCard(
                        issue: FileIssue(title: files.unavailableReason(host) ?? "This host can't be browsed yet.", editsHost: true),
                        hostID: host.id
                    )
                    Spacer(minLength: 0)
                }
            }
        } else {
            AeroEmptyState(
                systemImage: "sidebar.left",
                title: "Pick a host",
                message: "Choose a host in the sidebar to browse its files here."
            )
        }
    }

    private func remoteConfiguration(_ host: RemoteHost, pane: FilePaneModel<RemoteFileBackend>) -> FilePaneConfiguration<SFTPPath> {
        let localDirectory = files.local.directory
        return FilePaneConfiguration(
            title: host.name,
            systemImage: "server.rack",
            subtitle: host.connectionSummary,
            status: Self.status(pane.backend.session.status),
            transferTitle: "Download",
            transferSymbol: "arrow.down.circle",
            transferTarget: localDirectory.map { "This Mac (\(($0 as NSString).abbreviatingWithTildeInPath))" },
            transferUnavailable: "Open a folder on this Mac first.",
            transfer: { paths in
                guard let localDirectory else { return }
                files.download(paths, from: host, into: localDirectory)
            },
            dragPayload: { FileDragPayload(side: .remote, hostID: host.id, paths: $0.map(\.bytes)) },
            drop: { payload, folder in
                guard payload.side == .local, !payload.paths.isEmpty else { return false }
                Task { await files.upload(payload.localPaths, to: host, into: folder) }
                return true
            }
        )
    }

    private static func status(_ status: RemoteFileSession.Status) -> PaneStatus {
        switch status {
        case .idle: PaneStatus(tone: .neutral, text: "Not connected")
        case .connecting: PaneStatus(tone: .warning, text: "Connecting…")
        case .connected: PaneStatus(tone: .healthy, text: "SFTP")
        case .failed: PaneStatus(tone: .error, text: "Not connected")
        }
    }

    // MARK: Local side

    private var localConfiguration: FilePaneConfiguration<String> {
        let target = uploadTarget
        return FilePaneConfiguration(
            title: "This Mac",
            systemImage: "laptopcomputer",
            transferTitle: "Upload",
            transferSymbol: "arrow.up.circle",
            transferTarget: target.map { "\($0.host.name) (\($0.directory.string))" },
            transferUnavailable: host == nil
                ? "Pick a host in the sidebar to upload to it."
                : "Open a folder on \(host?.name ?? "the host") first.",
            transfer: { paths in
                guard let target else { return }
                Task { await files.upload(paths, to: target.host, into: target.directory) }
            },
            dragPayload: { FileDragPayload(side: .local, hostID: nil, paths: $0.map { Data($0.utf8) }) },
            drop: { payload, folder in
                guard payload.side == .remote, let hostID = payload.hostID, let host = model.host(id: hostID) else { return false }
                files.download(payload.paths.map(SFTPPath.init(bytes:)), from: host, into: folder)
                return true
            },
            openFile: { NSWorkspace.shared.open(URL(filePath: $0)) },
            revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting($0.map { URL(filePath: $0) }) }
        )
    }

    /// The remote pane's folder, when the selected host can be browsed and one is open.
    private var uploadTarget: (host: RemoteHost, directory: SFTPPath)? {
        guard let host, files.canBrowse(host), let directory = files.remotePane(for: host).directory else { return nil }
        return (host, directory)
    }

    // MARK: Conflicts

    private var conflictTitle: String {
        guard let names = files.conflict?.names else { return "" }
        return names.count == 1 ? "Replace “\(names[0])”?" : "Replace \(names.count) items?"
    }

    /// "“a”", "“a” and “b”", "“a”, “b” and 3 more".
    private static func list(_ names: [String]) -> String {
        let quoted = names.prefix(2).map { "“\($0)”" }
        switch names.count {
        case 1: return quoted[0]
        case 2: return "\(quoted[0]) and \(quoted[1])"
        default: return "\(quoted.joined(separator: ", ")) and \(names.count - 2) more"
        }
    }
}

// MARK: - Pane

/// A connection state in a pane header.
struct PaneStatus {
    var tone: OrbTone
    var text: String
}

/// What a pane does besides browsing: copy its selection to the other side, and accept drops.
struct FilePaneConfiguration<Path> {
    var title: String
    var systemImage: String
    var subtitle: String?
    var status: PaneStatus?
    /// "Upload" or "Download".
    var transferTitle: String
    var transferSymbol: String
    /// Where copies go, for button help and menus; `nil` disables copying (see `transferUnavailable`).
    var transferTarget: String?
    var transferUnavailable: String
    var transfer: ([Path]) -> Void
    var dragPayload: ([Path]) -> FileDragPayload
    /// Handles items dropped into `folder`; returns whether it took them.
    var drop: (FileDragPayload, Path) -> Bool
    /// Opens a file on double-click (local files: in their default app).
    var openFile: ((Path) -> Void)?
    var revealInFinder: (([Path]) -> Void)?
}

/// One side of the Files tab: header, navigation bar and the folder's table.
struct FilePaneView<Backend: FileBackend>: View {
    @Bindable var pane: FilePaneModel<Backend>
    let configuration: FilePaneConfiguration<Backend.Path>
    var hostID: RemoteHost.ID?

    @State private var pathText = ""
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var deleting: [FileItem]?
    @State private var isDropTarget = false
    @State private var tableWidth: CGFloat = 0
    @State private var columns = TableColumnCustomization<FileItem>()

    private enum Naming {
        case newFolder
        case rename(FileItem)

        var title: String {
            switch self {
            case .newFolder: "New Folder"
            case .rename(let item): "Rename “\(item.name)”"
            }
        }

        var action: String {
            switch self {
            case .newFolder: "Create"
            case .rename: "Rename"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PaneHeader(
                    title: configuration.title, systemImage: configuration.systemImage,
                    subtitle: configuration.subtitle, status: configuration.status
                )
                Spacer(minLength: 8)
                Button(configuration.transferTitle, systemImage: configuration.transferSymbol) {
                    transfer(pane.selectedItems)
                }
                .buttonStyle(.aquaSecondary)
                .disabled(pane.selection.isEmpty || configuration.transferTarget == nil)
                .help(configuration.transferTarget.map { "Copy the selected items to \($0)" } ?? configuration.transferUnavailable)
            }
            navigationBar
            if let error = pane.loadError {
                FileIssueCard(issue: FileIssue(error), hostID: hostID) { pane.refresh() }
            }
            tableCard
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .task(id: pane.epoch) { pane.start() }
        .onChange(of: pane.displayPath, initial: true) { _, path in pathText = path }
        .alert(
            naming?.title ?? "",
            isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
            presenting: naming
        ) { request in
            TextField("Name", text: $nameText)
            Button(request.action) { commit(request) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { items in
            Button("Delete", role: .destructive) { Task { await pane.delete(items) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Folders are deleted with everything in them. This can’t be undone.")
        }
        .alert(
            "Couldn’t finish that",
            isPresented: Binding(get: { pane.actionError != nil }, set: { if !$0 { pane.actionError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(pane.actionError ?? "")
        }
    }

    // MARK: Navigation bar

    private var navigationBar: some View {
        HStack(spacing: 8) {
            RowActionButton(title: "Back", systemImage: "chevron.backward", disabled: !pane.canGoBack) { pane.goBack() }
            RowActionButton(title: "Enclosing Folder", systemImage: "arrow.up", disabled: !pane.canGoUp) { pane.goUp() }
            RowActionButton(title: "Home Folder", systemImage: "house") { pane.goHome() }
            PathField(text: $pathText, isLoading: pane.isLoading) { pane.go(to: pathText) }
            RowActionButton(
                title: pane.showsHidden ? "Hide Hidden Files" : "Show Hidden Files",
                systemImage: pane.showsHidden ? "eye" : "eye.slash"
            ) {
                pane.showsHidden.toggle()
            }
            RowActionButton(title: "New Folder", systemImage: "folder.badge.plus", disabled: pane.directory == nil) {
                beginNaming(.newFolder)
            }
            RowActionButton(title: "Refresh", systemImage: "arrow.clockwise") { pane.refresh() }
        }
    }

    // MARK: Table

    private var tableCard: some View {
        let rows = pane.visibleItems
        let layout = FileColumn.layout(width: tableWidth)
        return AeroCard(padding: 0) {
            // Created once its width is known, so it starts out filled (WorkloadTableLayout).
            if tableWidth > 0 {
                table(rows, layout: layout)
            } else {
                Color.clear
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            tableWidth = width
            FileColumn.layout(width: width).apply(to: &columns)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous)
                .strokeBorder(Aero.aqua, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
                .allowsHitTesting(false)
        }
        .dropDestination(for: FileDragPayload.self) { payloads, _ in
            drop(payloads, into: nil)
        } isTargeted: { isDropTarget = $0 }
    }

    private func table(_ rows: [FileItem], layout: WorkloadTableLayout<FileColumn>) -> some View {
        Table(of: FileItem.self, selection: $pane.selection, sortOrder: $pane.sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.isFolder ? Aero.aqua : Aero.text.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.name)
            }
            .width(min: FileColumn.nameMinimum, ideal: layout.width(.name))
            .layoutColumn(FileColumn.name)
            TableColumn("Size", value: \.sortSize) { item in
                Text(item.sizeText)
                    .monospacedDigit()
                    .foregroundStyle(Aero.text.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(FileColumn.sizeWidth)
            .layoutColumn(FileColumn.size)
            TableColumn("Modified", value: \.sortDate) { item in
                Text(item.modifiedText)
                    .lineLimit(1)
                    .help(item.modified.map { $0.formatted(date: .complete, time: .standard) } ?? "")
                    .foregroundStyle(Aero.text.secondary)
            }
            .width(min: FileColumn.modifiedWidths.min, ideal: layout.width(.modified), max: FileColumn.modifiedWidths.max)
            .layoutColumn(FileColumn.modified)
            TableColumn("Permissions") { item in
                Text(item.permissionsText)
                    .font(Aero.monospacedFont(.caption))
                    .foregroundStyle(Aero.text.secondary)
            }
            .width(FileColumn.permissionsWidth)
            .layoutColumn(FileColumn.permissions)
        } rows: {
            ForEach(rows) { item in
                TableRow(item)
                    .draggable(payload(for: item))
                    .dropDestination(for: FileDragPayload.self) { payloads in
                        _ = drop(payloads, into: item)
                    }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            menu(for: pane.items(for: ids))
        } primaryAction: { ids in
            guard ids.count == 1, let item = pane.items(for: ids).first else { return }
            open(item)
        }
        .onDeleteCommand { requestDelete(pane.selectedItems) }
        .font(Aero.font(.callout))
        .foregroundStyle(Aero.text.primary)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if rows.isEmpty {
                if pane.isLoading {
                    ProgressView().controlSize(.small)
                } else if pane.directory != nil {
                    Text(pane.items.isEmpty ? "This folder is empty." : "Only hidden items here.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous))
    }

    @ViewBuilder private func menu(for items: [FileItem]) -> some View {
        if items.isEmpty {
            Button("New Folder…", systemImage: "folder.badge.plus") { beginNaming(.newFolder) }
                .disabled(pane.directory == nil)
            Button("Refresh", systemImage: "arrow.clockwise") { pane.refresh() }
            Toggle("Show Hidden Files", isOn: $pane.showsHidden)
        } else {
            if items.count == 1, let item = items.first, item.kind == .folder || item.kind == .symlink {
                Button("Open", systemImage: "arrow.forward.circle") { open(item) }
            }
            Button(transferMenuTitle, systemImage: configuration.transferSymbol) { transfer(items) }
                .disabled(configuration.transferTarget == nil)
            if let reveal = configuration.revealInFinder {
                Button("Show in Finder", systemImage: "folder") { reveal(items.compactMap(pane.path(of:))) }
            }
            Divider()
            if items.count == 1, let item = items.first {
                Button("Rename…", systemImage: "pencil") { beginNaming(.rename(item)) }
            }
            Button(items.count == 1 ? "Copy Path" : "Copy Paths", systemImage: "doc.on.doc") { copyPaths(items) }
            Divider()
            if pane.backend.deletesToTrash {
                Button("Move to Trash", systemImage: "trash", role: .destructive) { requestDelete(items) }
            } else {
                Button("Delete…", systemImage: "trash", role: .destructive) { requestDelete(items) }
            }
        }
    }

    private var transferMenuTitle: String {
        guard let target = configuration.transferTarget else { return configuration.transferTitle }
        return "\(configuration.transferTitle) to \(target)"
    }

    private var deleteTitle: String {
        guard let deleting else { return "" }
        return deleting.count == 1 ? "Delete “\(deleting[0].name)”?" : "Delete \(deleting.count) items?"
    }

    // MARK: Actions

    private func open(_ item: FileItem) {
        Task {
            guard !(await pane.open(item)), let openFile = configuration.openFile, let path = pane.path(of: item) else { return }
            openFile(path)
        }
    }

    private func transfer(_ items: [FileItem]) {
        let paths = items.compactMap(pane.path(of:))
        guard !paths.isEmpty, configuration.transferTarget != nil else { return }
        configuration.transfer(paths)
    }

    private func requestDelete(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if pane.backend.deletesToTrash {
            Task { await pane.delete(items) }
        } else {
            deleting = items
        }
    }

    private func beginNaming(_ request: Naming) {
        switch request {
        case .newFolder: nameText = "untitled folder"
        case .rename(let item): nameText = item.name
        }
        naming = request
    }

    private func commit(_ request: Naming) {
        let name = nameText
        Task {
            switch request {
            case .newFolder: await pane.createFolder(named: name)
            case .rename(let item): await pane.rename(item, to: name)
            }
        }
    }

    private func copyPaths(_ items: [FileItem]) {
        let text = items.compactMap(pane.path(of:)).map(pane.backend.displayString).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Drag and drop

    /// A dragged row carries the whole selection when it is part of it.
    private func payload(for item: FileItem) -> FileDragPayload {
        let items = pane.selection.contains(item.id) ? pane.selectedItems : [item]
        return configuration.dragPayload(items.compactMap(pane.path(of:)))
    }

    /// Drops onto a folder row go into that folder; anywhere else into the shown folder.
    private func drop(_ payloads: [FileDragPayload], into item: FileItem?) -> Bool {
        guard let first = payloads.first, var folder = pane.directory else { return false }
        if let item, item.isFolder, let path = pane.path(of: item) { folder = path }
        // A multi-row drag may deliver one payload per selected row, each carrying the selection.
        var seen = Set<Data>()
        var merged = first
        merged.paths = payloads
            .filter { $0.side == first.side && $0.hostID == first.hostID }
            .flatMap(\.paths)
            .filter { seen.insert($0).inserted }
        return configuration.drop(merged, folder)
    }
}

/// A pane table's columns. In a narrow pane Permissions, then Modified, then Size give way
/// rather than the table scrolling sideways.
enum FileColumn: String, CaseIterable {
    case name, size, modified, permissions

    static let nameMinimum: CGFloat = 100
    static let nameComfort: CGFloat = 160
    /// "123.4 MB".
    static let sizeWidth: CGFloat = 70
    /// "Today, 12:40" and "30 Sep 2026".
    static let modifiedWidths = (min: CGFloat(84), ideal: CGFloat(110), max: CGFloat(170))
    /// `drwxr-xr-x` and the header.
    static let permissionsWidth: CGFloat = 84

    static func layout(width: CGFloat) -> WorkloadTableLayout<FileColumn> {
        WorkloadTableLayout(
            width: width,
            columns: [
                .init(.name, width: nameMinimum),
                .init(.size, width: sizeWidth),
                .init(.modified, min: modifiedWidths.min, ideal: modifiedWidths.ideal),
                .init(.permissions, width: permissionsWidth),
            ],
            name: .name,
            nameComfort: nameComfort,
            dropOrder: [.permissions, .modified, .size]
        )
    }
}

/// Title, symbol and connection line of a pane.
private struct PaneHeader: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    var status: PaneStatus?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(Aero.font(.title3))
                .foregroundStyle(Aero.aqua)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Aero.font(.headline, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                if subtitle != nil || status != nil {
                    HStack(spacing: 5) {
                        if let status {
                            StatusOrb(tone: status.tone, size: 8)
                            Text(status.text)
                        }
                        if let subtitle {
                            Text(subtitle)
                        }
                    }
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                }
            }
        }
    }
}

/// The editable path of a pane: type a folder and press Return to go there.
private struct PathField: View {
    @Binding var text: String
    var isLoading: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(Aero.text.secondary)
                .accessibilityHidden(true)
            TextField("Path", text: $text)
                .textFieldStyle(.plain)
                .font(Aero.monospacedFont(.callout))
                .foregroundStyle(Aero.text.primary)
                .onSubmit(onSubmit)
                .frame(minWidth: 40)
            if isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .aeroGlass(in: Capsule(), shadow: Aero.shadow.control)
    }
}

// MARK: - Problems

/// A listing or connection problem, with the Containers tab's hints for ssh errors.
struct FileIssue {
    var title: String
    var hint: String?
    /// Whether the host editor is the place to fix it.
    var editsHost = false

    init(title: String, hint: String? = nil, editsHost: Bool = false) {
        self.title = title
        self.hint = hint
        self.editsHost = editsHost
    }

    init(_ error: any Error) {
        switch error {
        case let error as FileBrowserError:
            self.init(title: error.localizedDescription)
            switch error {
            case .unavailable:
                editsHost = true
            case .untrustedHost:
                hint = "Compare the fingerprints in the sheet before trusting the host. Retry shows the sheet again."
            case .refused:
                hint = "Review the new key in the host editor before connecting again."
                editsHost = true
            case .notAFolder, .exists, .invalidName:
                break
            }
        case let error as SFTPError:
            if case .disconnected(let sshError) = error {
                self.init(sshError)
            } else {
                self.init(title: error.localizedDescription)
            }
        case let error as SSHError:
            let issue = WorkloadIssue.from(error)
            self.init(title: issue?.title ?? error.localizedDescription, hint: issue?.hint, editsHost: issue?.offersHostEditor ?? false)
            if case .other(let message) = error, message.localizedCaseInsensitiveContains("subsystem") {
                hint = "The server may not offer SFTP: check the Subsystem sftp line in its sshd_config."
            }
        default:
            self.init(title: error.localizedDescription)
        }
    }
}

struct FileIssueCard: View {
    @Environment(AppModel.self) private var model
    let issue: FileIssue
    let hostID: RemoteHost.ID?
    var retry: (() -> Void)?

    var body: some View {
        AeroCard(padding: 12) {
            HStack(alignment: .top, spacing: 10) {
                StatusOrb(tone: .warning, size: 12)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    // No vertical fixedSize (see WorkloadIssueCard): it loops the split view.
                    Text(issue.title)
                        .font(Aero.font(.callout, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                        .textSelection(.enabled)
                    if let hint = issue.hint {
                        Text(hint)
                            .font(Aero.font(.caption))
                            .foregroundStyle(Aero.text.secondary)
                            .textSelection(.enabled)
                    }
                    if retry != nil || (issue.editsHost && hostID != nil) {
                        HStack(spacing: 8) {
                            if let retry {
                                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                            }
                            if issue.editsHost, let hostID {
                                Button("Edit Host…", systemImage: "slider.horizontal.3") { model.requestEdit(hostID) }
                            }
                        }
                        .buttonStyle(.aquaSecondary)
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Transfers

/// The transfer queue under the panes, newest first.
private struct TransferList: View {
    let files: FileService

    static let rowHeight: CGFloat = 54
    private static let visibleRows = 3

    var body: some View {
        let transfers = files.transfers.reversed()
        AeroCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Transfers")
                        .font(Aero.font(.headline, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                    Text(summary)
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                    Spacer(minLength: 8)
                    Button("Clear Finished") { files.clearFinished() }
                        .buttonStyle(.aquaSecondary)
                        .controlSize(.small)
                        .disabled(!files.transfers.contains { $0.phase.isOver })
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transfers) { transfer in
                            TransferRow(transfer: transfer, files: files)
                            if transfer.id != transfers.last?.id {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
                // A height from the row count, not the content: the split view loops on the latter.
                .frame(height: Self.rowHeight * CGFloat(min(files.transfers.count, Self.visibleRows)))
            }
        }
    }

    private var summary: String {
        files.queue.summary
    }
}

private struct TransferRow: View {
    let transfer: FileTransfer
    let files: FileService

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.symbol)
                .font(Aero.font(.title3))
                .foregroundStyle(transfer.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transfer.title)
                        .font(Aero.font(.callout, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                    Text("to \(transfer.destination)")
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                if transfer.phase.isActive {
                    Group {
                        if let fraction = transfer.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }
                    .controlSize(.small)
                    .tint(Aero.aqua)
                }
                Text(transfer.statusText)
                    .font(Aero.font(.caption))
                    .foregroundStyle(transfer.hasProblem ? Aero.coral : Aero.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if transfer.phase.isOver {
                RowActionButton(title: "Remove", systemImage: "xmark") { files.remove(transfer) }
            } else {
                RowActionButton(title: "Cancel", systemImage: "stop.circle") { files.cancel(transfer) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: TransferList.rowHeight)
        .help(transfer.details)
    }
}
