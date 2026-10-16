import Foundation

/// The most recent output of a terminal program, kept so a new libghostty surface can be
/// rebuilt from it.
///
/// Output on the main screen and a full-screen program's output on the alternate screen are
/// kept apart. While a program is on the alternate screen (mode 1049) its output goes to a log
/// of its own, so however much it draws, it never pushes the shell's output out. Once it leaves,
/// that log is dropped for a short stand-in (``TerminalModeTracker/alternateScreenStandIn(since:)``):
/// nothing it drew shows on the main screen any more, only the modes it left behind.
///
/// Each log keeps up to its limit of bytes, plus a graphics allowance for kitty graphics
/// commands on top, so a few images do not push the text out (and the replay shows them again).
/// Older bytes are dropped but run through a ``TerminalModeTracker`` first, and ``replay()``
/// puts what they changed in front of what is left, so a terminal fed the replay ends up in the
/// modes the full output would have left it in.
struct TerminalHistory: Sendable {
    /// About 40 000 lines of 100 bytes, beyond libghostty's default scrollback (10 MB of cells,
    /// some 10 000 lines at 120 columns), at about 1 MB once compressed.
    static let defaultLimit = 4 << 20
    /// A full-screen program repaints after a replay that dropped some of its output, so only
    /// its latest frames are worth keeping.
    static let defaultAlternateLimit = 1 << 20
    static let defaultGraphicsAllowance = 8 << 20

    let limit: Int
    let alternateLimit: Int
    let graphicsAllowance: Int
    /// Output on the main screen, with each stay on the alternate screen (mode 1049) that
    /// ended replaced by its stand-in.
    private var main: TerminalOutputLog
    /// The current stay on the alternate screen, from right after the program entered it with
    /// mode 1049.
    private var alternate: AlternateScreenOutput?
    /// The state after all output. Collects the output's events.
    private var tail = TerminalModeTracker()

    private struct AlternateScreenOutput: Sendable {
        /// The state right after entering.
        let entry: TerminalModeTracker
        var log: TerminalOutputLog
    }

    init(
        limit: Int = Self.defaultLimit,
        alternateLimit: Int = Self.defaultAlternateLimit,
        graphicsAllowance: Int = Self.defaultGraphicsAllowance
    ) {
        self.limit = limit
        self.alternateLimit = alternateLimit
        self.graphicsAllowance = graphicsAllowance
        main = TerminalOutputLog(limit: limit, graphicsAllowance: graphicsAllowance, start: TerminalModeTracker())
        tail.collectsEvents = true
    }

    var isEmpty: Bool { byteCount == 0 }

    /// Kept bytes.
    var byteCount: Int {
        main.byteCount + (alternate?.log.byteCount ?? 0)
    }

    /// Memory the kept bytes take, compressed.
    var storedByteCount: Int {
        main.storedByteCount + (alternate?.log.storedByteCount ?? 0)
    }

    /// Bytes were dropped: the replay starts somewhere in the middle of the output.
    var isTruncated: Bool {
        main.isTruncated || alternate?.log.isTruncated == true
    }

    /// A full-screen program is on the alternate screen and the start of what it drew there
    /// was dropped: after a replay it has to repaint.
    var replayNeedsRepaint: Bool {
        if let alternate {
            return alternate.log.isTruncated
        }
        return isAlternateScreenActive && main.isTruncated
    }

    /// The full-screen program's alternate screen is active at the end of the output.
    var isAlternateScreenActive: Bool {
        tail.alternateScreenMode != nil
    }

    /// The kitty keyboard flags in effect at the end of the output.
    var keyboardFlags: Int {
        tail.activeKeyboardFlags
    }

    /// The working directory the shell last reported (OSC 7).
    var workingDirectory: String? {
        tail.workingDirectory
    }

    /// The bell, notifications, progress reports, ... in the output appended since the last call.
    mutating func takeEvents() -> [TerminalOutputEvent] {
        tail.takeEvents()
    }

