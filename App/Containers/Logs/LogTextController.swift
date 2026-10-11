import AeroTheme
import AppKit
import SwiftUI

/// One log line as received: the raw text (with the `--timestamps` prefix) plus what the
/// display needs to know about it.
struct LogLine: Sendable, Hashable {
    /// The line without its terminator, ANSI already stripped by Collectors.
    var text: String
    /// Length of the leading RFC 3339 timestamp and its space (ASCII, so UTF-8 and UTF-16 agree); 0 when there is none.
    var timestampLength: Int
    /// A kubectl status message printed in place of log text (e.g. "unable to retrieve
    /// container logs …" between restarts), shown as an info line.
    var isInfo: Bool

    init(_ text: String) {
        self.text = text
        timestampLength = Self.timestampPrefixLength(text)
        let body = Substring(text.utf8.dropFirst(timestampLength))
        isInfo = Self.isStatusMessage(body)
    }

    /// An info line written by AeroOps itself (stream ended, previous instance missing…).
    init(info: String) {
        text = info
        timestampLength = 0
        isInfo = true
    }

    /// The text to show: with or without the timestamp.
    func display(timestamps: Bool) -> String {
        guard !timestamps, timestampLength > 0 else { return text }
        return String(Substring(text.utf8.dropFirst(timestampLength)))
    }

    /// `2026-10-11T10:00:00.123456789Z ` (docker) or `…+00:00 ` (kubectl): the length up to
    /// and including the first space, when the line starts with such a timestamp.
    static func timestampPrefixLength(_ text: String) -> Int {
        let utf8 = text.utf8
        guard utf8.count >= 21 else { return 0 }
        var index = 0
        for byte in utf8 {
            switch index {
            case 0...3, 5, 6, 8, 9:
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return 0 }
            case 4, 7:
                guard byte == UInt8(ascii: "-") else { return 0 }
            case 10:
                guard byte == UInt8(ascii: "T") else { return 0 }
            default:
                if byte == UInt8(ascii: " ") { return index >= 19 ? index + 1 : 0 }
                if index > 40 { return 0 }
            }
            index += 1
        }
        return 0
    }

    /// kubectl prints these on stdout instead of log text while a container restarts.
    static func isStatusMessage(_ body: Substring) -> Bool {
        body.hasPrefix("unable to retrieve container logs for ")
            || body.hasPrefix("failed to try resolving symlinks in path ")
    }
}

/// The log text view: an `NSTextView` (TextKit 1, non-contiguous layout) that keeps the newest
/// ``maxLines`` lines (``trimSlack`` more before it trims), appends batches without re-laying
/// out what is already there, highlights
/// search matches and keeps the view pinned to the bottom while the user is there.
///
/// It is the single owner of the lines, so toggling timestamps re-renders from the raw text.
/// All work runs on the main actor; callers batch lines (``LogViewerModel`` flushes every
/// 100 ms) so a busy container costs one append per flush, not one per line.
@MainActor
final class LogTextController: NSObject, NSTextViewDelegate {
    /// Oldest lines are dropped beyond this many.
    nonisolated static let maxLines = 10_000
    /// Lines over ``maxLines`` tolerated before trimming, so trimming happens in chunks: a cut at
    /// the start invalidates layout for the whole text, so it should not happen on every flush
    /// of a busy stream.
    static let trimSlack = 2_000
    /// Matches highlighted at most (the count stops there too).
    nonisolated static let maxMatches = 5_000

    let scrollView: NSScrollView
    let textView: NSTextView

    private(set) var lines: [LogLine] = []
    /// UTF-16 length of each displayed line including its newline.
    private var lengths: [Int] = []
    private(set) var droppedLines = 0
    private(set) var showTimestamps = true

    private(set) var query = ""
    private(set) var matches: [NSRange] = []
    private(set) var currentMatch: Int?

    /// Called when the selection becomes empty or non-empty.
    var onSelectionChange: ((Bool) -> Void)?
    /// Called after the match list changed (count, current index).
    var onMatchesChange: (() -> Void)?

