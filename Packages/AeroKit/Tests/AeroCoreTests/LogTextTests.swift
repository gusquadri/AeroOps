import Foundation
import Testing
import AeroCore
import AeroTestSupport

@Suite("LogText")
struct LogTextTests {
    private let esc = "\u{1B}"

    @Test("demo-logger: colours removed, text and UTF-8 kept")
    func loggerFixture() throws {
        let raw = try Fixtures.string("docker/logs-demo-logger.txt")
        #expect(raw.utf8.count == 4095)
        let clean = LogText.stripANSI(raw)
        #expect(!clean.contains(esc))
        #expect(clean.utf8.count == 3607)
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 51)
        #expect(lines[0] == "2026-10-11T07:02:42.893066459Z WARN  slow query took 746ms (threshold 500ms)")
        #expect(lines[1] == "2026-10-11T07:02:43.393546094Z DEBUG cache hit ratio=0.59 entries=2577")
        #expect(lines[2] == "2026-10-11T07:02:43.895904365Z plain line 860 without colour codes")
        #expect(lines[3] == "2026-10-11T07:02:44.396522959Z NOTICE 256-colour line, bold and underline 861")
        #expect(lines[4] == "2026-10-11T07:02:44.899863485Z unicode line 862: café ✓ 日本")
        #expect(lines[6] == "2026-10-11T07:02:45.902640473Z ERROR request 864 failed: upstream timeout after 3000ms")