    /// Kitty graphics bytes among the kept ones.
    var graphicsByteCount: Int {
        main.graphicsByteCount + (alternate?.log.graphicsByteCount ?? 0)
    }

    mutating func append(_ data: Data) {
        var rest = data[...]
        while !rest.isEmpty {
            let graphics = tail.graphicsByteCount
            let switches = tail.screenSwitches
            let count = tail.consumeUntilScreenSwitch(rest)
            let piece = rest.prefix(count)
            rest = rest.dropFirst(count)
            let pieceGraphics = tail.graphicsByteCount - graphics
            let switched = tail.screenSwitches != switches

            guard var stay = alternate else {
                main.append(piece, graphicsBytes: pieceGraphics)
                if switched, tail.alternateScreenMode == 1049 {
                    let entry = tail.withoutEvents
                    alternate = AlternateScreenOutput(
                        entry: entry,
                        log: TerminalOutputLog(limit: alternateLimit, graphicsAllowance: graphicsAllowance / 4, start: entry)
                    )
                }
                continue
            }
            guard switched else {
                // Not kept in `alternate` meanwhile, so the log's storage is not copied.
                alternate = nil
                stay.log.append(piece, graphicsBytes: pieceGraphics)
                alternate = stay
                continue
            }
            // The program left the alternate screen, with this piece's last sequence.
            alternate = nil
            if let standIn = tail.alternateScreenStandIn(since: stay.entry) {
                main.append(standIn, graphicsBytes: 0)
            } else {
                // RIS: it wipes the main screen as well.
                main.append(Data([0x1B, UInt8(ascii: "c")]), graphicsBytes: 0)
            }
        }
    }

    /// Bytes that rebuild the screen on a fresh terminal.
    func replay() -> Data {
        var out = main.replay(after: TerminalModeTracker())
        if let alternate {
            out.append(alternate.log.replay(after: alternate.entry))
        }
        return out
    }
}

/// Output bytes in chunks of up to ``chunkSize``, each compressed once full, with the oldest
/// bytes dropped to stay within the limit.
struct TerminalOutputLog: Sendable {
    static let chunkSize = 64 << 10

    let limit: Int
    let graphicsAllowance: Int
    /// Full chunks, oldest first.
    private var sealed: [Chunk] = []
    /// The newest bytes, not compressed yet.
    private var open = Data()
    /// Dropped bytes at the start of the oldest chunk (the open one when none is sealed).
    private var skip = 0
    /// Kept bytes.
    private(set) var byteCount = 0
    /// Kitty graphics bytes among all bytes appended.
    private var graphicsAppended = 0
    /// Bytes were dropped.
    private(set) var isTruncated = false
    /// The state after the dropped bytes.
    private var dropped: TerminalModeTracker
    private let droppedGraphicsStart: Int

    private struct Chunk: Sendable {
        let bytes: Data
        let isCompressed: Bool

        /// LZ4: on a terminal's output about 3 to 5 times smaller, at several hundred MB/s.
        init(_ raw: Data) {
            if let packed = try? (raw as NSData).compressed(using: .lz4) as Data, packed.count < raw.count {
                bytes = packed
                isCompressed = true
            } else {
                bytes = raw
                isCompressed = false
            }
        }

        var raw: Data {
            guard isCompressed else { return bytes }
            guard let raw = try? (bytes as NSData).decompressed(using: .lz4) as Data else {
                assertionFailure("a history chunk does not decompress")
                return Data()
            }
            return raw
        }
    }

    /// A log whose first byte follows output that left the terminal in the `start` state.
    init(limit: Int, graphicsAllowance: Int, start: TerminalModeTracker) {
        self.limit = limit
        self.graphicsAllowance = graphicsAllowance
        dropped = start.withoutEvents
        droppedGraphicsStart = start.graphicsByteCount
    }

    /// Memory the kept bytes take.
    var storedByteCount: Int {
        sealed.reduce(open.count) { $0 + $1.bytes.count }
    }

