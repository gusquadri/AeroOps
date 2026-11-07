import Foundation

/// A folder of hosts on the dashboards, kept and synced by ``HostStore`` with the hosts.
///
/// Folders are one level deep: they hold hosts, never other folders. A host is in at most one
/// folder; ``HostStore/folderID(ofHost:)`` says which. Deleting a folder keeps its hosts.
public struct HostFolder: Identifiable, Codable, Sendable, Hashable {
    /// Stable identity.
    public var id: UUID
    /// Display name, trimmed, 1 to ``maxNameLength`` characters.
    public var name: String

    /// The longest folder name.
    public static let maxNameLength = 64

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// `name` trimmed, or `nil` when that leaves it empty or longer than ``maxNameLength``.
    public static func normalizedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else { return nil }
        return trimmed
    }
}
