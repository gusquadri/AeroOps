import Foundation

/// A program's progress report (OSC 9;4), shown on its tab.
public struct TerminalProgress: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case running
        case failed
        case indeterminate
        case paused
    }

    public var state: State
    /// 0...100; `nil` when the report has none (indeterminate, or an error or pause without one).
    public var percent: Int?

    public init(state: State, percent: Int?) {
        self.state = state
        self.percent = percent.map { min(100, max(0, $0)) }
    }
}

/// Something in a session the app may tell the user about (see
/// ``TerminalSessionManager/alertHandler``). Only live output raises them, never a replay.
public enum TerminalAlert: Sendable, Hashable {
    /// The program rang the bell.
    case bell
    /// The program asked for a desktop notification (OSC 9 or OSC 777). The texts come from
    /// the remote host: control characters are removed and they are cut to a few hundred
    /// characters, but they are otherwise untrusted.
    case notification(title: String, body: String)
    /// A command ended, where the remote shell marks commands (OSC 133).
    case commandFinished(exitCode: Int?, duration: Duration)
}

/// Where the viewport is while it is scrolled back from the bottom.
public struct TerminalScrollPosition: Sendable, Hashable {
    /// Rows of output below the viewport.
    public var rowsBelow: UInt64
    /// Rows in scrollback plus screen.
    public var totalRows: UInt64

    public init(rowsBelow: UInt64, totalRows: UInt64) {
        self.rowsBelow = rowsBelow
        self.totalRows = totalRows
    }

    /// `nil` at the bottom.
    init?(total: UInt64, offset: UInt64, visibleRows: UInt64) {
        let end = offset.addingReportingOverflow(visibleRows)
        guard !end.overflow, end.partialValue < total else { return nil }
        rowsBelow = total - end.partialValue
        totalRows = total
    }
}

extension TerminalAlert {
    static let maxTitleLength = 120
    static let maxBodyLength = 400

    /// A notification with displayable texts, `nil` when nothing is left of them.
    static func notification(sanitizingTitle title: String, body: String) -> TerminalAlert? {
        let title = sanitized(title, limit: maxTitleLength)
        let body = sanitized(body, limit: maxBodyLength)
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return .notification(title: title, body: body)
    }

    /// `text` without control or bidi-override characters, whitespace runs collapsed, cut to
    /// `limit` characters.
    static func sanitized(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            // Bidi embeddings, overrides and isolates can make a text read as another.
            if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        let cleaned = String(scalars)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit - 1)) + "…"
    }
}
