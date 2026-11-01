import CryptoKit
import Foundation
import Security

/// Why a signature could not be produced.
enum SigningError: Error, Equatable, Sendable, CustomStringConvertible {
    /// RSA request without `rsa-sha2-256`/`rsa-sha2-512` flags, i.e. a SHA-1 `ssh-rsa` signature.
    case sha1Refused(flags: UInt32)
    /// The stored secret could not be turned back into a key.
    case invalidSecret(SSHKeyAlgorithm, String)
    /// CryptoKit or Security.framework failed.
    case crypto(String)

    var description: String {
        switch self {
        case .sha1Refused(let flags): "refusing SHA-1 ssh-rsa signature (flags \(flags)); only rsa-sha2-256/512"
        case .invalidSecret(let alg, let why): "stored \(alg.displayName) secret is unusable: \(why)"
        case .crypto(let why): why
        }
    }
}

/// A private key the agent can sign with.
protocol SSHSigningKey: Sendable {
    var algorithm: SSHKeyAlgorithm { get }
    /// The public key blob sent in `IDENTITIES_ANSWER` and matched in `SIGN_REQUEST`.
    var publicKeyBlob: [UInt8] { get }
    /// The full SSH signature blob: `string signature-algorithm || string signature`.
    func signature(for data: [UInt8], flags: UInt32) throws -> [UInt8]
}

// MARK: Ed25519

struct Ed25519SigningKey: SSHSigningKey {
    let privateKey: Curve25519.Signing.PrivateKey

    var algorithm: SSHKeyAlgorithm { .ed25519 }
    var publicKeyBlob: [UInt8] { PublicKeyBlob.ed25519(privateKey.publicKey.rawRepresentation) }

    func signature(for data: [UInt8], flags: UInt32) throws -> [UInt8] {
        // 64 bytes R || S. CryptoKit's signatures are randomized but valid: verify, never compare bytes.
        let signature = try privateKey.signature(for: Data(data))
        var w = SSHWriter()
        w.string("ssh-ed25519")
        w.string(signature)
        return w.bytes
    }
}

// MARK: ECDSA P-256

/// `string "ecdsa-sha2-nistp256" || string(mpint r || mpint s)` from CryptoKit's raw `r || s`.
func ecdsaP256SignatureBlob(raw: Data) -> [UInt8] {
    let bytes = Array(raw)
    var inner = SSHWriter()
    inner.mpint(unsigned: bytes[0..<32])
    inner.mpint(unsigned: bytes[32..<64])
    var w = SSHWriter()
    w.string("ecdsa-sha2-nistp256")
    w.string(inner.bytes)
    return w.bytes
}

/// A software P-256 key (imported from a file).
struct P256SigningKey: SSHSigningKey {
    let privateKey: P256.Signing.PrivateKey

    var algorithm: SSHKeyAlgorithm { .ecdsaP256 }
    var publicKeyBlob: [UInt8] { PublicKeyBlob.ecdsaP256(x963: privateKey.publicKey.x963Representation) }

    func signature(for data: [UInt8], flags: UInt32) throws -> [UInt8] {
        // signature(for:) hashes with SHA-256 itself; never pass a digest here.
        ecdsaP256SignatureBlob(raw: try privateKey.signature(for: Data(data)).rawRepresentation)
    }
}

/// A P-256 key inside the Secure Enclave, reloaded from its wrapped `dataRepresentation`.
struct SecureEnclaveP256SigningKey: SSHSigningKey {
    let privateKey: SecureEnclave.P256.Signing.PrivateKey

    var algorithm: SSHKeyAlgorithm { .secureEnclaveP256 }
    var publicKeyBlob: [UInt8] { PublicKeyBlob.ecdsaP256(x963: privateKey.publicKey.x963Representation) }

    func signature(for data: [UInt8], flags: UInt32) throws -> [UInt8] {
        ecdsaP256SignatureBlob(raw: try privateKey.signature(for: Data(data)).rawRepresentation)
    }
}

// MARK: RSA

/// An RSA key via Security.framework. `SecKey` is immutable and thread-safe but not annotated `Sendable`.
final class RSASigningKey: SSHSigningKey, @unchecked Sendable {
    let privateKey: SecKey
    let publicKeyBlob: [UInt8]
    /// Modulus size in bits.
    let bitCount: Int

    var algorithm: SSHKeyAlgorithm { .rsa }

    /// Wraps a private `SecKey`, deriving the `ssh-rsa` public blob from its PKCS#1 public key.
    init(privateKey: SecKey) throws {
        self.privateKey = privateKey
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw SigningError.crypto("RSA key has no public key") }
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SigningError.crypto("RSA public key export failed: \(Self.describe(error))")
        }
        // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
        var outer = DERReader(Array(der))
        var sequence = try outer.sequence("RSAPublicKey")
        let n = try sequence.unsignedInteger("modulus")
        let e = try sequence.unsignedInteger("publicExponent")
        publicKeyBlob = PublicKeyBlob.rsa(exponent: e, modulus: n)
        bitCount = BigUInt(bigEndian: n).bitWidth
    }

    /// Loads a key from PKCS#1 `RSAPrivateKey` DER (what the ``KeychainStore`` holds).
    convenience init(pkcs1DER: Data) throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1DER as CFData, attributes as CFDictionary, &error) else {
            throw SigningError.invalidSecret(.rsa, Self.describe(error))
        }
        try self.init(privateKey: key)
    }

    func signature(for data: [UInt8], flags: UInt32) throws -> [UInt8] {
        let algorithm: SecKeyAlgorithm
        let name: String
        if flags & AgentMessage.flagRSASHA512 != 0 {
            (algorithm, name) = (.rsaSignatureMessagePKCS1v15SHA512, "rsa-sha2-512")
        } else if flags & AgentMessage.flagRSASHA256 != 0 {
            (algorithm, name) = (.rsaSignatureMessagePKCS1v15SHA256, "rsa-sha2-256")
        } else {
            throw SigningError.sha1Refused(flags: flags)
        }
        var error: Unmanaged<CFError>?
        // The "Message" algorithms hash the data themselves.
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, Data(data) as CFData, &error) as Data? else {
            throw SigningError.crypto("RSA signing failed: \(Self.describe(error))")
        }
        var w = SSHWriter()
        w.string(name)
        w.string(signature)
        return w.bytes
    }

    static func describe(_ error: Unmanaged<CFError>?) -> String {
        error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown error"
    }
}

// MARK: Rebuilding keys from stored secrets

enum SigningKeyFactory {
    /// Rebuilds a signing key from the bytes kept in the ``KeychainStore``:
    /// the Ed25519 seed (32 B), the P-256 scalar (32 B), the SE `dataRepresentation`, or PKCS#1 DER.
    static func make(_ algorithm: SSHKeyAlgorithm, secret: Data) throws -> any SSHSigningKey {
        do {
            switch algorithm {
            case .ed25519:
                return Ed25519SigningKey(privateKey: try .init(rawRepresentation: secret))
            case .ecdsaP256:
                return P256SigningKey(privateKey: try .init(rawRepresentation: secret))
            case .secureEnclaveP256:
                guard SecureEnclave.isAvailable else { throw SigningError.invalidSecret(algorithm, "no Secure Enclave on this Mac") }
                return SecureEnclaveP256SigningKey(privateKey: try .init(dataRepresentation: secret))
            case .rsa:
                return try RSASigningKey(pkcs1DER: secret)
            }
        } catch let error as SigningError {
            throw error
        } catch {
            throw SigningError.invalidSecret(algorithm, String(describing: error))
        }
    }
}
