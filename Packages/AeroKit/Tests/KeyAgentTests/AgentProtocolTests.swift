import CryptoKit
import Foundation
import Testing
@testable import KeyAgent

@Suite("Agent protocol")
struct AgentProtocolTests {
    /// A store with Ed25519, imported ECDSA P-256 and imported RSA keys, plus a handler.
    private struct Fixture {
        let dir: TempDirectory
        let store: KeyStore
        let authorizer: RecordingAuthorizer
        let handler: AgentRequestHandler
        let ed25519: SSHKeyRecord
        let ecdsa: SSHKeyRecord
        let rsa: SSHKeyRecord

        init(decision: SigningDecision = .allow) async throws {
            dir = try TempDirectory()
            store = try makeKeyStore(dir)
            authorizer = RecordingAuthorizer(decision)
            handler = AgentRequestHandler(keyStore: store, authorizer: authorizer)
            ed25519 = try await store.generate(.ed25519, name: "ed", policy: .always)
            ecdsa = try await store.importOpenSSHPrivateKey(try await GeneratedOpenSSHKey.make(type: "ecdsa", bits: 256, comment: "ec", in: dir).privateKeyText)
            rsa = try await store.importOpenSSHPrivateKey(try await GeneratedOpenSSHKey.make(type: "rsa", bits: 2048, comment: "rsa", in: dir).privateKeyText)
        }

        func state(peer: PeerIdentity = .trustedSSH) -> AgentConnectionState {
            AgentConnectionState(connectionID: 7, peer: peer)
        }
    }

    @Test func requestIdentitiesListsEveryKey() async throws {
        let f = try await Fixture()
        defer { f.dir.remove() }
        var state = f.state()
        let (reply, events) = await f.handler.handle([AgentMessage.requestIdentities], state: &state)
        let identities = try parseIdentities(reply)
        #expect(identities.map(\.blob) == [f.ed25519, f.ecdsa, f.rsa].map { Array($0.publicKeyBlob) })
        #expect(identities.map(\.comment) == ["ed", "ec", "rsa"])
        #expect(events == [.identitiesListed(count: 3)])
    }

    @Test func signsWithEachKeyType() async throws {
        let f = try await Fixture()
        defer { f.dir.remove() }
        let data = Array("to be signed".utf8)
        for (record, flags, expected) in [(f.ed25519, UInt32(0), "ssh-ed25519"), (f.ecdsa, 0, "ecdsa-sha2-nistp256"), (f.rsa, 2, "rsa-sha2-256"), (f.rsa, 4, "rsa-sha2-512"), (f.rsa, 6, "rsa-sha2-512")] {
            var state = f.state()
            let (reply, events) = await f.handler.handle(signRequestMessage(keyBlob: Array(record.publicKeyBlob), data: data, flags: flags), state: &state)
            let signature = try parseSignResponse(reply)
            #expect(signatureAlgorithm(signature) == expected)
            #expect(SignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: Array(record.publicKeyBlob), data: data))
            guard case .signed(let keyID, _, let algorithm, _, _) = events.first else {
                Issue.record("no signed event")
                continue
            }
            #expect(keyID == record.id)
            #expect(algorithm == expected)
        }
        #expect(f.authorizer.requests.count == 5)
    }

    @Test func refusesSHA1RSABeforeAskingTheAuthorizer() async throws {
        let f = try await Fixture()
        defer { f.dir.remove() }
        for flags: UInt32 in [0, 1, 8] {
            var state = f.state()
            let (reply, events) = await f.handler.handle(signRequestMessage(keyBlob: Array(f.rsa.publicKeyBlob), data: [1], flags: flags), state: &state)
            #expect(reply == [AgentMessage.failure])
            guard case .signFailed(let keyID, _) = events.first else { Issue.record("expected signFailed"); continue }
            #expect(keyID == f.rsa.id)
        }
        #expect(f.authorizer.requests.isEmpty)
    }

    @Test(arguments: [
        AgentMessage.addIdentity, AgentMessage.removeIdentity, AgentMessage.removeAllIdentities,
        AgentMessage.addSmartcardKey, AgentMessage.removeSmartcardKey, AgentMessage.lock, AgentMessage.unlock,
        AgentMessage.addIdentityConstrained, AgentMessage.addSmartcardKeyConstrained, 1, 9, 99, 255,
    ])
    func refusesMutationsAndUnknownTypes(type: UInt8) async throws {
        let f = try await Fixture()
        defer { f.dir.remove() }
        var state = f.state()
        let (reply, events) = await f.handler.handle([type, 0, 0, 0, 0], state: &state)
        #expect(reply == [AgentMessage.failure])
        #expect(events == [.refused(request: AgentMessage.name(type))])
        #expect(await f.store.keys.count == 3)
    }

