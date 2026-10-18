import Foundation
import SSHKit

/// One row of a file pane.
struct FileItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case file
        case symlink
        case other
    }

    /// The name's raw bytes: unique within a folder, and exact for remote names that are not UTF-8.
    var id: Data { rawName }
    let rawName: Data
    /// The name for display (invalid UTF-8 shows as �).
    let name: String
    let kind: Kind
    /// Size of a regular file; `nil` for everything else.
    let size: Int64?
    let modified: Date?
    /// Permission bits (`0o7777`), when known.
    let mode: UInt32?

    var isHidden: Bool { name.hasPrefix(".") }
    var isFolder: Bool { kind == .folder }

    /// Sort keys for the table: folders have no size, unknown dates sort first.
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
}

extension FileItem {
    /// A remote entry from `readdir`, whose attributes describe the entry itself (a symbolic link
    /// is a link, not its target).
    init(_ entry: SFTPEntry) {
        let kind: Kind = switch entry.attributes.kind {
        case .directory: .folder
        case .regular: .file
        case .symlink: .symlink
        case .other, .unknown: .other
        }
        self.init(
            rawName: entry.name,
            name: entry.displayName,
            kind: kind,
            size: kind == .file ? entry.attributes.size.map { Int64(clamping: $0) } : nil,
            modified: entry.attributes.modificationDate,
            mode: entry.attributes.mode
        )
    }
}
