import Foundation
import Testing
@testable import BridgeProtocol

@Suite("Line framer")
struct LineFramerTests {
    private func lines(_ events: [LineFramer.Event]) -> [String] {
        events.compactMap { event in
            if case .line(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }
    }

    @Test func splitsLinesAcrossChunks() {
        var framer = LineFramer(maxLineBytes: 100)
        #expect(framer.append(Data("{\"id\":1".utf8)).isEmpty)
        #expect(framer.bufferedByteCount == 7)
        #expect(lines(framer.append(Data("}\n{\"id\":2}\n{\"id\"".utf8))) == ["{\"id\":1}", "{\"id\":2}"])
        #expect(lines(framer.append(Data(":3}\n".utf8))) == ["{\"id\":3}"])
        #expect(framer.bufferedByteCount == 0)
    }

    @Test func skipsEmptyLinesAndCarriageReturns() {
        var framer = LineFramer(maxLineBytes: 100)
        #expect(lines(framer.append(Data("\n\r\na\r\n\nb\n".utf8))) == ["a", "b"])
    }

    @Test func lineAtTheLimitIsAccepted() {
        var framer = LineFramer(maxLineBytes: 5)
        #expect(framer.append(Data("12345\n".utf8)) == [.line(Data("12345".utf8))])
    }

    @Test func oversizedLineIsReportedOnceAndDiscarded() {
        var framer = LineFramer(maxLineBytes: 5)
        #expect(framer.append(Data("1234".utf8)).isEmpty)
        #expect(framer.append(Data("56".utf8)) == [.oversized(bytes: 6)])
        // The rest of the long line is dropped without buffering it.
        #expect(framer.append(Data(String(repeating: "x", count: 10_000).utf8)).isEmpty)
        #expect(framer.bufferedByteCount == 0)
        // The next line is fine again.
        #expect(framer.append(Data("yy\nok\n".utf8)) == [.line(Data("ok".utf8))])
    }

    @Test func oversizedInOneChunk() {
        var framer = LineFramer(maxLineBytes: 3)
        #expect(framer.append(Data("abcdef\nab\n".utf8)) == [.oversized(bytes: 6), .line(Data("ab".utf8))])
    }

    @Test func finishReturnsTheUnterminatedLine() {
        var framer = LineFramer(maxLineBytes: 10)
        _ = framer.append(Data("tail\r".utf8))
        #expect(framer.finish() == Data("tail".utf8))
        #expect(framer.finish() == nil)
        _ = framer.append(Data("0123456789AB".utf8))
        #expect(framer.finish() == nil, "an oversized line is not returned")
    }

    @Test func byteArrayInput() {
        var framer = LineFramer(maxLineBytes: 10)
        #expect(lines(framer.append(Array("x\ny\n".utf8))) == ["x", "y"])
    }
}
