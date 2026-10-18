import AeroTheme
import Foundation
import SwiftUI

// MARK: - Items

extension FileItem {
    var symbol: String {
        switch kind {
        case .folder: "folder.fill"
        case .file: "doc"
        case .symlink: "arrow.up.right.square"
        case .other: "questionmark.square.dashed"
        }
    }

    var sizeText: String {
        size.map { $0.formatted(.byteCount(style: .file)) } ?? MetricText.missing
    }

    /// Finder-style: today's items by time, older ones by date.
    var modifiedText: String {
        guard let modified else { return MetricText.missing }
        if Calendar.current.isDateInToday(modified) {
            return "Today, \(modified.formatted(date: .omitted, time: .shortened))"
        }
        return modified.formatted(date: .abbreviated, time: .omitted)
    }

    /// `ls -l` style, e.g. `drwxr-xr-x`, with set-id and sticky bits.
    var permissionsText: String {
        guard let mode else { return MetricText.missing }
        let type: Character = switch kind {
        case .folder: "d"
        case .symlink: "l"
        case .file: "-"
        case .other: "?"
        }
        var text = String(type)
        let triples: [(shift: UInt32, special: UInt32, set: Character, unset: Character)] = [
            (6, 0o4000, "s", "S"), (3, 0o2000, "s", "S"), (0, 0o1000, "t", "T"),
        ]
        for triple in triples {
            let bits = mode >> triple.shift & 0o7
            text.append(bits & 0o4 != 0 ? "r" : "-")
            text.append(bits & 0o2 != 0 ? "w" : "-")
            let executable = bits & 0o1 != 0
            if mode & triple.special != 0 {
                text.append(executable ? triple.set : triple.unset)
            } else {
                text.append(executable ? "x" : "-")
            }
        }
        return text
    }
}

// MARK: - Transfers

extension FileTransfer {
    var symbol: String {
        direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    var tint: Color {
        switch phase {
        case .waiting, .cancelled: Aero.neutral
        case .preparing, .copying: Aero.aqua
        case .finished: failures.isEmpty && skipped.isEmpty ? Aero.leaf : Aero.sun
        case .failed: Aero.coral
        }
    }

    /// Whether the status line reports a failure.
    var hasProblem: Bool {
        switch phase {
        case .failed: true
        case .finished: !failures.isEmpty
        default: false
        }
    }

    /// One line: what it is doing, or how it ended.
    var statusText: String {
        switch phase {
        case .waiting:
            return "Waiting"
        case .preparing:
            return "Connecting and listing folders…"
        case .copying:
            var parts = ["\(Self.bytes(copiedBytes)) of \(Self.bytes(totalBytes))"]
            if let speed { parts.append("\(Self.bytes(Int64(speed)))/s") }
            if let currentFile { parts.append((currentFile as NSString).lastPathComponent) }
            return parts.joined(separator: " · ")
        case .finished:
            var parts = [failures.isEmpty
                ? "Copied \(Self.files(fileCount)), \(Self.bytes(totalBytes))"
                : "\(failures.count) of \(Self.files(fileCount)) failed"]
            if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
            return parts.joined(separator: " · ")
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Every failure and skipped item (the first dozen of each).
    var details: String {
        var lines = failures.prefix(12).map { "\($0.path): \($0.message)" }
        if failures.count > 12 { lines.append("…and \(failures.count - 12) more failures") }
        if !skipped.isEmpty {
            lines.append("Skipped:")
            lines += skipped.prefix(12)
            if skipped.count > 12 { lines.append("…and \(skipped.count - 12) more") }
        }
        if case .failed(let message) = phase { lines.insert(message, at: 0) }
        return lines.isEmpty ? "\(title) to \(destination)" : lines.joined(separator: "\n")
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}
