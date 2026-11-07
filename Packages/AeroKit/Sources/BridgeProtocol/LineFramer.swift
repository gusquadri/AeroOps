import Foundation

/// Splits a byte stream into `\n`-terminated lines with a maximum line size.
///
/// ```swift
/// var framer = LineFramer(maxLineBytes: BridgeLimits.maxRequestLineBytes)
/// for event in framer.append(chunk) {
///     switch event {
///     case .line(let data): handle(data)          // without the newline
///     case .oversized(let bytes): reject(bytes)   // the line was dropped
///     }
/// }
/// ```
///
/// An oversized line is reported once, as soon as it crosses the limit; the rest of it is
/// discarded up to the next newline, so memory stays bounded by `maxLineBytes`. Empty lines
/// (and a lone `\r` before the newline) are skipped.
public struct LineFramer: Sendable {
    /// Something found in the stream.
    public enum Event: Sendable, Hashable {
        /// A complete line, without its `\n` (and without a trailing `\r`).
        case line(Data)
        /// A line longer than the limit was dropped; `bytes` is how much had arrived when it was.
        case oversized(bytes: Int)
    }

    /// The limit, excluding the newline.
    public let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false

    /// Creates a framer. `maxLineBytes` must be positive.
    public init(maxLineBytes: Int) {
        precondition(maxLineBytes > 0, "maxLineBytes must be positive")
        self.maxLineBytes = maxLineBytes
    }

    /// Bytes buffered for the current, incomplete line.
    public var bufferedByteCount: Int { buffer.count }

    /// Feeds a chunk and returns the lines (and oversize reports) it completes, in order.
    public mutating func append(_ chunk: Data) -> [Event] {
        var events: [Event] = []
        let newline = UInt8(ascii: "\n")
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let end = chunk[start...].firstIndex(of: newline)
            let piece = chunk[start..<(end ?? chunk.endIndex)]
            if !discarding {
                if buffer.count + piece.count > maxLineBytes {
                    events.append(.oversized(bytes: buffer.count + piece.count))
                    buffer = Data()
                    discarding = true
                } else {
                    buffer.append(piece)
                }
            }
            guard let end else { break }
            if discarding {
                discarding = false
            } else {
                if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
                if !buffer.isEmpty { events.append(.line(buffer)) }
            }
            buffer = Data()
            start = chunk.index(after: end)
        }
        return events
    }

    /// Feeds raw bytes.
    public mutating func append(_ bytes: [UInt8]) -> [Event] {
        append(Data(bytes))
    }

    /// Ends the stream: returns a final line that had no newline, if any, and resets.
    public mutating func finish() -> Data? {
        defer {
            buffer = Data()
            discarding = false
        }
        guard !discarding, !buffer.isEmpty else { return nil }
        if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
        return buffer.isEmpty ? nil : buffer
    }
}
