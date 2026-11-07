import Foundation

/// Text after a cap was applied.
public struct CappedText: Sendable, Hashable {
    /// The kept text.
    public var text: String
    /// `true` when something was cut off.
    public var truncated: Bool

    /// Creates a capped text.
    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }
}

/// Clean-up for remote log text before it is shown or returned over MCP.
///
/// ```swift
/// let capped = LogText.prepare(stdout)   // strip ANSI, keep the last 2,000 lines and 1 MiB
/// if capped.truncated { showTruncatedBanner() }
/// ```
public enum LogText {
    /// The most lines a log view or MCP response holds (``LogRequest/maxTail``).
    public static let maxLines = LogRequest.maxTail
    /// The default byte cap: 1 MiB.
    public static let defaultMaxBytes = 1_048_576

    /// Which end of the text a cap keeps.
    public enum Keep: Sendable, Hashable {
        /// Keep the start (e.g. `describe` output).
        case head
        /// Keep the end (logs: the newest lines).
        case tail
    }

    /// Removes terminal escape sequences and control characters:
    /// - CSI (`ESC [` or 0x9B, parameters, final byte), e.g. colours and cursor movement;
    /// - OSC, DCS, SOS, PM and APC strings (`ESC ]`, `ESC P`, `ESC X`, `ESC ^`, `ESC _` or their
    ///   C1 forms), ended by BEL, `ESC \`, 0x9C or another ESC; never past a newline;
    /// - other escapes (`ESC (B`, `ESC 7`, `ESC =`), and a lone ESC;
    /// - other C0/C1 controls and DEL, except tab and newline.
    ///
    /// `\r\n` and a lone `\r` become `\n`.
    public static func stripANSI(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsWork) else { return text }

        var output = String.UnicodeScalarView()
        var state = EscapeState.text
        var afterCR = false

        for scalar in text.unicodeScalars {
            var pending: Unicode.Scalar? = scalar
            while let current = pending {
                pending = nil
                let value = current.value
                switch state {
                case .text:
                    switch value {
                    case 0x1B: state = .escape
                    case 0x9B: state = .csi
                    case 0x90, 0x98, 0x9D, 0x9E, 0x9F: state = .string
                    case 0x0D:
                        if !afterCR { output.append("\n") }
                        afterCR = true
                    case 0x0A:
                        if afterCR { afterCR = false } else { output.append("\n") }
                    case 0x09:
                        output.append(current)
                        afterCR = false
                    case 0x00..<0x20, 0x7F, 0x80..<0xA0:
                        break
                    default:
                        output.append(current)
                        afterCR = false
                    }
                case .escape:
                    switch value {
                    case 0x5B: state = .csi
                    case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .string
                    case 0x20...0x2F: state = .intermediates
                    case 0x30...0x7E: state = .text
                    case 0x1B: break
                    default:
                        state = .text
                        pending = current
                    }
                case .csi:
                    switch value {
                    case 0x20...0x3F: break
                    case 0x40...0x7E: state = .text
                    case 0x1B: state = .escape
                    default:
                        state = .text
                        pending = current
                    }
                case .intermediates:
                    switch value {
                    case 0x20...0x2F: break
                    case 0x30...0x7E: state = .text
                    case 0x1B: state = .escape
                    default:
                        state = .text
                        pending = current
                    }
                case .string:
                    switch value {
                    case 0x07, 0x9C: state = .text
                    case 0x1B: state = .stringEscape
                    case 0x0A, 0x0D:
                        state = .text
                        pending = current
                    default: break
                    }
                case .stringEscape:
                    if value == 0x5C {
                        state = .text
                    } else {
                        state = .escape
                        pending = current
                    }
                }
            }
        }
        return String(output)
    }

    /// Keeps at most `maxLines` lines (a final line without `\n` counts). Returns the text unchanged
    /// when it is within the cap.
    public static func capLines(_ text: String, maxLines: Int = LogText.maxLines, keep: Keep = .tail) -> CappedText {
        let limit = max(0, maxLines)
        let bytes = Array(text.utf8)
        let newline = UInt8(ascii: "\n")
        let endsWithNewline = bytes.last == newline
        let lineCount = bytes.count(where: { $0 == newline }) + (bytes.isEmpty || endsWithNewline ? 0 : 1)
        guard lineCount > limit else { return CappedText(text: text, truncated: false) }
        guard limit > 0 else { return CappedText(text: "", truncated: true) }

        switch keep {
        case .head:
            var seen = 0
            for index in bytes.indices where bytes[index] == newline {
                seen += 1
                if seen == limit { return CappedText(text: string(bytes[...index]), truncated: true) }
            }
        case .tail:
            var seen = 0
            let scanEnd = endsWithNewline ? bytes.count - 1 : bytes.count
            for index in stride(from: scanEnd - 1, through: 0, by: -1) where bytes[index] == newline {
                seen += 1
                if seen == limit { return CappedText(text: string(bytes[(index + 1)...]), truncated: true) }
            }
        }
        return CappedText(text: text, truncated: false)
    }

    /// Keeps at most `maxBytes` UTF-8 bytes, never splitting a character. Prefers to cut at a line
    /// boundary so no partial line is shown. Returns the text unchanged when it is within the cap.
    public static func capBytes(_ text: String, maxBytes: Int = LogText.defaultMaxBytes, keep: Keep = .tail) -> CappedText {
        let limit = max(0, maxBytes)
        guard text.utf8.count > limit else { return CappedText(text: text, truncated: false) }
        let bytes = Array(text.utf8)
        let newline = UInt8(ascii: "\n")
        func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }

        switch keep {
        case .head:
            var end = limit
            while end > 0, isContinuation(bytes[end]) { end -= 1 }
            if let lastNewline = bytes[..<end].lastIndex(of: newline) { end = lastNewline + 1 }
            return CappedText(text: string(bytes[..<end]), truncated: true)
        case .tail:
            var start = bytes.count - limit
            while start < bytes.count, isContinuation(bytes[start]) { start += 1 }
            if start > 0, bytes[start - 1] != newline,
               let firstNewline = bytes[start...].firstIndex(of: newline), firstNewline < bytes.count - 1 {
                start = firstNewline + 1
            }
            return CappedText(text: string(bytes[start...]), truncated: true)
        }
    }

    /// Strips escapes, then keeps the last `maxLines` lines and `maxBytes` bytes.
    public static func prepare(_ text: String, maxLines: Int = LogText.maxLines,
                               maxBytes: Int = LogText.defaultMaxBytes) -> CappedText {
        let lines = capLines(stripANSI(text), maxLines: maxLines, keep: .tail)
        let bytes = capBytes(lines.text, maxBytes: maxBytes, keep: .tail)
        return CappedText(text: bytes.text, truncated: lines.truncated || bytes.truncated)
    }

    private enum EscapeState {
        case text, escape, csi, intermediates, string, stringEscape
    }

    private static func needsWork(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (value < 0x20 && value != 0x09 && value != 0x0A) || (0x7F...0x9F).contains(value)
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
