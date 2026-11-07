import Foundation

/// Per-connection protocol state.
struct AgentConnectionState: Sendable {
    struct SessionBind: Sendable, Equatable {
        var hostKeyFingerprint: String
        var sessionID: [UInt8]
        var isForwarding: Bool
    }

    let connectionID: UInt64
    let peer: PeerIdentity
    var sessionBinds: [SessionBind] = []

    /// ssh marked a bind as agent forwarding: requests come from another machine.
    var isForwarded: Bool { sessionBinds.contains { $0.isForwarding } }
}

/// The ssh-agent protocol (draft-miller-ssh-agent) without I/O: one message in, one reply out.
///
/// Serves `REQUEST_IDENTITIES`, `SIGN_REQUEST` and the `session-bind@openssh.com` extension.
/// Everything else (add, remove, lock, unlock, smartcard, other extensions, protocol 1) gets
/// `SSH_AGENT_FAILURE`, and the connection stays open.
struct AgentRequestHandler: Sendable {
    let keyStore: KeyStore
    let authorizer: any SigningAuthorizer

    /// OpenSSH's agent keeps at most 16 session binds per connection.
    static let maxSessionBinds = 16

    /// `message` is one frame's payload (type byte + body), without the length prefix.
    func handle(_ message: [UInt8], state: inout AgentConnectionState) async -> (reply: [UInt8], events: [AgentEvent.Kind]) {
        guard let type = message.first else { return failure(.refused(request: "empty message")) }
        var body = SSHReader(Array(message.dropFirst()))
        switch type {
        case AgentMessage.requestIdentities:
            return await identities()
        case AgentMessage.signRequest:
            return await sign(&body, state: state)
        case AgentMessage.extensionRequest:
            return handleExtension(&body, state: &state)
        default:
            return failure(.refused(request: AgentMessage.name(type)))
        }
    }

    private func failure(_ event: AgentEvent.Kind) -> (reply: [UInt8], events: [AgentEvent.Kind]) {
        ([AgentMessage.failure], [event])
    }

    private func identities() async -> (reply: [UInt8], events: [AgentEvent.Kind]) {
        let records = await keyStore.identities()
        var w = SSHWriter()
        w.byte(AgentMessage.identitiesAnswer)
        w.uint32(UInt32(records.count))
        for record in records {
            w.string(record.publicKeyBlob)
            w.string(SSHPublicKey.sanitizedComment(record.comment.isEmpty ? record.name : record.comment))
        }
        return (w.bytes, [.identitiesListed(count: records.count)])
    }

    private func sign(_ body: inout SSHReader, state: AgentConnectionState) async -> (reply: [UInt8], events: [AgentEvent.Kind]) {
        let keyBlob: [UInt8], data: [UInt8], flags: UInt32
        do {
            keyBlob = try body.string("key blob")
            data = try body.string("data")
            flags = try body.uint32("flags")
        } catch {
            return failure(.signFailed(keyID: nil, reason: "malformed sign request: \(error)"))
        }

        let found: (record: SSHKeyRecord, key: any SSHSigningKey)?
        do {
            found = try await keyStore.signingKey(forPublicKeyBlob: keyBlob)
        } catch {
            return failure(.signFailed(keyID: nil, reason: "key unavailable: \(error.localizedDescription)"))
        }
        guard let (record, key) = found else {
            return failure(.signFailed(keyID: nil, reason: "unknown key \(SSHPublicKey.fingerprint(of: keyBlob))"))
        }
        if record.algorithm == .rsa, flags & (AgentMessage.flagRSASHA256 | AgentMessage.flagRSASHA512) == 0 {
            return failure(.signFailed(keyID: record.id, reason: SigningError.sha1Refused(flags: flags).description))
        }

        let userAuth = UserAuthRequest(parsing: data, keyBlob: keyBlob)
        let sessionMatches = userAuth.map { auth in state.sessionBinds.last.map { $0.sessionID == auth.sessionID } ?? true } ?? false
        let request = SignRequest(
            connectionID: state.connectionID, key: record, peer: state.peer, user: userAuth?.user,
            hostKeyFingerprint: userAuth?.hostKey.map { SSHPublicKey.fingerprint(of: $0) } ?? state.sessionBinds.last?.hostKeyFingerprint,
            isUserAuthentication: userAuth != nil && sessionMatches, isForwarded: state.isForwarded)

        if case .deny(let reason) = await authorizer.authorize(request) {
            return failure(.signFailed(keyID: record.id, reason: "denied: \(reason)"))
        }

        let signature: [UInt8]
        do {
            signature = try key.signature(for: data, flags: flags)
        } catch {
            return failure(.signFailed(keyID: record.id, reason: "signing failed: \(error)"))
        }
        var name = SSHReader(signature)
        let algorithm = (try? name.text()) ?? record.algorithm.keyType
        var w = SSHWriter()
        w.byte(AgentMessage.signResponse)
        w.string(signature)
        return (w.bytes, [.signed(keyID: record.id, keyName: record.name, signatureAlgorithm: algorithm, user: request.user, hostKeyFingerprint: request.hostKeyFingerprint)])
    }