    private let font: NSFont
    private let textColor = NSColor(Aero.text.primary)
    private let timestampColor = NSColor(Aero.text.secondary)
    private let infoColor = NSColor(Aero.aquaDeep)
    private let matchColor = NSColor(Aero.sun).withAlphaComponent(0.45)
    private let currentMatchColor = NSColor(Aero.sun)

    override init() {
        // The system monospaced face at the Callout text style's size (AeroTheme has no
        // monospaced token; log text must align in columns).
        font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        let textView = NSTextView(usingTextLayoutManager: false)
        self.textView = textView
        scrollView = NSScrollView()
        super.init()

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.allowsUndo = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(Aero.glass.solidFill)
        textView.textColor = textColor
        textView.font = font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        // Non-contiguous layout only lays out what is shown; background layout would instead
        // lay out the whole 10k-line document on the main thread in idle slices after every flush.
        textView.layoutManager?.backgroundLayoutEnabled = false
        textView.selectedTextAttributes = [.backgroundColor: NSColor(Aero.aqua).withAlphaComponent(0.3)]
        textView.setAccessibilityLabel("Log lines")
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(Aero.glass.solidFill)
        scrollView.borderType = .noBorder
    }

    var lineCount: Int { lines.count }
    var hasSelection: Bool { textView.selectedRange().length > 0 }
    var displayedText: String { textView.string }

    // MARK: - Content

    /// Replaces everything.
    func reset(_ newLines: [LogLine] = []) {
        lines = []
        lengths = []
        droppedLines = 0
        matches = []
        currentMatch = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
        append(newLines)
    }

    /// Appends `batch` (one attributed-string edit), trims the oldest lines beyond the cap and
    /// highlights matches in the new text. Keeps the view at the bottom if it was there.
    func append(_ batch: [LogLine]) {
        guard !batch.isEmpty, let storage = textView.textStorage else { return }
        var batch = batch[...]
        if batch.count > Self.maxLines {
            droppedLines += batch.count - Self.maxLines
            batch = batch.suffix(Self.maxLines)
        }
        let pinned = isPinnedToBottom
        let start = storage.length
        let chunk = render(batch)
        storage.beginEditing()
        storage.append(chunk.text)
        storage.endEditing()
        lines.append(contentsOf: batch)
        lengths.append(contentsOf: chunk.lengths)

        var removed = 0
        if lines.count > Self.maxLines + Self.trimSlack {
            let drop = lines.count - Self.maxLines
            removed = lengths[..<drop].reduce(0, +)
            lines.removeFirst(drop)
            lengths.removeFirst(drop)
            droppedLines += drop
            storage.beginEditing()
            storage.deleteCharacters(in: NSRange(location: 0, length: removed))
            storage.endEditing()
            shiftMatches(by: removed)
        }
        if !query.isEmpty {
            let from = max(0, start - removed)
            highlight(in: NSRange(location: from, length: storage.length - from))
        }
        if pinned { scrollToBottom() }
    }

    /// Shows or hides the timestamp prefix (re-renders every line).
    func setShowTimestamps(_ show: Bool) {
        guard show != showTimestamps else { return }
        showTimestamps = show
        let all = lines
        let dropped = droppedLines
        let savedQuery = query
        query = ""
        reset(all)
        droppedLines = dropped
        setQuery(savedQuery)
        scrollToBottom()
    }

    var isPinnedToBottom: Bool {
        guard let document = scrollView.documentView else { return true }
        let visible = scrollView.contentView.documentVisibleRect
        return visible.maxY >= document.bounds.maxY - 24 || document.bounds.height <= visible.height
    }

