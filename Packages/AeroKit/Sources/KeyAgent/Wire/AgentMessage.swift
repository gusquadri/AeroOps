/// ssh-agent message numbers and constants (draft-miller-ssh-agent §6).
enum AgentMessage {
    static let failure: UInt8 = 5
    static let success: UInt8 = 6
    static let requestIdentities: UInt8 = 11
    static let identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13
    static let signResponse: UInt8 = 14
    static let addIdentity: UInt8 = 17
    static let removeIdentity: UInt8 = 18
    static let removeAllIdentities: UInt8 = 19
    static let addSmartcardKey: UInt8 = 20
    static let removeSmartcardKey: UInt8 = 21
    static let lock: UInt8 = 22
    static let unlock: UInt8 = 23
    static let addIdentityConstrained: UInt8 = 25
    static let addSmartcardKeyConstrained: UInt8 = 26
    static let extensionRequest: UInt8 = 27

    /// OpenSSH's `AGENT_MAX_LEN`: larger messages close the connection.
    static let maxLength = 256 * 1024

    /// `SSH_AGENT_RSA_SHA2_256`: sign with `rsa-sha2-256`.
    static let flagRSASHA256: UInt32 = 2
    /// `SSH_AGENT_RSA_SHA2_512`: sign with `rsa-sha2-512` (preferred when both are set).
    static let flagRSASHA512: UInt32 = 4

    /// `session-bind@openssh.com`, sent by OpenSSH 8.9+ before userauth.
    static let sessionBindExtension = "session-bind@openssh.com"

    /// A readable name for logs and events.
    static func name(_ type: UInt8) -> String {
        switch type {
        case 1: "REQUEST_RSA_IDENTITIES (v1)"
        case 9: "REMOVE_ALL_RSA_IDENTITIES (v1)"
        case requestIdentities: "REQUEST_IDENTITIES"
        case signRequest: "SIGN_REQUEST"
        case addIdentity: "ADD_IDENTITY"
        case removeIdentity: "REMOVE_IDENTITY"
        case removeAllIdentities: "REMOVE_ALL_IDENTITIES"
        case addSmartcardKey: "ADD_SMARTCARD_KEY"
        case removeSmartcardKey: "REMOVE_SMARTCARD_KEY"
        case lock: "LOCK"
        case unlock: "UNLOCK"
        case addIdentityConstrained: "ADD_ID_CONSTRAINED"
        case addSmartcardKeyConstrained: "ADD_SMARTCARD_KEY_CONSTRAINED"
        case extensionRequest: "EXTENSION"
        default: "type \(type)"
        }
    }
}
