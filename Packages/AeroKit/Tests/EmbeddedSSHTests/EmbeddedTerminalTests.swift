import AeroCore
import Foundation
import Synchronization
import Testing
@testable import EmbeddedSSH
@testable import EmbeddedTerminal
@testable import SSHKit

/// ``EmbeddedTerminalSession`` against ``TestSSHServer``'s scripted shell, which echoes what it
/// gets and exits with status 7 on `exit`. No surface is attached, so the output stays queued
/// in the in-memory session.
@MainActor
@Suite("EmbeddedTerminal sessions")
struct EmbeddedTerminalTests {
    private struct Fixture {
        let env: TestEnvironment
        let server: TestSSHServer
        let host: RemoteHost
        let client: EmbeddedSSHClient

        init() async throws {
            env = try TestEnvironment()
            server = try await TestSSHServer()
            host = try await server.host(in: env)
            client = env.client()
        }

        @MainActor func session() -> EmbeddedTerminalSession {
            let (client, host) = (client, host)
            return EmbeddedTerminalSession { size in
                try await client.openTerminal(on: host, term: EmbeddedTerminalSession.term, size: size)
            }
        }

        func tearDown() async {
            await client.disconnectAll()
            await server.close()
        }
    }

    private func waitFor(_ session: EmbeddedTerminalSession, _ isDone: (EmbeddedTerminalSession.State) -> Bool) async throws {
        try await waitFor("still \(session.state)") { isDone(session.state) }
    }

