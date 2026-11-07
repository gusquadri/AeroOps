import AeroCore
import BridgeProtocol
import Darwin
import Foundation
import Testing
@testable import AgentBridge

@Suite("Bridge server (socket)")
struct BridgeServerTests {
    /// A started server on `<temp>/run/bridge.sock`.
    final class Fixture: Sendable {
        let dir: TempDirectory
        let socketURL: URL
        let handler = ScriptedRequestHandler()
        let server: BridgeServer

        init(validator: any BridgePeerValidator = AcceptAllPeers(), maxConnections: Int = 32, start: Bool = true) throws {
            dir = try TempDirectory()
            socketURL = dir.appending("run/bridge.sock")
            server = BridgeServer(socketURL: socketURL, handler: handler, validator: validator, maxConnections: maxConnections)
            if start { try server.start() }
        }

        var path: String { socketURL.path(percentEncoded: false) }

        func client() throws -> BridgeTestClient { try BridgeTestClient(path: path) }

        deinit {
            server.stop()
            dir.remove()
        }
    }

    static func request(_ id: Int, _ tool: String, _ arguments: [String: JSONValue] = [:]) -> BridgeClientMessage {
        .request(BridgeRequest(id: id, tool: tool, arguments: arguments))
    }

    @Test func socketAndDirectoryArePrivateAndStopRemovesTheSocket() throws {
        let fixture = try Fixture()
        #expect(fixture.server.isRunning)
        #expect(fileMode(fixture.path).map { $0 & S_IFMT } == S_IFSOCK)
        #expect(fileMode(fixture.path).map { $0 & 0o777 } == 0o600)
        #expect(fileMode(fixture.socketURL.deletingLastPathComponent().path(percentEncoded: false)).map { $0 & 0o777 } == 0o700)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.socketURL.deletingLastPathComponent().path(percentEncoded: false))) == ["bridge.sock"])
        fixture.server.stop()
        #expect(!fixture.server.isRunning)
        #expect(fileMode(fixture.path) == nil)
    }

    @Test func looseDirectoryIsTightened() throws {
        let fixture = try Fixture(start: false)
        let directory = fixture.socketURL.deletingLastPathComponent().path(percentEncoded: false)
        mkdir(directory, 0o755)
        chmod(directory, 0o755)
        try fixture.server.start()
        #expect(fileMode(directory).map { $0 & 0o777 } == 0o700)
    }

    @Test func staleSocketIsReplacedButLiveOnesAndFilesAreNot() throws {
        let fixture = try Fixture()
        let second = BridgeServer(socketURL: fixture.socketURL, handler: fixture.handler, validator: AcceptAllPeers())
        #expect(throws: BridgeServerError.alreadyRunning(fixture.path)) { try second.start() }

        fixture.server.stop()
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(BridgeServerCore.withAddress(fixture.path) { bind(stale, $0, $1) } == 0)
        close(stale)
        #expect(fileMode(fixture.path).map { $0 & S_IFMT } == S_IFSOCK)
        try second.start()
        #expect(second.isRunning)
        let client = try BridgeTestClient(path: fixture.path)
        defer { client.close() }
        second.stop()

        FileManager.default.createFile(atPath: fixture.path, contents: Data("keep".utf8))
        #expect(throws: BridgeServerError.notASocket(fixture.path)) { try second.start() }
        #expect(FileManager.default.contents(atPath: fixture.path) == Data("keep".utf8))
    }

    @Test func stopDoesNotRemoveAnotherServersSocket() throws {
        let fixture = try Fixture()
        unlink(fixture.path)
        let other = BridgeServer(socketURL: fixture.socketURL, handler: fixture.handler, validator: AcceptAllPeers())
        try other.start()
        defer { other.stop() }
        fixture.server.stop()
        #expect(fileMode(fixture.path).map { $0 & S_IFMT } == S_IFSOCK, "the other server's socket survived")
    }

    @Test func pathTooLongIsRefused() {
        let long = URL(filePath: "/tmp/" + String(repeating: "x", count: 120) + "/bridge.sock")
        let server = BridgeServer(socketURL: long, handler: ScriptedRequestHandler(), validator: AcceptAllPeers())
        #expect(throws: BridgeServerError.socketPathTooLong(long.path(percentEncoded: false))) { try server.start() }
    }

