import AeroCore
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Items dragged out of a Files pane (declared in Info.plist; only AeroOps reads it).
    static let aeroOpsFileSelection = UTType(exportedAs: "app.aeroops.file-selection")
}

/// What a Files pane drags: the selected items of one side. Finder's file URLs import as a
/// local selection, so files dropped from Finder onto a host's pane upload.
struct FileDragPayload: Codable, Transferable {
    enum Side: String, Codable {
        case local
        case remote
    }

    var side: Side
    /// The host of a remote selection.
    var hostID: RemoteHost.ID?
    /// Absolute paths: UTF-8 for local items, the raw bytes for remote ones.
    var paths: [Data]

    var localPaths: [String] {
        side == .local ? paths.map { String(decoding: $0, as: UTF8.self) } : []
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .aeroOpsFileSelection)
        ProxyRepresentation(importing: { (url: URL) in
            var path = url.standardizedFileURL.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return FileDragPayload(side: .local, hostID: nil, paths: [Data(path.utf8)])
        })
    }
}