    @Test func failsCleanlyOnBadRequests() async throws {
        let f = try await Fixture()
        defer { f.dir.remove() }
        var state = f.state()
        // Empty, truncated, and an unknown key.
        let empty = await f.handler.handle([], state: &state)
        #expect(empty.reply == [AgentMessage.failure])
        let truncated = await f.handler.handle([AgentMessage.signRequest, 0, 0, 0, 50, 1], state: &state)
        #expect(truncated.reply == [AgentMessage.failure])
        let unknown = PublicKeyBlob.ed25519(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let (reply, events) = await f.handler.handle(signRequestMessage(keyBlob: unknown, data: [1], flags: 0), state: &state)
        #expect(reply == [AgentMessage.failure])
        guard case .signFailed(nil, let reason) = events.first else { Issue.record("expected signFailed"); return }
        #expect(reason.contains("unknown key"))
        #expect(f.authorizer.requests.isEmpty)
    }

    @Test func deniedRequestsFail() async throws {
        let f = try await Fixture(decision: .deny(reason: "no"))
        defer { f.dir.remove() }
        var state = f.state()
        let (reply, events) = await f.handler.handle(signRequestMessage(keyBlob: Array(f.ed25519.publicKeyBlob), data: [1], flags: 0), state: &state)
        #expect(reply == [AgentMessage.failure])
        #expect(events == [.signFailed(keyID: f.ed25519.id, reason: "denied: no")])
    }

    @Test func sessionBindAndUserAuthDetails() async throws {
        let f = try await Fixture()
        defer { f.dir.remove() }
        let hostKey = PublicKeyBlob.ed25519([UInt8](repeating: 3, count: 32))
        let sessionID = [UInt8](repeating: 0x5A, count: 32)
        var state = f.state()

        let (bindReply, bindEvents) = await f.handler.handle(sessionBindMessage(hostKey: hostKey, sessionID: sessionID, forwarding: false), state: &state)
        #expect(bindReply == [AgentMessage.success])
        #expect(bindEvents == [.sessionBound(hostKeyFingerprint: SSHPublicKey.fingerprint(of: hostKey), isForwarding: false)])
        #expect(state.sessionBinds.count == 1)

        let blob = Array(f.ed25519.publicKeyBlob)
        let data = userAuthData(sessionID: sessionID, user: "dev", algorithm: "ssh-ed25519", keyBlob: blob, hostKey: hostKey)
        let signed = await f.handler.handle(signRequestMessage(keyBlob: blob, data: data, flags: 0), state: &state)
        _ = try parseSignResponse(signed.reply)
        let request = try #require(f.authorizer.requests.last)
        #expect(request.isUserAuthentication)
        #expect(request.user == "dev")
        #expect(request.hostKeyFingerprint == SSHPublicKey.fingerprint(of: hostKey))
        #expect(!request.isForwarded)
        #expect(request.connectionID == 7)

        // Signed data for another session is not treated as this connection's login.
        let other = userAuthData(sessionID: [1, 2, 3], user: "dev", algorithm: "ssh-ed25519", keyBlob: blob, hostKey: hostKey)
        _ = await f.handler.handle(signRequestMessage(keyBlob: blob, data: other, flags: 0), state: &state)
        #expect(f.authorizer.requests.last?.isUserAuthentication == false)

        // Arbitrary data is not userauth either.
        _ = await f.handler.handle(signRequestMessage(keyBlob: blob, data: Array("git commit".utf8), flags: 0), state: &state)
        #expect(f.authorizer.requests.last?.isUserAuthentication == false)
        #expect(f.authorizer.requests.last?.user == nil)
    }

    @Test func forwardingBindMarksTheConnection() async throws {
        let f = try await Fixture()
        defer { f.dir.remove() }
        var state = f.state()
        let hostKey = PublicKeyBlob.ed25519([UInt8](repeating: 4, count: 32))
        _ = await f.handler.handle(sessionBindMessage(hostKey: hostKey, sessionID: [9, 9, 9], forwarding: true), state: &state)
        #expect(state.isForwarded)
        _ = await f.handler.handle(signRequestMessage(keyBlob: Array(f.ed25519.publicKeyBlob), data: [1], flags: 0), state: &state)
        #expect(f.authorizer.requests.last?.isForwarded == true)
    }

    @Test func extensionLimitsAndUnknownExtensions() async throws {
        let f = try await Fixture()
        defer { f.dir.remove() }
        var state = f.state()
        var w = SSHWriter()
        w.byte(AgentMessage.extensionRequest)
        w.string("query")
        let unknown = await f.handler.handle(w.bytes, state: &state)
        #expect(unknown.reply == [AgentMessage.failure])
        #expect(unknown.events == [.refused(request: "EXTENSION query")])
        let truncated = await f.handler.handle([AgentMessage.extensionRequest, 0, 0, 0, 24] + Array("session-bind@openssh.com".utf8), state: &state)
        #expect(truncated.reply == [AgentMessage.failure])
        let hostKey = PublicKeyBlob.ed25519([UInt8](repeating: 5, count: 32))
        for i in 0..<AgentRequestHandler.maxSessionBinds {
            let bound = await f.handler.handle(sessionBindMessage(hostKey: hostKey, sessionID: [UInt8(i) + 1], forwarding: false), state: &state)
            #expect(bound.reply == [AgentMessage.success])
        }
        let tooMany = await f.handler.handle(sessionBindMessage(hostKey: hostKey, sessionID: [200], forwarding: false), state: &state)
        #expect(tooMany.reply == [AgentMessage.failure])
        #expect(state.sessionBinds.count == AgentRequestHandler.maxSessionBinds)
    }

    @Test func userAuthParsing() {
        let blob = PublicKeyBlob.ed25519([UInt8](repeating: 1, count: 32))
        let hostKey = PublicKeyBlob.ed25519([UInt8](repeating: 2, count: 32))
        let plain = UserAuthRequest(parsing: userAuthData(sessionID: [1], user: "root", algorithm: "ssh-ed25519", keyBlob: blob, hostKey: nil), keyBlob: blob)
        #expect(plain?.user == "root")
        #expect(plain?.method == "publickey")
        #expect(plain?.hostKey == nil)
        let bound = UserAuthRequest(parsing: userAuthData(sessionID: [1], user: "root", algorithm: "ssh-ed25519", keyBlob: blob, hostKey: hostKey), keyBlob: blob)
        #expect(bound?.hostKey == hostKey)
        // Another key's blob, or trailing bytes, do not count.
        #expect(UserAuthRequest(parsing: userAuthData(sessionID: [1], user: "root", algorithm: "ssh-ed25519", keyBlob: hostKey, hostKey: nil), keyBlob: blob) == nil)
        #expect(UserAuthRequest(parsing: userAuthData(sessionID: [1], user: "root", algorithm: "ssh-ed25519", keyBlob: blob, hostKey: nil) + [0], keyBlob: blob) == nil)
    }
}

@Suite("Signing policy")
struct SigningPolicyTests {
    private func request(
        policy: SigningPolicy, peer: PeerIdentity = .trustedSSH, userAuth: Bool = true, forwarded: Bool = false, keyID: UUID = UUID()
    ) -> SignRequest {
        SignRequest(
            connectionID: 1, key: .fake(policy: policy, id: keyID), peer: peer, user: userAuth ? "dev" : nil,
            hostKeyFingerprint: "SHA256:abc", isUserAuthentication: userAuth, isForwarded: forwarded)
    }

