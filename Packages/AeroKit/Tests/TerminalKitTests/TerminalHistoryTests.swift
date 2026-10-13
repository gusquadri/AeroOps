import Foundation
import Testing
@testable import TerminalKit

private let esc = "\u{1B}"

private func bytes(_ text: String) -> Data {
    Data(text.utf8)
}

private func baseline(after text: String) -> String {
    var tracker = TerminalModeTracker()
    tracker.consume(bytes(text))
    return String(decoding: tracker.baseline, as: UTF8.self)
}

@Suite("Terminal mode tracker")
struct TerminalModeTrackerTests {
    @Test("a fresh terminal needs no baseline")
    func fresh() {
        #expect(TerminalModeTracker().baseline.isEmpty)
        #expect(baseline(after: "plain text\r\n") == "")
    }

    @Test("private modes keep only what differs from a fresh terminal")
    func privateModes() {
        #expect(baseline(after: "\(esc)[?2004h\(esc)[?1h\(esc)[?25l") == "\(esc)[?1h\(esc)[?25l\(esc)[?2004h")
        #expect(baseline(after: "\(esc)[?1;2004h\(esc)[?25l\(esc)[?25h\(esc)[?1l") == "\(esc)[?2004h")
        #expect(baseline(after: "\(esc)[?1000h\(esc)[?1006h") == "\(esc)[?1000h\(esc)[?1006h")
        #expect(baseline(after: "\(esc)[?1000h\(esc)[?1000l") == "")
    }

    @Test("a sequence split across reads is still followed")
    func splitSequence() {
        var tracker = TerminalModeTracker()
        tracker.consume(bytes("\(esc)[?20"))
        #expect(!tracker.isAtBoundary(next: UInt8(ascii: "0")))
        tracker.consume(bytes("04h"))
        #expect(tracker.isAtBoundary(next: UInt8(ascii: "x")))
        #expect(String(decoding: tracker.baseline, as: UTF8.self) == "\(esc)[?2004h")
    }

    @Test("text inside OSC and DCS strings is not parsed as sequences")
    func strings() {
        #expect(baseline(after: "\(esc)]0;title [?2004h\u{07}") == "")
        #expect(baseline(after: "\(esc)P+q544e[?1049h\(esc)\\") == "")
        // ESC that is not a string terminator ends the string and starts a sequence.
        #expect(baseline(after: "\(esc)]0;title\(esc)[?2004h") == "\(esc)[?2004h")
    }

    @Test("the alternate screen, its kitty flags and the scroll region")
    func alternateScreen() {
        var tracker = TerminalModeTracker()
        tracker.consume(bytes("\(esc)[>1u\(esc)[?1049h\(esc)[>3u\(esc)[2;20r"))
        #expect(tracker.alternateScreenMode == 1049)
        #expect(String(decoding: tracker.baseline, as: UTF8.self)
            == "\(esc)[>1u\(esc)[?1049h\(esc)[>3u\(esc)[2;20r")
        tracker.consume(bytes("\(esc)[<u\(esc)[r\(esc)[?1049l"))
        #expect(tracker.alternateScreenMode == nil)
        #expect(String(decoding: tracker.baseline, as: UTF8.self) == "\(esc)[>1u")
        #expect(baseline(after: "\(esc)[=5;1u") == "\(esc)[=5;1u")
    }

    @Test("graphic rendition since the last reset")
    func graphicRendition() {
        #expect(baseline(after: "\(esc)[1m\(esc)[31m") == "\(esc)[1m\(esc)[31m")
        #expect(baseline(after: "\(esc)[1m\(esc)[31m\(esc)[m") == "")
        #expect(baseline(after: "\(esc)[1m\(esc)[0;32m") == "\(esc)[0;32m")
    }

    @Test("keypad, modifyOtherKeys and character sets")
    func keysAndCharsets() {
        #expect(baseline(after: "\(esc)=\(esc)[>4;2m\(esc)(0\u{0E}") == "\(esc)=\(esc)[>4;2m\(esc)(0\u{0E}")
        #expect(baseline(after: "\(esc)=\(esc)>\(esc)[>4;2m\(esc)[>4m\(esc)(0\(esc)(B\u{0E}\u{0F}") == "")
    }

    @Test("RIS resets everything, DECSTR the soft state")
    func resets() {
        #expect(baseline(after: "\(esc)[?2004h\(esc)[?1049h\(esc)[1m\(esc)c") == "")
        #expect(baseline(after: "\(esc)[?2004h\(esc)[?1h\(esc)[1m\(esc)[!p") == "\(esc)[?2004h")
    }

    @Test("a replay starts outside sequences and UTF-8 characters")
    func boundaries() {
        let tracker = TerminalModeTracker()
        #expect(tracker.isAtBoundary(next: UInt8(ascii: "a")))
        #expect(tracker.isAtBoundary(next: 0xC3))
        #expect(!tracker.isAtBoundary(next: 0xA9))
    }
}

@Suite("Terminal history")
struct TerminalHistoryTests {
    @Test("keeps short output as it is")
    func short() {
        var history = TerminalHistory()
        history.append(bytes("hello\r\n"))
        history.append(bytes("\(esc)[?2004hworld"))
        #expect(!history.isTruncated)
        #expect(history.replay() == bytes("hello\r\n\(esc)[?2004hworld"))
    }

    @Test("dropped output leaves its modes in the baseline")
    func truncatedBaseline() {
        var history = TerminalHistory(limit: 16)
        history.append(bytes("\(esc)[?2004h" + String(repeating: "x", count: 100_000)))
        #expect(history.isTruncated)
        #expect(history.byteCount == 16)
        #expect(history.replay() == bytes("\(esc)[?2004h" + String(repeating: "x", count: 16)))
    }

    @Test("a cut inside a sequence skips its rest and keeps its effect")
    func cutInSequence() {
        var history = TerminalHistory(limit: 4)
        history.append(bytes(String(repeating: "x", count: 100_000) + "\(esc)[31mZ"))
        #expect(history.replay() == bytes("\(esc)[31mZ"))
    }

    @Test("a cut inside a UTF-8 character skips its rest")
    func cutInCharacter() {
        var history = TerminalHistory(limit: 2)
        history.append(bytes(String(repeating: "x", count: 100_000) + "é!"))
        #expect(history.replay() == bytes("!"))
    }

    @Test("follows the alternate screen")
    func alternateScreen() {
        var history = TerminalHistory()
        history.append(bytes("\(esc)[?1049h"))
        #expect(history.isAlternateScreenActive)
        history.append(bytes("\(esc)[?1049l"))
        #expect(!history.isAlternateScreenActive)
    }
}
