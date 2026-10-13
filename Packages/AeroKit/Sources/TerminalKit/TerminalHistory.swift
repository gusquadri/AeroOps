import Foundation

/// The most recent output of a terminal program, kept so a new libghostty surface can be
/// rebuilt from it.
///
/// Holds up to ``limit`` bytes. Older bytes are dropped but run through a
/// ``TerminalModeTracker`` first, and ``replay()`` puts its baseline in front of what is left,
/// so a terminal fed the replay ends up in the modes the full output would have left it in.
struct TerminalHistory: Sendable {
    static let defaultLimit = 2 << 20
    private static let chunkSize = 64 << 10

    let limit: Int
    private var chunks: [Data] = []
    private(set) var byteCount = 0
    /// Bytes were dropped: the replay starts somewhere in the middle of the output.
    private(set) var isTruncated = false
    private var tracker = TerminalModeTracker()

    init(limit: Int = Self.defaultLimit) {
        self.limit = limit
    }

    var isEmpty: Bool { byteCount == 0 }

    /// The full-screen program's alternate screen is active at the end of the output.
    var isAlternateScreenActive: Bool {
        var state = tracker
        for chunk in chunks {
            state.consume(chunk)
        }
        return state.alternateScreenMode != nil
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if let last = chunks.indices.last, chunks[last].count < Self.chunkSize {
            chunks[last].append(data)
        } else {
            chunks.append(data)
        }
        byteCount += data.count
        // Trim in steps of a chunk, not on every append.
        if byteCount > limit + Self.chunkSize {
            dropOldest(byteCount - limit)
        }
    }

    private mutating func dropOldest(_ amount: Int) {
        var remaining = amount
        while remaining > 0, let first = chunks.first {
            if first.count <= remaining {
                tracker.consume(first)
                chunks.removeFirst()
                remaining -= first.count
                byteCount -= first.count
            } else {
                let cut = first.index(first.startIndex, offsetBy: remaining)
                tracker.consume(first[..<cut])
                chunks[0] = first[cut...]
                byteCount -= remaining
                remaining = 0
            }
        }
        isTruncated = true
    }

    /// Bytes that rebuild the screen on a fresh terminal: the baseline of the dropped output,
    /// then the kept output from its first sequence boundary on.
    func replay() -> Data {
        var tracker = tracker
        var body = Data(capacity: byteCount)
        var aligned = false
        for chunk in chunks {
            guard !aligned else {
                body.append(chunk)
                continue
            }
            // The cut may have split an escape sequence or a UTF-8 character: skip its rest.
            var index = chunk.startIndex
            while index < chunk.endIndex, !tracker.isAtBoundary(next: chunk[index]) {
                tracker.consume(chunk[index])
                index = chunk.index(after: index)
            }
            if index < chunk.endIndex {
                aligned = true
                body.append(chunk[index...])
            }
        }
        return tracker.baseline + body
    }
}