    @Test func requestsRunConcurrently() async throws {
        let fixture = try Fixture()
        let client = try fixture.client()
        defer { client.close() }
        client.send(Self.request(1, "sleep", ["ms": 400]))
        client.send(Self.request(2, "echo", ["text": "fast"]))
        let fast = await client.waitForReply(2)
        #expect(fast?.text == "fast")
        #expect(client.reply(for: 1) == nil, "the slow call did not block the fast one")
        #expect(await client.waitForReply(1)?.text == "slept")
        #expect(client.replies.map(\.id) == [2, 1])
    }

    @Test func cancelStopsTheCallWithoutAReplyAndKeepsTheConnection() async throws {
        let fixture = try Fixture()
        let client = try fixture.client()
        defer { client.close() }
        client.send(Self.request(5, "wait"))
        #expect(await eventually { client.progress(for: 5) == ["waiting"] })
        client.send(.cancel(id: 5))
        #expect(await eventually { fixture.handler.cancelled == [5] })
        client.send(Self.request(6, "echo", ["text": "still here"]))
        #expect(await client.waitForReply(6)?.text == "still here")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.reply(for: 5) == nil, "a cancelled call gets no reply")
        client.send(.cancel(id: 99))
        client.send(Self.request(5, "echo", ["text": "again"]))
        #expect(await client.waitForReply(5)?.text == "again")
    }

    @Test func droppedConnectionCancelsEverything() async throws {
        let fixture = try Fixture()
        let events = fixture.server.events()
        let client = try fixture.client()
        for id in 1...3 { client.send(Self.request(id, "wait")) }
        #expect(await eventually { fixture.handler.started.count == 3 })
        #expect(fixture.server.connectionCount == 1)
        client.close()
        #expect(await eventually { Set(fixture.handler.cancelled) == [1, 2, 3] })
        #expect(await eventually { fixture.server.connectionCount == 0 })
        var kinds: [BridgeServerEvent.Kind] = []
        for await event in events {
            kinds.append(event.kind)
            if event.kind == .disconnected { break }
        }
        #expect(kinds.count == 2)
        if case .connected(let peer) = kinds.first {
            #expect(peer.uid == getuid())
            #expect(peer.pid == getpid(), "the peer is this test process")
        } else {
            Issue.record("expected a connected event, got \(kinds)")
        }
    }

    @Test func stopCancelsCallsAndClosesConnections() async throws {
        let fixture = try Fixture()
        let client = try fixture.client()
        defer { client.close() }
        client.send(Self.request(1, "wait"))
        #expect(await eventually { fixture.handler.started == [1] })
        fixture.server.stop()
        #expect(await eventually { fixture.handler.cancelled == [1] })
        #expect(await eventually { client.isClosedByServer })
        #expect(fixture.server.connectionCount == 0)
    }