    private func handleExtension(_ body: inout SSHReader, state: inout AgentConnectionState) -> (reply: [UInt8], events: [AgentEvent.Kind]) {
        guard let name = try? body.text("extension name") else { return failure(.refused(request: "EXTENSION (malformed)")) }
        guard name == AgentMessage.sessionBindExtension else {
            let printable = String(name.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f }.prefix(64).map(Character.init))
            return failure(.refused(request: "EXTENSION \(printable)"))
        }
        let bind: AgentConnectionState.SessionBind
        do {
            let hostKey = try body.string("session-bind host key")
            let sessionID = try body.string("session-bind session id")
            _ = try body.string("session-bind signature")
            let isForwarding = try body.bool("session-bind is_forwarding")
            guard !hostKey.isEmpty, !sessionID.isEmpty, sessionID.count <= 128 else { throw SSHWireError.malformed("session-bind") }
            bind = .init(hostKeyFingerprint: SSHPublicKey.fingerprint(of: hostKey), sessionID: sessionID, isForwarding: isForwarding)
        } catch {
            return failure(.refused(request: "EXTENSION \(name) (malformed)"))
        }
        guard state.sessionBinds.count < Self.maxSessionBinds else {
            return failure(.refused(request: "EXTENSION \(name) (too many binds)"))
        }
        state.sessionBinds.append(bind)
        return ([AgentMessage.success], [.sessionBound(hostKeyFingerprint: bind.hostKeyFingerprint, isForwarding: bind.isForwarding)])
    }
}

/// The data ssh signs for public key authentication (RFC 4252 §7), as far as the agent cares.
struct UserAuthRequest: Equatable {
    static let userAuthRequestMessage: UInt8 = 50
    static let methods: Set<String> = ["publickey", "publickey-hostbound-v00@openssh.com"]

    let sessionID: [UInt8]
    let user: String
    let service: String
    let method: String
    /// The server host key, present with `publickey-hostbound-v00@openssh.com`.
    let hostKey: [UInt8]?

    /// `nil` unless `data` is exactly a userauth request for `keyBlob`.
    init?(parsing data: [UInt8], keyBlob: [UInt8]) {
        var r = SSHReader(data)
        do {
            sessionID = try r.string("session id")
            guard try r.byte("message type") == Self.userAuthRequestMessage else { return nil }
            user = try r.text("user")
            service = try r.text("service")
            method = try r.text("method")
            guard Self.methods.contains(method), try r.bool("has signature") else { return nil }
            _ = try r.text("algorithm")
            guard try r.string("public key") == keyBlob else { return nil }
            hostKey = method == "publickey" ? nil : try r.string("host key")
            guard r.isAtEnd, !sessionID.isEmpty else { return nil }
        } catch {
            return nil
        }
    }
}