    @Test func trustedPeerFollowsTheKeyPolicy() {
        #expect(SigningPolicyEvaluator.requirement(for: request(policy: .always)) == .none)
        #expect(SigningPolicyEvaluator.requirement(for: request(policy: .oncePerSession)) == .oncePerSession)
        #expect(SigningPolicyEvaluator.requirement(for: request(policy: .everySignature)) == .everySignature)
    }

    @Test(arguments: [
        PeerIdentity.fake(path: "/opt/homebrew/bin/ssh", appleSSH: false, startedByApp: true),
        PeerIdentity.fake(path: "/usr/bin/ssh", appleSSH: true, startedByApp: false),
        PeerIdentity.fake(path: "/usr/bin/ssh", appleSSH: false, startedByApp: true),
        PeerIdentity.fake(path: "/usr/bin/ssh-add", appleSSH: true, startedByApp: true),
        PeerIdentity.fake(path: nil, appleSSH: true, startedByApp: true),
    ])
    func untrustedPeersAlwaysNeedTouchID(peer: PeerIdentity) {
        #expect(!peer.isTrustedAppSSH)
        for policy in SigningPolicy.allCases {
            #expect(SigningPolicyEvaluator.requirement(for: request(policy: policy, peer: peer)) == .everySignature)
        }
    }

    @Test func forwardedOrNonLoginDataNeedsTouchID() {
        #expect(SigningPolicyEvaluator.requirement(for: request(policy: .always, forwarded: true)) == .everySignature)
        #expect(SigningPolicyEvaluator.requirement(for: request(policy: .always, userAuth: false)) == .everySignature)
    }

    @Test func reasonNamesKeyUserHostAndUntrustedProgram() {
        let reason = SigningPolicyEvaluator.reason(for: request(policy: .always, peer: .fake(path: "/usr/local/bin/git", appleSSH: false)))
        #expect(reason.contains("Test key"))
        #expect(reason.contains("dev"))
        #expect(reason.contains("SHA256:abc"))
        #expect(reason.hasSuffix("for git"))
    }

