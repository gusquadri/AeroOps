import Foundation
import Testing
@testable import KeyAgent

@Suite("Agent socket server")
struct AgentServerTests {
    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode : nil
    }

    private func makeServer(_ dir: TempDirectory, socket: String = "agent/agent.sock", appProcessID: pid_t = getpid(), maxConnections: Int = 64) throws -> (SSHAgentServer, KeyStore) {
        let store = try makeKeyStore(dir)
        let server = SSHAgentServer(
            socketURL: dir.appending(socket), keyStore: store, authorizer: RecordingAuthorizer(),
            appProcessID: appProcessID, maxConnections: maxConnections)
        return (server, store)
    }

    @Test func startCreatesPrivateSocketAndStopRemovesIt() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, _) = try makeServer(dir)
        try await server.start()
        #expect(await server.isRunning)
        let socketMode = try #require(mode(server.socketURL.path))
        #expect(socketMode & S_IFMT == S_IFSOCK)
        #expect(socketMode & 0o777 == 0o600)
        #expect(mode(dir.appending("agent").path).map { $0 & 0o777 } == 0o700)
        // Only the socket is left in the directory: the temporary bind name was renamed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appending("agent").path) == ["agent.sock"])

        try await server.start() // already running: no-op
        await server.stop()
        #expect(await !server.isRunning)
        #expect(mode(server.socketURL.path) == nil)
        try await server.start() // restartable
        #expect(mode(server.socketURL.path) != nil)
        await server.stop()
    }

    @Test func replacesAStaleSocket() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        // What a crashed agent leaves behind: a bound socket file nobody listens on.
        try FileManager.default.createDirectory(at: dir.appending("agent"), withIntermediateDirectories: false)
        let path = dir.appending("agent/agent.sock").path
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        #expect(bound == 0)
        #expect(mode(path).map { $0 & S_IFMT } == S_IFSOCK)

        let (server, store) = try makeServer(dir)
        _ = try await store.generate(.ed25519, name: "k")
        try await server.start()
        let client = try AgentTestClient(path: path)
        defer { client.close() }
        #expect(try parseIdentities(#require(await client.request([AgentMessage.requestIdentities]))).count == 1)
        await server.stop()
    }

    @Test func refusesToReplaceALiveAgent() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (first, _) = try makeServer(dir)
        try await first.start()
        let (second, _) = try makeServer(dir)
        await #expect(throws: AgentServerError.alreadyRunning(first.socketURL.path)) { try await second.start() }
        #expect(await first.isRunning)
        let client = try AgentTestClient(path: first.socketURL.path)
        defer { client.close() }
        #expect(await client.request([AgentMessage.requestIdentities]) != nil)
        await first.stop()
    }

    @Test func refusesUnsafePaths() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        // A regular file where the socket should be.
        try FileManager.default.createDirectory(at: dir.appending("agent"), withIntermediateDirectories: false)
        try Data("x".utf8).write(to: dir.appending("agent/agent.sock"))
        let (server, _) = try makeServer(dir)
        await #expect(throws: AgentServerError.notASocket(server.socketURL.path)) { try await server.start() }
        #expect(FileManager.default.fileExists(atPath: server.socketURL.path))

        // A file where the directory should be.
        try Data("x".utf8).write(to: dir.appending("file"))
        let (inFile, _) = try makeServer(dir, socket: "file/agent.sock")
        await #expect(throws: AgentServerError.insecureDirectory(dir.appending("file").path)) { try await inFile.start() }

        // sun_path holds 104 bytes.
        let (tooLong, _) = try makeServer(dir, socket: String(repeating: "x", count: 100) + ".sock")
        do {
            try await tooLong.start()
            Issue.record("a 100+ byte socket path was accepted")
        } catch {
            guard case .socketPathTooLong = error else { Issue.record("unexpected \(error)"); return }
        }
    }

    @Test func tightensAnOpenDirectory() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.appending("agent"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let (server, _) = try makeServer(dir)
        try await server.start()
        #expect(mode(dir.appending("agent").path).map { $0 & 0o777 } == 0o700)
        await server.stop()
    }

    @Test func stopLeavesAReplacedSocketPathAlone() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, _) = try makeServer(dir)
        try await server.start()
        unlink(server.socketURL.path)
        try Data("someone else".utf8).write(to: server.socketURL)
        await server.stop()
        #expect(FileManager.default.fileExists(atPath: server.socketURL.path))
    }

    @Test func servesRequestsAndReportsThePeer() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        // The test process is its own peer; naming its parent as "the app" makes it "started by the app".
        let (server, store) = try makeServer(dir, appProcessID: getppid())
        let recorder = EventRecorder(server.events)
        defer { recorder.stop() }
        let record = try await store.generate(.ed25519, name: "Server key")
        try await server.start()

        let client = try AgentTestClient(path: server.socketURL.path)
        let identities = try parseIdentities(#require(await client.request([AgentMessage.requestIdentities])))
        #expect(identities.map(\.blob) == [Array(record.publicKeyBlob)])
        // Mutations are refused and the connection stays usable.
        #expect(await client.request([AgentMessage.removeAllIdentities]) == [AgentMessage.failure])
        #expect(await client.request([AgentMessage.addIdentity, 0, 0, 0, 0]) == [AgentMessage.failure])
        let data = Array("over the socket".utf8)
        let reply = try #require(await client.request(signRequestMessage(keyBlob: Array(record.publicKeyBlob), data: data, flags: 0)))
        #expect(SignatureVerifier.verify(signatureBlob: try parseSignResponse(reply), publicKeyBlob: Array(record.publicKeyBlob), data: data))
        #expect(await store.keys.count == 1)
        client.close()

        #expect(await recorder.wait { $0.contains(.disconnected) })
        let events = recorder.all
        guard case .connected(let peer) = events.first else {
            Issue.record("first event: \(String(describing: events.first))")
            return
        }
        #expect(peer.pid == getpid())
        #expect(peer.uid == getuid())
        #expect(peer.parentPID == getppid())
        #expect(peer.startedByApp)
        #expect(!peer.isAppleSSH)
        #expect(!peer.isTrustedAppSSH)
        #expect(peer.executablePath != nil)
        #expect(events.contains(.identitiesListed(count: 1)))
        #expect(events.contains(.refused(request: "REMOVE_ALL_IDENTITIES")))
        #expect(events.contains(.refused(request: "ADD_IDENTITY")))
        #expect(events.contains { if case .signed(record.id, _, "ssh-ed25519", _, _) = $0 { true } else { false } })
        await server.stop()
    }

    @Test func peerIsNotStartedByAppWhenTheAppIsItself() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, _) = try makeServer(dir) // appProcessID = getpid(): the peer's ancestors exclude itself
        let recorder = EventRecorder(server.events)
        defer { recorder.stop() }
        try await server.start()
        let client = try AgentTestClient(path: server.socketURL.path)
        _ = await client.request([AgentMessage.requestIdentities])
        client.close()
        #expect(await recorder.wait { $0.contains(.disconnected) })
        guard case .connected(let peer) = recorder.all.first else { Issue.record("no connected event"); return }
        #expect(!peer.startedByApp)
        await server.stop()
    }

    @Test func oversizedFramesCloseTheConnection() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, _) = try makeServer(dir)
        try await server.start()
        let client = try AgentTestClient(path: server.socketURL.path)
        defer { client.close() }
        let length = UInt32(AgentMessage.maxLength + 1)
        let header = [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        #expect(await client.sendRaw(header + [AgentMessage.requestIdentities]) == nil)
        await server.stop()
    }

    @Test func limitsConnectionsAndStopClosesThem() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, _) = try makeServer(dir, maxConnections: 1)
        let recorder = EventRecorder(server.events)
        defer { recorder.stop() }
        try await server.start()
        let first = try AgentTestClient(path: server.socketURL.path)
        defer { first.close() }
        #expect(await first.request([AgentMessage.requestIdentities]) != nil)
        let second = try AgentTestClient(path: server.socketURL.path)
        defer { second.close() }
        #expect(await second.request([AgentMessage.requestIdentities]) == nil)
        #expect(await recorder.wait { $0.contains(.rejected(reason: "too many connections")) })

        await server.stop()
        #expect(await first.request([AgentMessage.requestIdentities]) == nil)
        #expect(await recorder.wait { $0.contains(.disconnected) })
    }

    @Test func framesRoundTripOverASocketPair() async throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { close($0) } }
        let payload = [UInt8](repeating: 0xAB, count: 70_000)
        let (a, b) = (fds[0], fds[1])
        let writer = Thread { _ = AgentServerCore.writeAll(a, SSHWriter.frame(payload) + [0, 0, 0, 0]) }
        writer.start()
        #expect(AgentServerCore.readFrame(b) == payload)
        #expect(AgentServerCore.readFrame(b) == nil) // a zero-length frame is invalid
    }
}
