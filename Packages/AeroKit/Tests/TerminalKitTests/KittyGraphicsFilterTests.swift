import Foundation
import Testing
@testable import TerminalKit

private let esc = "\u{1B}"
private let blocked = KittyGraphicsFilter.blockedMessage

private func run(_ text: String) -> (output: String, replies: String) {
    var filter = KittyGraphicsFilter()
    let result = filter.filter(Data(text.utf8))
    return (String(decoding: result.output, as: UTF8.self), String(decoding: result.replies, as: UTF8.self))
}

@Suite("Kitty graphics filter")
struct KittyGraphicsFilterTests {
    @Test("direct transmission and everything else pass unchanged")
    func passes() {
        for text in [
            "plain text\r\n",
            "a\(esc)_Ga=T,f=100,i=3;iVBORw0KGgo=\(esc)\\b",
            "\(esc)_Ga=T,t=d,m=1;AAAA\(esc)\\\(esc)_Gm=0;BBBB\(esc)\\",
            "\(esc)_Ga=d,d=A\(esc)\\",
            "\(esc)_Xother\(esc)\\\(esc)[31mred\(esc)]0;title\u{07}",
            "\(esc)\(esc)[1m",
        ] {
            let result = run(text)
            #expect(result.output == text)
            #expect(result.replies.isEmpty)
        }
    }

    @Test("file, temporary file and shared memory transmission are dropped and answered")
    func blocksLocalMedia() {
        for medium in ["f", "t", "s"] {
            let result = run("a\(esc)_Ga=T,t=\(medium),i=5;L2V0Yy9wYXNzd2Q=\(esc)\\b")
            #expect(result.output == "ab")
            #expect(result.replies == "\(esc)_Gi=5;\(blocked)\(esc)\\")
        }
    }

    @Test("the answer carries only the command's numbers, and only when it wants one")
    func replies() {
        #expect(run("\(esc)_Gt=f,I=3,p=2;AA\(esc)\\").replies == "\(esc)_GI=3,p=2;\(blocked)\(esc)\\")
        #expect(run("\(esc)_Gt=f,i=5,q=2;AA\(esc)\\").replies.isEmpty)
        #expect(run("\(esc)_Gt=f;AA\(esc)\\").replies.isEmpty)
        #expect(run("\(esc)_Gt=f,i=x\(esc)[2J;AA\(esc)\\").replies.isEmpty)
    }

    @Test("the later chunks of a blocked transmission are dropped too")
    func chunks() {
        let result = run(
            "\(esc)_Gt=f,i=1,m=1;AAAA\(esc)\\\(esc)_Gm=1;BBBB\(esc)\\\(esc)_Gm=0;CCCC\(esc)\\z"
                + "\(esc)_Ga=T,i=2;DDDD\(esc)\\"
        )
        #expect(result.output == "z\(esc)_Ga=T,i=2;DDDD\(esc)\\")
        #expect(result.replies == "\(esc)_Gi=1;\(blocked)\(esc)\\")
    }

    @Test("a command split across reads is filtered the same")
    func split() {
        let text = "x\(esc)_Ga=T,t=f,i=9;L3RtcA==\(esc)\\y\(esc)_Ga=T,i=4;AAAA\(esc)\\z"
        var filter = KittyGraphicsFilter()
        var output = Data()
        var replies = Data()
        for byte in Data(text.utf8) {
            let result = filter.filter(Data([byte]))
            output.append(result.output)
            replies.append(result.replies)
        }
        let whole = run(text)
        #expect(String(decoding: output, as: UTF8.self) == whole.output)
        #expect(String(decoding: replies, as: UTF8.self) == whole.replies)
        #expect(whole.output == "xy\(esc)_Ga=T,i=4;AAAA\(esc)\\z")
    }

    @Test("over-long control data is dropped, an aborted command is not run")
    func malformed() {
        let long = String(repeating: "a", count: KittyGraphicsFilter.maxControlBytes + 10)
        #expect(run("\(esc)_G\(long);x\(esc)\\ok").output == "ok")
        #expect(run("\(esc)_Gt=f\u{18}ok").output == "\u{18}ok")
        #expect(run("\(esc)_Gt=f;AAAA\(esc)[31mred").output == "\(esc)[31mred")
    }
}