    func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    /// One string for the whole batch, then colour runs for timestamps and info lines: a single
    /// attributed-string build per flush, whatever the line count.
    private func render(_ batch: ArraySlice<LogLine>) -> (text: NSAttributedString, lengths: [Int]) {
        var whole = ""
        whole.reserveCapacity(batch.reduce(0) { $0 + $1.text.utf8.count + 4 })
        var lengths: [Int] = []
        lengths.reserveCapacity(batch.count)
        var stamps: [NSRange] = []
        var infos: [NSRange] = []
        var offset = 0
        for line in batch {
            let body = line.display(timestamps: showTimestamps)
            let shown = line.isInfo ? Self.infoMarker + body : body
            let length = shown.utf16.count + 1
            if line.isInfo {
                infos.append(NSRange(location: offset, length: length - 1))
            } else if showTimestamps, line.timestampLength > 0 {
                stamps.append(NSRange(location: offset, length: line.timestampLength))
            }
            whole += shown
            whole += "\n"
            lengths.append(length)
            offset += length
        }
        let result = NSMutableAttributedString(string: whole, attributes: [.font: font, .foregroundColor: textColor])
        result.beginEditing()
        for range in stamps { result.addAttribute(.foregroundColor, value: timestampColor, range: range) }
        for range in infos { result.addAttribute(.foregroundColor, value: infoColor, range: range) }
        result.endEditing()
        return (result, lengths)
    }

    /// Prefix of info lines.
    static let infoMarker = "ⓘ "

    // MARK: - Search

    /// Highlights every case-insensitive match of `newQuery` (up to ``maxMatches``) and makes
    /// the last one current.
    func setQuery(_ newQuery: String) {
        guard let storage = textView.textStorage else { return }
        query = newQuery
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        matches = []
        currentMatch = nil
        if !newQuery.isEmpty {
            highlight(in: NSRange(location: 0, length: storage.length))
            if !matches.isEmpty { select(match: matches.count - 1) }
        }
        onMatchesChange?()
    }

    /// Moves to the next (`forward`) or previous match, wrapping around.
    func moveMatch(forward: Bool) {
        guard !matches.isEmpty else { return }
        let next: Int
        if let current = currentMatch {
            next = forward ? (current + 1) % matches.count : (current - 1 + matches.count) % matches.count
        } else {
            next = forward ? 0 : matches.count - 1
        }
        select(match: next)
        onMatchesChange?()
    }

    private func highlight(in range: NSRange) {
        guard !query.isEmpty, let storage = textView.textStorage, range.length > 0 else { return }
        let string = storage.string as NSString
        var searchRange = range
        storage.beginEditing()
        while matches.count < Self.maxMatches, searchRange.length > 0 {
            let found = string.range(of: query, options: [.caseInsensitive], range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            matches.append(found)
            storage.addAttribute(.backgroundColor, value: matchColor, range: found)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: range.location + range.length - next)
        }
        storage.endEditing()
        onMatchesChange?()
    }

    private func select(match index: Int) {
        guard let storage = textView.textStorage, matches.indices.contains(index) else { return }
        storage.beginEditing()
        if let current = currentMatch, matches.indices.contains(current) {
            storage.addAttribute(.backgroundColor, value: matchColor, range: matches[current])
        }
        currentMatch = index
        storage.addAttribute(.backgroundColor, value: currentMatchColor, range: matches[index])
        storage.endEditing()
        textView.scrollRangeToVisible(matches[index])
        textView.showFindIndicator(for: matches[index])
    }

    /// After `removed` characters were cut from the start.
    private func shiftMatches(by removed: Int) {
        guard !matches.isEmpty else { return }
        let currentRange = currentMatch.map { matches[$0] }
        matches = matches.compactMap { range in
            range.location >= removed ? NSRange(location: range.location - removed, length: range.length) : nil
        }
        if let currentRange, currentRange.location >= removed {
            currentMatch = matches.firstIndex { $0.location == currentRange.location - removed }
        } else {
            currentMatch = nil
        }
        onMatchesChange?()
    }

    // MARK: - Copy

    /// Copies every displayed line.
    func copyAll() {
        copy(textView.string)
    }

    /// Copies the selected text.
    func copySelection() {
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        copy((textView.string as NSString).substring(with: range))
    }

    private func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    // MARK: - NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?(hasSelection)
    }
}

/// Hosts a ``LogTextController``'s scroll view in SwiftUI. The controller, not SwiftUI, drives
/// the content, so new lines never re-render the SwiftUI hierarchy.
struct LogTextView: NSViewRepresentable {
    let controller: LogTextController

    func makeNSView(context: Context) -> NSScrollView {
        controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