    @Test func alwaysNeverAsks() async {
        let verifier = ScriptedVerifier(answer: false)
        let authorizer = PolicySigningAuthorizer(verifier: verifier)
        #expect(await authorizer.authorize(request(policy: .always)) == .allow)
        #expect(verifier.callCount == 0)
    }

    @Test func everySignatureAsksEachTime() async {
        let verifier = ScriptedVerifier(answer: true)
        let authorizer = PolicySigningAuthorizer(verifier: verifier)
        let id = UUID()
        for _ in 0..<3 { #expect(await authorizer.authorize(request(policy: .everySignature, keyID: id)) == .allow) }
        #expect(verifier.callCount == 3)
        verifier.setAnswer(false)
        #expect(await authorizer.authorize(request(policy: .everySignature, keyID: id)) == .deny(reason: "user presence not confirmed"))
    }

    @Test func oncePerSessionAsksOncePerKey() async {
        let verifier = ScriptedVerifier(answer: true)
        let authorizer = PolicySigningAuthorizer(verifier: verifier)
        let a = UUID(), b = UUID()
        #expect(await authorizer.authorize(request(policy: .oncePerSession, keyID: a)) == .allow)
        #expect(await authorizer.authorize(request(policy: .oncePerSession, keyID: a)) == .allow)
        #expect(verifier.callCount == 1)
        #expect(await authorizer.authorize(request(policy: .oncePerSession, keyID: b)) == .allow)
        #expect(verifier.callCount == 2)

        await authorizer.forgetSessionApproval(for: a)
        #expect(await !authorizer.hasSessionApproval(for: a))
        #expect(await authorizer.hasSessionApproval(for: b))
        _ = await authorizer.authorize(request(policy: .oncePerSession, keyID: a))
        #expect(verifier.callCount == 3)

        await authorizer.endSession()
        _ = await authorizer.authorize(request(policy: .oncePerSession, keyID: b))
        #expect(verifier.callCount == 4)
    }

    @Test func anUnlockedSessionAsksOnlyForEverySignatureKeys() async {
        let verifier = ScriptedVerifier(answer: true)
        let authorizer = PolicySigningAuthorizer(verifier: verifier, sessionApproved: true)
        #expect(await authorizer.authorize(request(policy: .oncePerSession)) == .allow)
        #expect(verifier.callCount == 0)
        #expect(await authorizer.authorize(request(policy: .everySignature)) == .allow)
        #expect(verifier.callCount == 1)

        await authorizer.endSession()
        #expect(await authorizer.authorize(request(policy: .oncePerSession)) == .allow)
        #expect(verifier.callCount == 2)
    }

    @Test func oncePerSessionDenialIsNotRemembered() async {
        let verifier = ScriptedVerifier(answer: false)
        let authorizer = PolicySigningAuthorizer(verifier: verifier)
        let id = UUID()
        #expect(await authorizer.authorize(request(policy: .oncePerSession, keyID: id)) == .deny(reason: "user presence not confirmed"))
        verifier.setAnswer(true)
        #expect(await authorizer.authorize(request(policy: .oncePerSession, keyID: id)) == .allow)
        #expect(verifier.callCount == 2)
    }

    @Test func concurrentFirstRequestsShareOnePrompt() async {
        let verifier = ScriptedVerifier(answer: true, delay: .milliseconds(200))
        let authorizer = PolicySigningAuthorizer(verifier: verifier)
        let id = UUID()
        let requests = (0..<5).map { _ in request(policy: .oncePerSession, keyID: id) }
        let decisions = await withTaskGroup(of: SigningDecision.self) { group in
            for r in requests { group.addTask { await authorizer.authorize(r) } }
            return await group.reduce(into: [SigningDecision]()) { $0.append($1) }
        }
        #expect(decisions == Array(repeating: .allow, count: 5))
        #expect(verifier.callCount == 1)
    }

    @Test func untrustedPeersNeitherUseNorCreateSessionApprovals() async {
        let verifier = ScriptedVerifier(answer: true)
        let authorizer = PolicySigningAuthorizer(verifier: verifier)
        let id = UUID()
        let untrusted = PeerIdentity.fake(path: "/usr/bin/ssh", appleSSH: true, startedByApp: false)
        _ = await authorizer.authorize(request(policy: .oncePerSession, peer: untrusted, keyID: id))
        #expect(await !authorizer.hasSessionApproval(for: id))
        _ = await authorizer.authorize(request(policy: .oncePerSession, keyID: id)) // trusted: asks, then remembers
        #expect(verifier.callCount == 2)
        _ = await authorizer.authorize(request(policy: .oncePerSession, peer: untrusted, keyID: id))
        #expect(verifier.callCount == 3)
    }
}
