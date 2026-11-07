import AeroCore
import AeroTheme
import CoreTransferable
import SwiftUI

extension HostLayoutItem: @retroactive Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { $0.token } importing: { try HostLayoutItem(token: $0) }
    }

    private static let hostPrefix = "app.aeroops.host:"
    private static let folderPrefix = "app.aeroops.folder:"

    var token: String {
        switch self {
        case .host(let id): Self.hostPrefix + id.uuidString
        case .folder(let id): Self.folderPrefix + id.uuidString
        }
    }

    init(token: String) throws {
        if let id = Self.id(in: token, after: Self.hostPrefix) {
            self = .host(id)
        } else if let id = Self.id(in: token, after: Self.folderPrefix) {
            self = .folder(id)
        } else {
            throw CocoaError(.coderReadCorrupt)
        }
    }

    private static func id(in token: String, after prefix: String) -> UUID? {
        guard token.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(token.dropFirst(prefix.count)))
    }
}

extension EnvironmentValues {
    /// Whether a dragged host or folder is over this view (``View/hostArranging(_:target:cornerRadius:isEnabled:onDrop:)``).
    @Entry var isHostDropTarget = false
}

extension View {
    /// Makes this view a drag source for `item` (when not `nil`) and a drop target for `target`,
    /// outlined in aqua while something is over it. Disabled, it is left as it is.
    @ViewBuilder
    func hostArranging(
        _ item: HostLayoutItem?,
        target: HostLayoutTarget,
        cornerRadius: CGFloat = Aero.radius.card,
        isEnabled: Bool = true,
        onDrop: @escaping (HostLayoutItem, HostLayoutTarget) -> Void
    ) -> some View {
        if isEnabled {
            modifier(HostArrangingModifier(item: item, target: target, cornerRadius: cornerRadius, onDrop: onDrop))
        } else {
            self
        }
    }

    /// Asks before deleting the folder in `candidate`; its hosts stay.
    func folderDeletionConfirmation(_ candidate: Binding<HostFolder?>, onDelete: @escaping (HostFolder) -> Void) -> some View {
        confirmationDialog(
            Text(candidate.wrappedValue.map { "Delete “\($0.name)”?" } ?? ""),
            isPresented: Binding(get: { candidate.wrappedValue != nil }, set: { if !$0 { candidate.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: candidate.wrappedValue
        ) { folder in
            Button("Delete Folder", role: .destructive) { onDelete(folder) }
        } message: { _ in
            Text("Its hosts move out of the folder. No host is deleted.")
        }
    }

    /// Shows ``FolderNameSheet`` for `request`; `onSave` creates or renames the folder.
    func folderNameSheet(
        _ request: Binding<FolderNameRequest?>,
        onSave: @escaping (FolderNameRequest, String) throws -> Void
    ) -> some View {
        sheet(item: request) { current in
            FolderNameSheet(request: current, onSave: { try onSave(current, $0) }, onClose: { request.wrappedValue = nil })
        }
    }
}

private struct HostArrangingModifier: ViewModifier {
    let item: HostLayoutItem?
    let target: HostLayoutTarget
    let cornerRadius: CGFloat
    let onDrop: (HostLayoutItem, HostLayoutTarget) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        dragSource(content)
            .environment(\.isHostDropTarget, isTargeted)
            .dropDestination(for: HostLayoutItem.self) { items, _ in
                accept(items.first)
            } isTargeted: {
                isTargeted = $0
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Aero.aqua, lineWidth: 3)
                    .opacity(isTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.snappy(duration: 0.15), value: isTargeted)
    }

    @ViewBuilder
    private func dragSource(_ content: Content) -> some View {
        if let item {
            content.draggable(item)
        } else {
            content
        }
    }

    private func accept(_ dropped: HostLayoutItem?) -> Bool {
        guard let dropped, dropped != item else { return false }
        onDrop(dropped, target)
        return true
    }
}

/// The dashboard's folders: a tile each, in order. Click one to open it; drop a host on one to
/// move it in, or a folder to move it there. Each tile's menu renames or deletes it.
struct HostFolderShelf: View {
    let folders: [HostFolder]
    let statuses: (HostFolder.ID) -> [HostStatus]
    let onOpen: (HostFolder) -> Void
    let onRename: (HostFolder) -> Void
    let onDelete: (HostFolder) -> Void
    let onDrop: (HostLayoutItem, HostLayoutTarget) -> Void

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(folders) { folder in
                Button { onOpen(folder) } label: {
                    HostFolderTile(folder: folder, statuses: statuses(folder.id))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") { onRename(folder) }
                    Button("Delete Folder…", systemImage: "trash", role: .destructive) { onDelete(folder) }
                }
                .hostArranging(.folder(folder.id), target: .item(.folder(folder.id)), onDrop: onDrop)
            }
        }
    }
}