        let prepared = LogText.prepare(raw)
        #expect(prepared == CappedText(text: clean, truncated: false))
    }

    @Test("demo-logger: line and byte caps keep the newest whole lines")
    func loggerCaps() throws {
        let raw = try Fixtures.string("docker/logs-demo-logger.txt")
        let clean = LogText.stripANSI(raw)

        let ten = LogText.prepare(raw, maxLines: 10)
        #expect(ten.truncated)
        #expect(ten.text.split(separator: "\n").count == 10)
        #expect(clean.hasSuffix(ten.text))

        let small = LogText.prepare(raw, maxBytes: 200)
        #expect(small.truncated)
        #expect(small.text.utf8.count <= 200)
        #expect(clean.hasSuffix(small.text))
        #expect(clean.hasSuffix("\n" + small.text))
        #expect(small.text.hasPrefix("2026-10-11T"))
    }

    @Test("demo-exited: plain text passes through unchanged")
    func exitedFixture() throws {
        let raw = try Fixtures.string("docker/logs-demo-exited.txt")
        #expect(LogText.stripANSI(raw) == raw)
        #expect(LogText.prepare(raw) == CappedText(text: raw, truncated: false))
        #expect(LogText.capLines(raw, maxLines: 1).text == "2026-10-11T06:55:30.580619277Z fatal: /etc/job/config.yaml not found\n")
    }

    @Test("CSI sequences: SGR, private modes, truecolour, cursor moves, 8-bit CSI")
    func csi() {
        #expect(LogText.stripANSI("\(esc)[31mred\(esc)[0m") == "red")
        #expect(LogText.stripANSI("\(esc)[?25lhidden cursor\(esc)[?25h") == "hidden cursor")
        #expect(LogText.stripANSI("\(esc)[38;2;255;100;0mX\(esc)[m") == "X")
        #expect(LogText.stripANSI("a\(esc)[2K\(esc)[1Gb\(esc)[10;20Hc") == "abc")
        #expect(LogText.stripANSI("\u{9B}1mbold") == "bold")
        #expect(LogText.stripANSI("\(esc)[>4;2m\(esc)[2 q x") == " x")
    }

    @Test("OSC and other string sequences, with every terminator")
    func oscStrings() {
        #expect(LogText.stripANSI("\(esc)]0;window title\u{07}text") == "text")
        #expect(LogText.stripANSI("\(esc)]8;;https://example.com\(esc)\\link\(esc)]8;;\(esc)\\") == "link")
        #expect(LogText.stripANSI("\u{9D}0;title\u{9C}after") == "after")
        #expect(LogText.stripANSI("\(esc)P1$r0m\(esc)\\ok") == "ok")
        #expect(LogText.stripANSI("\(esc)_app command\u{07}ok") == "ok")
        #expect(LogText.stripANSI("\(esc)^privacy\(esc)\\ok\(esc)Xsos\u{9C}!") == "ok!")
        #expect(LogText.stripANSI("\(esc)]0;title\(esc)[1mB") == "B")
        #expect(LogText.stripANSI("\(esc)]0;title\nnext line\n") == "\nnext line\n")
        #expect(LogText.stripANSI("\(esc)]0;title\r\nnext") == "\nnext")
    }

    @Test("other escapes and lone ESC")
    func otherEscapes() {
        #expect(LogText.stripANSI("\(esc)(Bplain\(esc))0") == "plain")
        #expect(LogText.stripANSI("\(esc)7saved\(esc)8") == "saved")
        #expect(LogText.stripANSI("\(esc)=\(esc)>keypad") == "keypad")
        #expect(LogText.stripANSI("\(esc)#8x") == "x")
        #expect(LogText.stripANSI("abc\(esc)") == "abc")
        #expect(LogText.stripANSI("\(esc)\(esc)\(esc)[1mx") == "x")
        #expect(LogText.stripANSI("a\(esc)\nb") == "a\nb")
        #expect(LogText.stripANSI("\(esc)é") == "é")
        #expect(LogText.stripANSI("\(esc)[12\nX") == "\nX")
        #expect(LogText.stripANSI("\(esc)[1;2") == "")
    }

    @Test("line endings and control characters")
    func controls() {
        #expect(LogText.stripANSI("a\r\nb\r\n") == "a\nb\n")
        #expect(LogText.stripANSI("50%\r75%\r100%\n") == "50%\n75%\n100%\n")
        #expect(LogText.stripANSI("x\r\r\ny") == "x\ny")
        #expect(LogText.stripANSI("x\r\(esc)[K\ny") == "x\ny")
        #expect(LogText.stripANSI("a\u{07}b\u{08}c\u{7F}d\u{85}e\u{0}f\u{0C}") == "abcdef")
        #expect(LogText.stripANSI("col1\tcol2\n\n") == "col1\tcol2\n\n")
    }

    @Test("Unicode is untouched, including emoji and combining marks")
    func unicode() {
        let text = "café ✓ 日本 👍🏽 e\u{301} \u{A0}nbsp\n"
        #expect(LogText.stripANSI(text) == text)
        #expect(LogText.stripANSI("\(esc)[1m👍🏽\(esc)[0m") == "👍🏽")
    }

    @Test("capLines keeps head or tail, with or without a final newline")
    func capLines() {
        #expect(LogText.capLines("a\nb\nc\n", maxLines: 2) == CappedText(text: "b\nc\n", truncated: true))
        #expect(LogText.capLines("a\nb\nc", maxLines: 2) == CappedText(text: "b\nc", truncated: true))
        #expect(LogText.capLines("a\nb\nc\n", maxLines: 2, keep: .head) == CappedText(text: "a\nb\n", truncated: true))
        #expect(LogText.capLines("a\nb\nc", maxLines: 3) == CappedText(text: "a\nb\nc", truncated: false))
        #expect(LogText.capLines("a\nb\nc\n", maxLines: 3) == CappedText(text: "a\nb\nc\n", truncated: false))
        #expect(LogText.capLines("\n\n\n", maxLines: 2) == CappedText(text: "\n\n", truncated: true))
        #expect(LogText.capLines("a\nb", maxLines: 0) == CappedText(text: "", truncated: true))
        #expect(LogText.capLines("a\nb", maxLines: -3) == CappedText(text: "", truncated: true))
        #expect(LogText.capLines("", maxLines: 0) == CappedText(text: "", truncated: false))
        #expect(LogText.capLines("日本\n語\n", maxLines: 1) == CappedText(text: "語\n", truncated: true))
    }

    @Test("capLines defaults to the plan's 2,000-line limit")
    func capLinesDefault() {
        let text = (0..<2_500).map { "line \($0)\n" }.joined()
        let capped = LogText.capLines(text)
        #expect(LogText.maxLines == 2_000)
        #expect(capped.truncated)
        #expect(capped.text.hasPrefix("line 500\n"))
        #expect(capped.text.hasSuffix("line 2499\n"))
        #expect(capped.text.split(separator: "\n").count == 2_000)
    }

    @Test("capBytes cuts at line boundaries, never inside a character")
    func capBytes() {
        let text = "aaaa\nbbbb\ncccc\n"
        #expect(LogText.capBytes(text, maxBytes: 11) == CappedText(text: "bbbb\ncccc\n", truncated: true))
        #expect(LogText.capBytes(text, maxBytes: 11, keep: .head) == CappedText(text: "aaaa\nbbbb\n", truncated: true))
        #expect(LogText.capBytes(text, maxBytes: 15) == CappedText(text: text, truncated: false))
        #expect(LogText.capBytes(text, maxBytes: 0) == CappedText(text: "", truncated: true))
        #expect(LogText.capBytes("日本語", maxBytes: 4) == CappedText(text: "語", truncated: true))
        #expect(LogText.capBytes("日本語", maxBytes: 4, keep: .head) == CappedText(text: "日", truncated: true))
        #expect(LogText.capBytes("👍", maxBytes: 3, keep: .head) == CappedText(text: "", truncated: true))
        #expect(LogText.capBytes("👍", maxBytes: 3) == CappedText(text: "", truncated: true))
        #expect(LogText.capBytes("xxxxxxxx\n", maxBytes: 5) == CappedText(text: "xxxx\n", truncated: true))
        #expect(LogText.defaultMaxBytes == 1_048_576)
    }

    @Test("prepare on a huge single line respects the byte cap")
    func hugeLine() {
        let text = String(repeating: "é", count: 700_000)
        let capped = LogText.prepare(text)
        #expect(capped.truncated)
        #expect(capped.text.utf8.count <= LogText.defaultMaxBytes)
        #expect(capped.text.utf8.count >= LogText.defaultMaxBytes - 1)
        #expect(capped.text.allSatisfy { $0 == "é" })
    }
}
