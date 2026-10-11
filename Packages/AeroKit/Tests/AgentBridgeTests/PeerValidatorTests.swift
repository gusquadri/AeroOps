import AeroCore
import BridgeProtocol
import Darwin
import Foundation
import Testing
@testable import AgentBridge

/// The real code-signature check against real peers on a temp socket.
@Suite("Peer validation")
struct PeerValidatorTests {
    static let team = "VUDQQS32NW"

    @Test func requirementString() {
        let strict = CodeSignaturePeerValidator(team: .explicit(Self.team))
        #expect(strict.teamIdentifier == Self.team)
        #expect(strict.requirement == #"anchor apple generic and certificate leaf[subject.OU] = "VUDQQS32NW" and identifier "app.aeroops.mcp""#)
        let anyTool = CodeSignaturePeerValidator(team: .explicit(Self.team), requiredIdentifier: nil)
        #expect(anyTool.requirement == #"anchor apple generic and certificate leaf[subject.OU] = "VUDQQS32NW""#)
    }

    @Test(arguments: ["", "vudqqs32nw", "VUDQQS32N", #"VUDQQS32NW" or anchor apple"#, "VUDQQS32NW\n"])
    func malformedTeamRejectsEveryone(_ team: String) throws {
        let validator = CodeSignaturePeerValidator(team: .explicit(team))
        #expect(validator.teamIdentifier == nil && validator.requirement == nil)
        let (server, dir) = try Self.start(validator)
        defer { server.stop(); dir.remove() }
        let client = try BridgeTestClient(path: server.socketURL.path(percentEncoded: false))
        defer { client.close() }
        let rejected = Self.waitForRejection(client)
        #expect(rejected?.contains("AeroOps has no team ID") == true, "\(rejected ?? "-")")
    }

    @Test func injectedIdentifierIsDropped() {
        let validator = CodeSignaturePeerValidator(team: .explicit(Self.team), requiredIdentifier: #"x" or anchor apple"#)
        #expect(validator.requiredIdentifier == nil)
        #expect(validator.requirement?.contains("or anchor") == false)
    }

    @Test("An unsigned-by-our-team peer (this test process) is rejected")
    func inProcessClientIsRejected() throws {
        let (server, dir) = try Self.start(CodeSignaturePeerValidator(team: .explicit(Self.team)))
        defer { server.stop(); dir.remove() }
        let client = try BridgeTestClient(path: server.socketURL.path(percentEncoded: false))
        defer { client.close() }
        let rejected = Self.waitForRejection(client)
        #expect(rejected?.hasPrefix("AeroOps refused the connection: peer pid \(getpid())") == true, "\(rejected ?? "-")")
        #expect(rejected?.contains("does not satisfy the requirement") == true)
    }

    @Test("/usr/bin/nc (Apple-signed, no team) is rejected")
    func netcatIsRejected() async throws {
        let (server, dir) = try Self.start(CodeSignaturePeerValidator(team: .explicit(Self.team)))
        defer { server.stop(); dir.remove() }
        let events = server.events()
        let result = try await LocalProcess.run("/usr/bin/nc", ["-w", "5", "-U", server.socketURL.path(percentEncoded: false)])
        let line = try #require(result.stdout.split(separator: "\n").first, "nc printed nothing: \(result.stdout)")
        let reply = try BridgeWire.decodeServerMessage(Data(line.utf8))
        guard case .reply(let failure) = reply else {
            Issue.record("expected a reply, got \(reply)")
            return
        }
        #expect(failure.id == 0 && failure.error?.code == .peerRejected)
        #expect(failure.error?.message.contains("com.apple.nc") == true, "\(failure.error?.message ?? "-")")
        for await event in events {
            if case .rejected(let reason) = event.kind {
                #expect(reason.contains("does not satisfy the requirement"))
                break
            }
        }
    }

    #if DEBUG
    @Test func developmentOverrideAcceptsAndSaysSo() async throws {
        let (server, dir) = try Self.start(UnsignedDevelopmentPeerValidator(reason: "unit test"))
        defer { server.stop(); dir.remove() }
        let events = server.events()
        let client = try BridgeTestClient(path: server.socketURL.path(percentEncoded: false))
        defer { client.close() }
        client.send(.request(BridgeRequest(id: 1, tool: "echo", arguments: ["text": "hi"])))
        #expect(await client.waitForReply(1)?.text == "hi")
        for await event in events {
            if case .connected(let peer) = event.kind {
                #expect(peer.trust == .unsignedDevelopmentOverride)
                #expect(peer.pid == getpid() && peer.uid == getuid())
                break
            }
        }
    }

    @Test func forAppOnlyRelaxesWhenAskedAndUnsigned() {
        let strict = CodeSignaturePeerValidator.forApp()
        #expect(strict is CodeSignaturePeerValidator)
        let relaxed = CodeSignaturePeerValidator.forApp(allowUnsignedPeersInDebug: true)
        if CodeSignaturePeerValidator.ownTeamIdentifier() == nil {
            #expect(relaxed is UnsignedDevelopmentPeerValidator)
        } else {
            #expect(relaxed is CodeSignaturePeerValidator, "a signed app always checks signatures")
        }
    }
    #endif

    // MARK: Helpers

    static func start(_ validator: any BridgePeerValidator) throws -> (BridgeServer, TempDirectory) {
        let dir = try TempDirectory()
        let server = BridgeServer(socketURL: dir.appending("bridge.sock"), handler: ScriptedRequestHandler(), validator: validator)
        try server.start()
        return (server, dir)
    }

    /// The id-0 rejection message, once the server closed the connection.
    static func waitForRejection(_ client: BridgeTestClient) -> String? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !client.isClosedByServer { usleep(10_000) }
        guard let reply = client.reply(for: 0), reply.error?.code == .peerRejected else { return nil }
        return reply.error?.message
    }
}
