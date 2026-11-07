import Foundation

/// A host or a folder being dragged on a dashboard.
public enum HostLayoutItem: Hashable, Sendable {
    case host(RemoteHost.ID)
    case folder(HostFolder.ID)
}

/// Where a dragged ``HostLayoutItem`` is dropped: onto a host or folder, or after the last item
/// of a folder (`nil`: the top level).
public enum HostLayoutTarget: Hashable, Sendable {
    case item(HostLayoutItem)
    case end(folder: HostFolder.ID?)
}

extension HostStore {
    /// Applies a drop: a host dropped on a host takes its place (in its folder), on a folder goes
    /// last in it, and on an end goes last there; a folder dropped on a folder takes its place,
    /// and on the top level's end goes last. Returns `false` for a drop that means nothing, such
    /// as a folder onto a host.
    @discardableResult
    public func drop(_ item: HostLayoutItem, on target: HostLayoutTarget) throws(HostStoreError) -> Bool {
        switch item {
        case .host(let id):
            try dropHost(id, on: target)
            return true
        case .folder(let id):
            return try dropFolder(id, on: target)
        }
    }

    private func dropHost(_ id: RemoteHost.ID, on target: HostLayoutTarget) throws(HostStoreError) {
        switch target {
        case .item(.host(let other)): try moveHost(id, onto: other)
        case .item(.folder(let folder)): try moveHost(id, toFolder: folder)
        case .end(let folder): try moveHost(id, toFolder: folder)
        }
    }

    private func dropFolder(_ id: HostFolder.ID, on target: HostLayoutTarget) throws(HostStoreError) -> Bool {
        switch target {
        case .item(.folder(let other)): try moveFolder(id, onto: other)
        case .end(nil): try moveFolder(id, before: nil)
        case .item(.host), .end(.some): return false
        }
        return true
    }
}
