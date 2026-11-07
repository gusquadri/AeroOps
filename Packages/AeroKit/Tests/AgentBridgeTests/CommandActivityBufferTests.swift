import Foundation
import Testing
@testable import AgentBridge

@Suite("Command activity buffer")
struct CommandActivityBufferTests {
    let a = UUID()
    let b = UUID()
    let hostID = UUID()

    func output(_ id: UUID, _ stream: CommandOutputChunk.Stream, _ text: String) -> CommandActivity {
        .output(id: id, CommandOutputChunk(stream: stream, data: Data(text.utf8)))
    }

    func command(_ id: UUID) -> RunningCommand {
        RunningCommand(id: id, hostID: hostID, hostName: "staging", command: "true", startedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func mergesConsecutiveOutputOfOneStream() {
        var buffer = CommandActivityBuffer()
        buffer.append(.started(command(a)))
        for piece in ["one\n", "two\n", "thr", "ee\n"] { buffer.append(output(a, .stdout, piece)) }
        #expect(buffer.drain() == [.started(command(a)), output(a, .stdout, "one\ntwo\nthree\n")])
    }

    @Test func keepsStdoutAndStderrInterleaved() {
        var buffer = CommandActivityBuffer()
        buffer.append(output(a, .stdout, "1"))
        buffer.append(output(a, .stdout, "2"))
        buffer.append(output(a, .stderr, "e"))
        buffer.append(output(a, .stdout, "3"))
        #expect(buffer.drain() == [output(a, .stdout, "12"), output(a, .stderr, "e"), output(a, .stdout, "3")])
    }

    @Test func mergesEachCommandApartAndKeepsArrivalOrder() {
        var buffer = CommandActivityBuffer()
        buffer.append(output(a, .stdout, "a1"))
        buffer.append(output(b, .stdout, "b1"))
        buffer.append(output(a, .stdout, "a2"))
        buffer.append(.cancelled(id: b, byUser: true))
        buffer.append(output(a, .stdout, "a3"))
        #expect(buffer.drain() == [output(a, .stdout, "a1a2a3"), output(b, .stdout, "b1"), .cancelled(id: b, byUser: true)])
    }

    @Test func neverMergesAcrossAnotherEventOfTheSameCommand() {
        var buffer = CommandActivityBuffer()
        buffer.append(output(a, .stdout, "before"))
        buffer.append(.failed(id: a, message: "boom"))
        buffer.append(output(a, .stdout, "after"))
        #expect(buffer.drain() == [output(a, .stdout, "before"), .failed(id: a, message: "boom"), output(a, .stdout, "after")])
    }

    @Test func drainEmptiesTheBuffer() {
        var buffer = CommandActivityBuffer()
        #expect(buffer.isEmpty)
        buffer.append(output(a, .stdout, "x"))
        #expect(!buffer.isEmpty)
        _ = buffer.drain()
        #expect(buffer.isEmpty)
        #expect(buffer.drain().isEmpty)
        buffer.append(output(a, .stdout, "y"))
        #expect(buffer.drain() == [output(a, .stdout, "y")])
    }
}
