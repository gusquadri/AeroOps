import Foundation
import Testing
@testable import BridgeProtocol

@Suite("Bridge wire messages")
struct BridgeMessagesTests {
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func requestRoundTripsAsOneLine() throws {
        let request = BridgeRequest(
            id: 7, tool: "get_logs",
            arguments: ["host": "web-1", "kind": "container", "name": "api", "tail": 100, "previous": false, "since": "15m"],
            client: BridgeClientInfo(name: "claude-code", version: "2.1.296"), toolUseId: "toolu_01")
        let line = try BridgeWire.line(.request(request))
        #expect(line.last == UInt8(ascii: "\n"))
        #expect(line.dropLast().contains(UInt8(ascii: "\n")) == false)
        #expect(try BridgeWire.decodeClientMessage(line.dropLast()) == .request(request))
        // The integer stays an integer on the wire.
        #expect(text(line).contains("\"tail\":100"))
    }

    @Test func requestWithoutOptionalFields() throws {
        let decoded = try BridgeWire.decodeClientMessage(Data(#"{"id":1,"tool":"list_hosts"}"#.utf8))
        #expect(decoded == .request(BridgeRequest(id: 1, tool: "list_hosts")))
        guard case .request(let request) = decoded else { return }
        #expect(request.arguments.isEmpty)
        #expect(request.client == nil)
        #expect(request.toolUseId == nil)
    }

    @Test func cancelRoundTrips() throws {
        let line = try BridgeWire.line(.cancel(id: 9))
        #expect(text(line) == "{\"cancel\":true,\"id\":9}\n")
        #expect(try BridgeWire.decodeClientMessage(line.dropLast()) == .cancel(id: 9))
    }

    @Test func replyAndProgressRoundTrip() throws {
        let success = BridgeReply.success(id: 3, content: [.text("line 1\nline 2")], structuredContent: ["count": 2])
        let failure = BridgeReply.failure(id: 4, .denied, "The user denied it.")
        let progress = BridgeProgress(id: 5, message: "Waiting for approval in AeroOps")
        for message in [BridgeServerMessage.reply(success), .reply(failure), .progress(progress)] {
            let line = try BridgeWire.line(message)
            #expect(line.dropLast().contains(UInt8(ascii: "\n")) == false, "newlines in text are escaped")
            #expect(try BridgeWire.decodeServerMessage(line.dropLast()) == message)
        }
        #expect(success.text == "line 1\nline 2")
        #expect(text(try BridgeWire.line(.reply(failure))) ==
            "{\"error\":{\"code\":\"denied\",\"message\":\"The user denied it.\"},\"id\":4,\"ok\":false}\n")
    }

    @Test func unknownErrorCodesSurvive() throws {
        let line = Data(#"{"id":2,"ok":false,"error":{"code":"from_the_future","message":"x"}}"#.utf8)
        guard case .reply(let reply) = try BridgeWire.decodeServerMessage(line) else {
            Issue.record("not a reply")
            return
        }
        #expect(reply.error?.code.rawValue == "from_the_future")
    }

    @Test func malformedClientLines() {
        #expect(throws: BridgeDecodingError(id: nil, reason: "not a JSON object with a numeric id")) {
            try BridgeWire.decodeClientMessage(Data("hello".utf8))
        }
        #expect(throws: BridgeDecodingError(id: nil, reason: "missing id")) {
            try BridgeWire.decodeClientMessage(Data(#"{"tool":"list_hosts"}"#.utf8))
        }
        #expect(throws: BridgeDecodingError(id: nil, reason: "not a JSON object with a numeric id")) {
            try BridgeWire.decodeClientMessage(Data(#"{"id":"7","tool":"list_hosts"}"#.utf8))
        }
        do {
            _ = try BridgeWire.decodeClientMessage(Data(#"{"id":7,"arguments":{}}"#.utf8))
            Issue.record("expected an error")
        } catch {
            #expect(error.id == 7)
            #expect(error.reason == "invalid request: missing tool")
        }
        do {
            _ = try BridgeWire.decodeClientMessage(Data(#"{"id":8,"tool":"x","arguments":[1]}"#.utf8))
            Issue.record("expected an error")
        } catch {
            #expect(error.id == 8)
            #expect(error.reason.hasPrefix("invalid request: bad value at arguments"))
        }
    }

    @Test func failedReplyNeedsAnError() {
        #expect(throws: BridgeDecodingError(id: 3, reason: "failed reply without an error")) {
            try BridgeWire.decodeServerMessage(Data(#"{"id":3,"ok":false}"#.utf8))
        }
    }

    @Test func jsonValueKeepsNumberKinds() throws {
        let value: JSONValue = ["a": 1, "b": 1.5, "c": [true, nil, "x"], "d": ["e": -3]]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(value.jsonString().utf8))
        #expect(decoded == value)
        #expect(JSONValue.double(100).intValue == 100)
        #expect(JSONValue.double(1.5).intValue == nil)
        #expect(value.jsonString() == #"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{"e":-3}}"#)
    }

    @Test func clientDisplayName() {
        #expect(BridgeClientInfo(name: "claude-code", version: "2.1").displayName == "claude-code 2.1")
        #expect(BridgeClientInfo(name: "inspector", version: "").displayName == "inspector")
    }
}
