/// How a key is held and which SSH key type it serves.
public enum SSHKeyAlgorithm: String, Codable, Sendable, CaseIterable {
    /// `ssh-ed25519`; the 32-byte seed lives in the ``SecretStore``.
    case ed25519
    /// `ecdsa-sha2-nistp256` generated inside the Secure Enclave. The ``SecretStore`` holds only
    /// the SE-wrapped `dataRepresentation`, which is useless on any other Mac.
    case secureEnclaveP256
    /// `ecdsa-sha2-nistp256` imported from a file (software key; cannot move into the Secure Enclave).
    case ecdsaP256
    /// `ssh-rsa` key, signing only with `rsa-sha2-256` or `rsa-sha2-512` (never SHA-1).
    case rsa

    /// The OpenSSH key type name, as used in public key blobs and `authorized_keys`.
    public var keyType: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .secureEnclaveP256, .ecdsaP256: "ecdsa-sha2-nistp256"
        case .rsa: "ssh-rsa"
        }
    }

    /// A short label for the UI.
    public var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .secureEnclaveP256: "ECDSA P-256 (Secure Enclave)"
        case .ecdsaP256: "ECDSA P-256"
        case .rsa: "RSA"
        }
    }
}

/// Which kinds of key the app can generate.
public enum KeyGenerationType: Sendable, Hashable, CaseIterable {
    /// Ed25519 (CryptoKit); the private key is stored in the ``SecretStore``.
    case ed25519
    /// P-256 inside the Secure Enclave; non-exportable.
    case secureEnclaveP256

    var algorithm: SSHKeyAlgorithm {
        switch self {
        case .ed25519: .ed25519
        case .secureEnclaveP256: .secureEnclaveP256
        }
    }
}

/// Per-key signing policy.
///
/// Independently of the policy, a request from a peer that is not `/usr/bin/ssh` started by
/// AeroOps always needs user presence (see ``SigningPolicyEvaluator``).
public enum SigningPolicy: String, Codable, Sendable, CaseIterable {
    /// Sign without asking.
    case always
    /// Ask for Touch ID (or the login password) the first time the key signs in this app session.
    case oncePerSession
    /// Ask for Touch ID for every signature.
    case everySignature
}