    /// Kitty graphics bytes among the kept ones.
    var graphicsByteCount: Int {
        graphicsAppended - (dropped.graphicsByteCount - droppedGraphicsStart)
    }

    /// `data` holds `graphicsBytes` bytes of kitty graphics commands.
    mutating func append(_ data: Data, graphicsBytes: Int) {
        guard !data.isEmpty else { return }
        var rest = data[...]
        while !rest.isEmpty {
            let piece = rest.prefix(Self.chunkSize - open.count)
            open.append(piece)
            rest = rest.dropFirst(piece.count)
            if open.count == Self.chunkSize {
                seal()
            }
        }
        byteCount += data.count
        graphicsAppended += graphicsBytes
        // Trim in steps of a chunk, not on every append.
        if budgetedByteCount(dropping: 0, droppedGraphics: droppedGraphics(dropped)) > limit + Self.chunkSize {
            trim()
        }
    }

    private mutating func seal() {
        let raw = sealed.isEmpty && skip > 0 ? Data(open.dropFirst(skip)) : open
        if sealed.isEmpty {
            skip = 0
        }
        sealed.append(Chunk(raw))
        open = Data()
    }

    /// Kitty graphics bytes among the dropped ones, when they leave `state` behind.
    private func droppedGraphics(_ state: TerminalModeTracker) -> Int {
        state.graphicsByteCount - droppedGraphicsStart
    }

    /// The kept bytes that count against ``limit`` once `count` more are dropped, with
    /// `droppedGraphics` graphics bytes among all dropped ones. Dropping bytes never raises it.
    private func budgetedByteCount(dropping count: Int, droppedGraphics: Int) -> Int {
        byteCount - count - min(graphicsAppended - droppedGraphics, graphicsAllowance)
    }

    /// Drops the oldest bytes down to the limit: whole chunks while what is left stays over
    /// it, then byte by byte in the next one.
    private mutating func trim() {
        while byteCount > 0, budgetedByteCount(dropping: 0, droppedGraphics: droppedGraphics(dropped)) > limit {
            let oldest = (sealed.first?.raw ?? open).dropFirst(skip)
            var after = dropped
            after.consume(oldest)
            isTruncated = true
            if budgetedByteCount(dropping: oldest.count, droppedGraphics: droppedGraphics(after)) >= limit {
                dropped = after
                byteCount -= oldest.count
                if sealed.isEmpty {
                    open = Data()
                } else {
                    sealed.removeFirst()
                }
                skip = 0
                continue
            }
            var tracker = dropped
            var cut = 0
            oldest.withUnsafeBytes { buffer in
                while cut < buffer.count,
                      budgetedByteCount(dropping: cut, droppedGraphics: tracker.graphicsByteCount - droppedGraphicsStart) > limit {
                    tracker.consume(buffer[cut])
                    cut += 1
                }
            }
            dropped = tracker
            skip += cut
            byteCount -= cut
            return
        }
    }

    /// The bytes that rebuild what this log's output did, on a terminal in the `earlier`
    /// state: the changes made by the dropped bytes, then the kept bytes from their first
    /// sequence boundary on.
    func replay(after earlier: TerminalModeTracker) -> Data {
        var tracker = dropped
        var body = Data(capacity: byteCount)
        var aligned = false
        func add(_ kept: Data) {
            guard !aligned else {
                body.append(kept)
                return
            }
            // The cut may have split an escape sequence or a UTF-8 character: skip its rest.
            var start = kept.startIndex
            while start < kept.endIndex, !tracker.isAtBoundary(next: kept[start]) {
                tracker.consume(kept[start])
                start = kept.index(after: start)
            }
            if start < kept.endIndex {
                aligned = true
                body.append(kept[start...])
            }
        }
        for (index, chunk) in sealed.enumerated() {
            add(index == 0 ? chunk.raw.dropFirst(skip) : chunk.raw)
        }
        add(sealed.isEmpty ? open.dropFirst(skip) : open)
        return tracker.changes(since: earlier) + body
    }
}