    private func waitFor(_ failure: @autoclosure () -> String = "timed out", _ isDone: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !isDone() {
            guard ContinuousClock.now < deadline else {
                Issue.record(Comment(rawValue: failure()))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Keys typed while it opens are sent, the size follows the surface, the shell's exit ends it and its surface")
    func shell() async throws {
        let fixture = try await Fixture()
        let session = fixture.session()
        session.connect()
        #expect(session.state == .connecting)
        let link = try #require(session.link)
        link.write(Data("ls\r".utf8))
        link.resize(PseudoTerminalSize(columns: 120, rows: 40, pixelWidth: 960, pixelHeight: 800))
        try await waitFor(session) { $0 == .running }

        let terminal = try #require(fixture.server.log.terminals.first)
        #expect(terminal.term == "xterm-256color")
        #expect(terminal.size == EmbeddedTerminalSession.initialSize)
        link.resize(PseudoTerminalSize(columns: 120, rows: 40, pixelWidth: 960, pixelHeight: 800))
        link.resize(PseudoTerminalSize(columns: 100, rows: 30))
        link.write(Data("exit\r".utf8))
        try await waitFor(session) { $0.isOver }
        #expect(session.state == .ended(exitStatus: 7))
        #expect(fixture.server.log.windowChanges == [
            PseudoTerminalSize(columns: 120, rows: 40, pixelWidth: 960, pixelHeight: 800),
            PseudoTerminalSize(columns: 100, rows: 30),
        ])
        #expect(session.io?.pendingOutputByteCount == "$ ls\rexit\r".utf8.count)
        #expect(session.surface == .finished)

        session.connect()
        #expect(session.connection == 2)
        #expect(session.state == .connecting)
        try await waitFor(session) { $0 == .running }
        await fixture.tearDown()
    }

    @Test("A dropped connection shows as disconnected and drops keys; reconnect opens a new shell in the same surface at the last size")
    func reconnect() async throws {
        let fixture = try await Fixture()
        let session = fixture.session()
        session.connect()
        try await waitFor(session) { $0 == .running }
        let first = session.connection
        session.link?.resize(PseudoTerminalSize(columns: 90, rows: 20))
        session.connect()
        #expect(session.connection == first)

        await fixture.client.disconnect(fixture.host.id)
        try await waitFor(session) { $0.isOver }
        #expect(session.state == .disconnected)
        #expect(session.surface == .used)
        let io = try #require(session.io)
        let shown = io.pendingOutputByteCount
        session.link?.write(Data("lost\r".utf8))

        session.reconnect()
        #expect(session.connection == first)
        #expect(session.state == .reconnecting)
        try await waitFor(session) { $0 == .running }
        #expect(session.io === io)
        let expected = shown + EmbeddedTerminalSession.reconnectedNote.count + "$ ".utf8.count
        try await waitFor { io.pendingOutputByteCount >= expected }
        try await Task.sleep(for: .milliseconds(100))
        #expect(io.pendingOutputByteCount == expected)
        #expect(fixture.server.log.terminals.map(\.size) == [
            EmbeddedTerminalSession.initialSize, PseudoTerminalSize(columns: 90, rows: 20),
        ])
        session.close()
        #expect(session.state == .disconnected)
        session.link?.write(Data("exit\r".utf8))
        await fixture.tearDown()
    }

    @Test("An unknown host key fails the session; after trusting, reconnect runs")
    func hostKey() async throws {
        let fixture = try await Fixture()
        try await fixture.env.hostKeys.forget(fixture.host)
        let session = fixture.session()
        session.connect()
        try await waitFor(session) { $0.isOver }
        #expect(session.state == .failed(.hostKeyUnknown))

        try await fixture.env.hostKeys.trust(fixture.server.hostKey, for: fixture.host)
        session.reconnect()
        #expect(session.state == .connecting)
        try await waitFor(session) { $0 == .running }
        await fixture.tearDown()
    }

    @Test("Coming back, a dropped terminal and one whose server stopped answering reconnect in place")
    func resume() async throws {
        let fixture = try await Fixture()
        let session = fixture.session()
        session.connect()
        try await waitFor(session) { $0 == .running }
        let io = try #require(session.io)

        await session.resume()
        #expect(session.state == .running)
        #expect(fixture.server.log.terminals.count == 1)

        await fixture.server.stopAnswering()
        await session.resume(probeTimeout: .milliseconds(300))
        #expect(session.state == .reconnecting)
        try await waitFor(session) { $0 == .running }
        #expect(fixture.server.log.terminals.count == 2)

        await fixture.client.disconnect(fixture.host.id)
        try await waitFor(session) { $0 == .disconnected }
        await session.resume()
        try await waitFor(session) { $0 == .running }
        #expect(fixture.server.log.terminals.count == 3)
        #expect(session.io === io)
        #expect(session.connection == 1)
        await fixture.tearDown()
    }

    @Test("Errors from the opener become SSHError and are not retried on resume; closing while it opens drops the late channel")
    func openerErrors() async throws {
        let attempts = Counter()
        let failing = EmbeddedTerminalSession { _ in
            attempts.increment()
            throw SSHError.authFailed
        }
        failing.connect()
        try await waitFor(failing) { $0.isOver }
        #expect(failing.state == .failed(.authFailed))
        await failing.resume()
        #expect(failing.state == .failed(.authFailed))
        #expect(attempts.value == 1)

        let channel = FakeChannel()
        let slow = EmbeddedTerminalSession { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return channel
        }
        slow.connect()
        slow.close()
        #expect(slow.state == .disconnected)
        try await Task.sleep(for: .milliseconds(400))
        #expect(channel.isClosed)
        #expect(slow.state == .disconnected)
    }
}

/// A channel that never says anything; records whether it was closed.
private final class FakeChannel: TerminalChannel {
    private let stream = AsyncStream<Data>.makeStream()
    private let closed = Mutex(false)

    var incoming: AsyncStream<Data> { stream.stream }
    var exitStatus: Int32? { nil }
    var isClosed: Bool { closed.withLock { $0 } }

    func send(_ data: Data) {}
    func resize(_ size: PseudoTerminalSize) {}
    func closeInput() {}

    func close() {
        closed.withLock { $0 = true }
        stream.continuation.finish()
    }

    func waitForEnd() async -> SSHError? { nil }

    func isResponsive(within timeout: Duration) async -> Bool { true }
}