    @Test func malformedLines() async throws {
        let fixture = try Fixture()
        let client = try fixture.client()
        defer { client.close() }
        client.sendRaw(Data(#"{"type":"request","id":7,"tool":42}"#.utf8 + [0x0A]))
        let reply = await client.waitForReply(7)
        #expect(reply?.error?.code == .malformedRequest)
        #expect(reply?.error?.message.hasPrefix("Malformed request: ") == true)
        client.send(Self.request(8, "echo", ["text": "ok"]))
        #expect(await client.waitForReply(8)?.text == "ok")

        let garbage = try fixture.client()
        defer { garbage.close() }
        garbage.sendRaw(Data("this is not json\n".utf8))
        let fatal = await garbage.waitForReply(0)
        #expect(fatal?.error?.code == .malformedRequest)
        #expect(await eventually { garbage.isClosedByServer })
    }

    @Test func nonPositiveIdsAndDuplicateIds() async throws {
        let fixture = try Fixture()
        let client = try fixture.client()
        defer { client.close() }
        client.send(Self.request(3, "wait"))
        #expect(await eventually { fixture.handler.started == [3] })
        client.send(Self.request(3, "echo", ["text": "dup"]))
        let duplicate = await client.waitForReply(3)
        #expect(duplicate?.error?.code == .malformedRequest)
        #expect(duplicate?.error?.message == "Request id 3 is already in flight on this connection.")

        let negative = try fixture.client()
        defer { negative.close() }
        negative.send(Self.request(-1, "echo"))
        let fatal = await negative.waitForReply(0)
        #expect(fatal?.error?.message == "Request ids must be positive (got -1).")
        #expect(await eventually { negative.isClosedByServer })
    }

    @Test func tooManyCallsInFlight() async throws {
        let fixture = try Fixture()
        let client = try fixture.client()
        defer { client.close() }
        let limit = BridgeLimits.maxConcurrentRequestsPerConnection
        for id in 1...limit { client.send(Self.request(id, "wait")) }
        #expect(await eventually { fixture.handler.started.count == limit })
        client.send(Self.request(limit + 1, "echo", ["text": "one too many"]))
        #expect(await client.waitForReply(limit + 1)?.error?.code == .busy)
        client.send(.cancel(id: 1))
        client.send(Self.request(limit + 2, "echo", ["text": "room again"]))
        #expect(await client.waitForReply(limit + 2)?.text == "room again")
    }

    @Test func tooManyConnections() async throws {
        let fixture = try Fixture(maxConnections: 1)
        let first = try fixture.client()
        defer { first.close() }
        #expect(await eventually { fixture.server.connectionCount == 1 })
        let second = try fixture.client()
        defer { second.close() }
        #expect(await second.waitForReply(0)?.error?.code == .busy)
        #expect(await eventually { second.isClosedByServer })
    }

    @Test func rejectedPeerGetsAnIdZeroErrorAndIsClosed() async throws {
        let fixture = try Fixture(validator: RejectAllPeers())
        let client = try fixture.client()
        defer { client.close() }
        client.send(Self.request(1, "echo", ["text": "hi"]))
        let reply = await client.waitForReply(0)
        #expect(reply?.error?.code == .peerRejected)
        #expect(reply?.error?.message == "AeroOps refused the connection: test says no.")
        #expect(await eventually { client.isClosedByServer })
        #expect(fixture.handler.started.isEmpty)
    }

    @Test func oversizedLineClosesTheConnection() async throws {
        let fixture = try Fixture()
        let client = try fixture.client()
        defer { client.close() }
        _ = client.sendRaw(Data(repeating: UInt8(ascii: "x"), count: BridgeLimits.maxRequestLineBytes + 10))
        let reply = await client.waitForReply(0)
        #expect(reply?.error?.code == .malformedRequest)
        #expect(await eventually { client.isClosedByServer })
    }

    /// A peer that connected and hung up before the accept: XNU refuses `SO_NOSIGPIPE` on that
    /// socket, so the server must drop it instead of writing to it (that write raised SIGPIPE
    /// and killed the test runner, or the app).
    @Test func peerThatHungUpBeforeAcceptIsDropped() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let path = dir.appending("s.sock").path(percentEncoded: false)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        try #require(BridgeServerCore.withAddress(path) { bind(listener, $0, $1) } == 0)
        try #require(listen(listener, 4) == 0)

        func acceptPeer(hangUp: Bool) throws -> (peer: Int32, accepted: Int32) {
            let peer = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(peer >= 0)
            try #require(BridgeServerCore.withAddress(path) { connect(peer, $0, $1) } == 0)
            if hangUp { close(peer) }
            let accepted = accept(listener, nil, nil)
            try #require(accepted >= 0)
            return (hangUp ? -1 : peer, accepted)
        }

        let gone = try acceptPeer(hangUp: true)
        defer { close(gone.accepted) }
        #expect(!BridgeServerCore.prepareAccepted(gone.accepted))

        let live = try acceptPeer(hangUp: false)
        defer { close(live.peer); close(live.accepted) }
        #expect(BridgeServerCore.prepareAccepted(live.accepted))
        var noSigPipe: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(live.accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &length) == 0 && noSigPipe != 0)
    }
}
