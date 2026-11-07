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

    @Test("counts kitty graphics bytes, not other application commands")
    func graphicsBytes() {
        var tracker = TerminalModeTracker()
        tracker.consume(bytes("\(esc)_Ga=T;AAAA\(esc)\\\(esc)_Xother\(esc)\\"))
        #expect(tracker.graphicsByteCount == "Ga=T;AAAA".utf8.count)
    }

    @Test("reads the working directory from OSC 7")
    func workingDirectory() {
        var tracker = TerminalModeTracker()
        tracker.consume(bytes("\(esc)]7;file://web-1/home/dev/My%20Dir\u{07}"))
        #expect(tracker.workingDirectory == "/home/dev/My Dir")
        tracker.consume(bytes("\(esc)]7;kitty-shell-cwd://web-1/srv/100%\(esc)\\"))
        #expect(tracker.workingDirectory == "/srv/100%")
        tracker.consume(bytes("\(esc)]7;file://web-1\u{07}\(esc)]7;file://h/a%0Ab\u{07}\(esc)c"))
        #expect(tracker.workingDirectory == "/srv/100%")
    }

    @Test("collects the bell, notifications, progress and command marks")
    func events() {
        var tracker = TerminalModeTracker()
        tracker.collectsEvents = true
        tracker.consume(bytes("a\u{07}\u{07}b\(esc)]0;title\u{07}"))
        #expect(tracker.takeEvents() == [.bell])
        tracker.consume(bytes("\(esc)]9;build done\u{07}\(esc)]777;notify;Deploy;ok; really\(esc)\\\(esc)]9;1;100\u{07}"))
        #expect(tracker.takeEvents() == [
            .notification(title: "", body: "build done"),
            .notification(title: "Deploy", body: "ok; really"),
        ])
        tracker.consume(bytes("\(esc)]9;4;1;42\u{07}\(esc)]9;4;3\u{07}\(esc)]9;4;2;250\u{07}\(esc)]9;4;0\u{07}"))
        #expect(tracker.takeEvents() == [
            .progress(TerminalProgress(state: .running, percent: 42)),
            .progress(TerminalProgress(state: .indeterminate, percent: nil)),
            .progress(TerminalProgress(state: .failed, percent: 100)),
            .progress(nil),
        ])
        tracker.consume(bytes("\(esc)]133;A\u{07}\(esc)]133;C\u{07}\(esc)]133;D;2\u{07}\(esc)]133;D\u{07}"))
        #expect(tracker.takeEvents() == [.commandStarted, .commandFinished(exitCode: 2), .commandFinished(exitCode: nil)])
        #expect(tracker.takeEvents().isEmpty)
    }

    @Test("collects nothing unless asked")
    func noEvents() {
        var tracker = TerminalModeTracker()
        tracker.consume(bytes("\u{07}\(esc)]9;hi\u{07}"))
        #expect(tracker.takeEvents().isEmpty)
    }

    @Test("the cursor shape, the colours a program set and the newer modes")
    func cursorAndColors() {
        #expect(baseline(after: "\(esc)[4 q\(esc)]4;1;rgb:ff/00/00;2;?\(esc)\\\(esc)]11;#101010\u{07}")
            == "\(esc)[4 q\(esc)]4;1;rgb:ff/00/00\(esc)\\\(esc)]11;#101010\(esc)\\")
        #expect(baseline(after: "\(esc)[5 q\(esc)[?12l") == "\(esc)[5 q\(esc)[?12l")
        #expect(baseline(after: "\(esc)[5 q\(esc)[0 q") == "")
        #expect(baseline(after: "\(esc)]4;1;red\(esc)\\\(esc)]4;2;blue\(esc)\\\(esc)]104;1\(esc)\\\(esc)]10;a;b\u{07}\(esc)]110\u{07}")
            == "\(esc)]4;2;blue\(esc)\\\(esc)]11;b\(esc)\\")
        #expect(baseline(after: "\(esc)]4;1;red\u{07}\(esc)]104\u{07}") == "")
        #expect(baseline(after: "\(esc)[?2027h\(esc)[?2031h\(esc)[?2048h\(esc)[?12l") == "\(esc)[?12l\(esc)[?2027h\(esc)[?2031h\(esc)[?2048h")
        #expect(baseline(after: "\(esc)[?2031h\(esc)[?2031l") == "")
        #expect(baseline(after: "\(esc)[4 q\(esc)]4;1;red\u{07}\(esc)[?2027h\(esc)c") == "")
    }

    @Test("DECRC and leaving mode 1049 restore the saved attributes")
    func savedCursor() {
        #expect(baseline(after: "\(esc)[1m\(esc)7\(esc)[31m\(esc)(0\(esc)8") == "\(esc)[1m")
        #expect(baseline(after: "\(esc)[1m\(esc)[s\(esc)[0m\(esc)[u") == "\(esc)[1m")
        #expect(baseline(after: "\(esc)[1m\(esc)[?1049h\(esc)[31m\(esc)(0\(esc)[?1049l") == "\(esc)[1m")
        #expect(baseline(after: "\(esc)[1m\(esc)8") == "")
        #expect(baseline(after: "\(esc)[2 q\(esc)[?1049h\(esc)[5 q\(esc)[?1049l") == "\(esc)[2 q\(esc)[?12h")
        #expect(baseline(after: "\(esc)[?1049h\(esc)[6 q") == "\(esc)[?1049h\(esc)[6 q")
        #expect(baseline(after: "\(esc)[?47h\(esc)[4 q\(esc)[?47l") == "\(esc)[4 q")
    }

    @Test("the changes from one state to another")
    func changes() {
        var earlier = TerminalModeTracker()
        earlier.consume(bytes("\(esc)[?2004h\(esc)[?1000h\(esc)[>1u\(esc)[1m\(esc)]4;1;red\u{07}"))
        var later = earlier
        later.consume(bytes("\(esc)[?2004l\(esc)[?1000l\(esc)[>3u\(esc)[31m\(esc)]104\u{07}"))
        #expect(String(decoding: later.changes(since: earlier), as: UTF8.self)
            == "\(esc)[<8u\(esc)[>1u\(esc)[>3u\(esc)[?2004l\(esc)[?1000l\(esc)[m\(esc)[1m\(esc)[31m\(esc)]104;1\(esc)\\")
        #expect(later.changes(since: later).isEmpty)
    }

    @Test("stops after the sequence that switches screens")
    func screenSwitches() {
        var tracker = TerminalModeTracker()
        let data = bytes("ab\(esc)[?1049hcd\(esc)[?1049lef")
        #expect(tracker.consumeUntilScreenSwitch(data) == 10)
        #expect(tracker.alternateScreenMode == 1049)
        #expect(tracker.consumeUntilScreenSwitch(data.dropFirst(10)) == 10)
        #expect(tracker.alternateScreenMode == nil)
        #expect(tracker.lastScreenSwitchMode == 1049)
        #expect(tracker.consumeUntilScreenSwitch(data.dropFirst(20)) == 2)
        #expect(tracker.screenSwitches == 2)
        #expect(tracker.consumeUntilScreenSwitch(bytes("\(esc)[?47h\(esc)[?1049hx\(esc)cy")) == 6)
        #expect(tracker.consumeUntilScreenSwitch(bytes("\(esc)[?1049hx\(esc)cy")) == 11)
        #expect(tracker.screenSwitches == 4)
        #expect(tracker.lastScreenSwitchMode == nil)
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

    @Test("images get their own allowance on top of the text limit")
    func graphicsAllowance() {
        let image = "\(esc)_Ga=T,i=1;" + String(repeating: "A", count: 100_000) + "\(esc)\\"
        var history = TerminalHistory(limit: 16, graphicsAllowance: 200_000)
        history.append(bytes(String(repeating: "x", count: 100_000)))
        history.append(bytes(image + "end"))
        #expect(history.isTruncated)
        #expect(history.replay() == bytes(String(repeating: "x", count: 16) + image + "end"))
        history.append(bytes(String(repeating: "y", count: 100_000)))
        #expect(history.replay() == bytes(String(repeating: "y", count: 16)))
        #expect(history.graphicsByteCount == 0)
    }

    @Test("follows the keyboard flags, working directory and events of the live output")
    func liveState() {
        var history = TerminalHistory()
        history.append(bytes("\(esc)[>9u\(esc)]7;file://h/tmp\u{07}\u{07}"))
        #expect(history.keyboardFlags == 9)
        #expect(history.workingDirectory == "/tmp")
        #expect(history.takeEvents() == [.bell])
        history.append(bytes("\(esc)[?1049h"))
        #expect(history.keyboardFlags == 0)
    }

    @Test("follows the alternate screen")
    func alternateScreen() {
        var history = TerminalHistory()
        history.append(bytes("\(esc)[?1049h"))
        #expect(history.isAlternateScreenActive)
        history.append(bytes("\(esc)[?1049l"))
        #expect(!history.isAlternateScreenActive)
    }

    @Test("a full-screen program's output gives way to a stand-in once it leaves")
    func alternateScreenStandIn() {
        var history = TerminalHistory(limit: 1000, alternateLimit: 100)
        history.append(bytes("$ ls\r\nfile\r\n$ top\r\n\(esc)[?1049h\(esc)[?1h\(esc)[2;20r"))
        let frames = String(repeating: "\(esc)[H\(esc)[2J\(esc)[1;31mframe\(esc)[m", count: 20_000)
        var rest = Substring(frames)
        while !rest.isEmpty {
            history.append(bytes(String(rest.prefix(4093))))
            rest = rest.dropFirst(4093)
        }
        history.append(bytes("\(esc)[?2004h\(esc)[5 q\(esc)[?1049l$ "))
        #expect(!history.isAlternateScreenActive)
        #expect(!history.isTruncated)
        #expect(history.replay() == bytes(
            "$ ls\r\nfile\r\n$ top\r\n\(esc)[?1049h" + "\(esc)[2;20r\(esc)[?1049l"
                + "\(esc)[?1h\(esc)[?12h\(esc)[?2004h" + "$ "
        ))
    }

    @Test("a full-screen program that runs keeps only its latest frames and repaints")
    func runningProgram() {
        var history = TerminalHistory(limit: 1000, alternateLimit: 16)
        history.append(bytes("$ top\r\n\(esc)[?1049h"))
        #expect(!history.replayNeedsRepaint)
        history.append(bytes("\(esc)[?25l" + String(repeating: "x", count: 100_000)))
        #expect(history.isAlternateScreenActive)
        #expect(history.replayNeedsRepaint)
        #expect(history.replay() == bytes("$ top\r\n\(esc)[?1049h\(esc)[?25l" + String(repeating: "x", count: 16)))
        history.append(bytes("\(esc)[?25h\(esc)[?1049l"))
        #expect(!history.isTruncated)
        #expect(!history.replayNeedsRepaint)
        #expect(history.replay() == bytes("$ top\r\n\(esc)[?1049h\(esc)[?1049l"))
    }

    @Test("RIS on the alternate screen ends the stay and wipes the screen")
    func alternateScreenReset() {
        var history = TerminalHistory()
        history.append(bytes("a\(esc)[?1049hframe\(esc)cb"))
        #expect(!history.isAlternateScreenActive)
        #expect(history.replay() == bytes("a\(esc)[?1049h\(esc)cb"))
    }

    @Test("modes 47 and 1047 stay in the main output")
    func legacyAlternateScreen() {
        var history = TerminalHistory()
        history.append(bytes("a\(esc)[?1047hframe\(esc)[?1047lb"))
        #expect(history.replay() == bytes("a\(esc)[?1047hframe\(esc)[?1047lb"))
    }

    @Test("keeps full chunks compressed")
    func compression() {
        var history = TerminalHistory()
        let line = "\(esc)[1;32mdrwxr-xr-x\(esc)[m  2 dev dev 4096 Oct 15 03:00 \(esc)[34msrc\(esc)[m\r\n"
        for index in 0..<20_000 {
            history.append(bytes("\(index) " + line))
        }
        #expect(history.byteCount > 1_000_000)
        #expect(history.storedByteCount < history.byteCount / 3)
        #expect(history.replay().suffix(line.utf8.count) == bytes(line))
    }

    @Test("old images in front of the text go in one pass")
    func imagesInFront() {
        var history = TerminalHistory(limit: 1000, graphicsAllowance: 4 << 20)
        let image = "\(esc)_Ga=T,i=1;" + String(repeating: "A", count: 100_000) + "\(esc)\\"
        for _ in 0..<40 {
            history.append(bytes(image))
        }
        #expect(!history.isTruncated)
        history.append(bytes(String(repeating: "y", count: 2 << 20)))
        #expect(history.replay() == bytes(String(repeating: "y", count: 1000)))
        #expect(history.graphicsByteCount == 0)
        #expect(history.byteCount == 1000)
    }
}