/// A folder on the dashboard: the aqua folder gel (open while a host is dragged over it), its
/// name, how many hosts it holds and an orb per host's status.
struct HostFolderTile: View {
    let folder: HostFolder
    let statuses: [HostStatus]

    @Environment(\.isHostDropTarget) private var isTargeted

    var body: some View {
        AeroCard(padding: 14) {
            HStack(spacing: 12) {
                FolderGel(size: 44, isOpen: isTargeted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.name)
                        .font(Aero.font(.headline))
                        .foregroundStyle(Aero.text.primary)
                        .lineLimit(1)
                    Text(statuses.count == 1 ? "1 host" : "\(statuses.count) hosts")
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                    orbs
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Aero.font(.footnote, weight: .semibold))
                    .foregroundStyle(Aero.text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect(cornerRadius: Aero.radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the folder")
    }

    private var orbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(statuses.prefix(10).enumerated()), id: \.offset) { _, status in
                StatusOrb(tone: status.orbTone, size: 9)
            }
        }
        .frame(height: 10)
    }
}

/// What ``FolderNameSheet`` does: create a folder (moving a host into it) or rename one.
enum FolderNameRequest: Identifiable, Hashable {
    case new(moving: RemoteHost.ID?)
    case rename(HostFolder)

    var id: Self { self }
}

/// Asks for a folder's name, to create or rename it.
struct FolderNameSheet: View {
    let request: FolderNameRequest
    let onSave: (String) throws -> Void
    let onClose: () -> Void

    @State private var name: String
    @State private var error: String?
    @FocusState private var isFocused: Bool

    init(request: FolderNameRequest, onSave: @escaping (String) throws -> Void, onClose: @escaping () -> Void) {
        self.request = request
        self.onSave = onSave
        self.onClose = onClose
        if case .rename(let folder) = request {
            _name = State(initialValue: folder.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    var body: some View {
        content
            #if os(macOS)
            .frame(width: 400)
            #else
            .presentationDetents([.height(250)])
            #endif
            .background { Aero.sky.gradient.ignoresSafeArea() }
            .onAppear { isFocused = true }
    }

    private var isRename: Bool {
        if case .rename = request { true } else { false }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                FolderGel(size: 40)
                Text(isRename ? "Rename Folder" : "New Folder")
                    .font(Aero.font(.title2, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
            }
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
            if let error {
                ValidationMessage(text: error)
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.aquaSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Create", action: save)
                    .buttonStyle(.aqua)
                    .keyboardShortcut(.defaultAction)
                    .disabled(HostFolder.normalizedName(name) == nil)
            }
        }
        .padding(24)
    }

    private func save() {
        guard HostFolder.normalizedName(name) != nil else { return }
        do {
            try onSave(name)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A host's "Move to Folder" submenu: out of every folder, into one, or into a new one.
struct MoveToFolderMenu: View {
    let folders: [HostFolder]
    let current: HostFolder.ID?
    let onMove: (HostFolder.ID?) -> Void
    let onNewFolder: () -> Void

    var body: some View {
        Menu("Move to Folder", systemImage: "folder") {
            Button("No Folder") { onMove(nil) }
                .disabled(current == nil)
            Divider()
            ForEach(folders) { folder in
                Button(folder.name) { onMove(folder.id) }
                    .disabled(current == folder.id)
            }
            Divider()
            Button("New Folder…", systemImage: "folder.badge.plus", action: onNewFolder)
        }
    }
}
