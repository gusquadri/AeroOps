import Foundation

/// Something the agent did, for the peer log and the UI. Never carries signed data or signatures.
public struct AgentEvent: Sendable {
    public enum Kind: Sendable, Equatable {
        /// A client connected and was identified.
        case connected(PeerIdentity)
        /// A client was dropped before any request (another user, unidentifiable, or too many connections).
        case rejected(reason: String)
        case identitiesListed(count: Int)
        /// `session-bind@openssh.com`: the server's host key for this connection (not verified).
        case sessionBound(hostKeyFingerprint: String, isForwarding: Bool)
        case signed(keyID: UUID, keyName: String, signatureAlgorithm: String, user: String?, hostKeyFingerprint: String?)
        /// A sign request failed: unknown key, SHA-1 RSA, denied by the authorizer, or a key error.
        case signFailed(keyID: UUID?, reason: String)
        /// A request the agent does not allow (add, remove, lock, unknown types and extensions).
        case refused(request: String)
        case disconnected
    }

    public var date: Date
    public var connectionID: UInt64
    public var kind: Kind

    public init(date: Date = Date(), connectionID: UInt64, kind: Kind) {
        self.date = date
        self.connectionID = connectionID
        self.kind = kind
    }
}
