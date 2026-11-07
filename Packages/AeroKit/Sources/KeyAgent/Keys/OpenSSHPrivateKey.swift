import CryptoKit
import Foundation

/// Why a private key file could not be imported.
public enum KeyImportError: Error, Equatable, Sendable, LocalizedError {
    /// Not an `-----BEGIN OPENSSH PRIVATE KEY-----` file. `detected` names the format when known
    /// (PKCS#1, PKCS#8, SEC1 PEM); `ssh-keygen -p -f <file>` rewrites those as `openssh-key-v1`.
    case notOpenSSHFormat(detected: String?)
    /// A public key (`.pub` contents or an authorized_keys line) instead of the private key.
    case publicKey
    /// The key is protected by a passphrase. Encrypted import comes in a later phase.
    case encrypted(cipher: String, kdf: String)
    /// A key type the agent does not serve (e.g. DSA, ECDSA P-384/P-521, FIDO `sk-` keys).
    case unsupportedKeyType(String)
    /// RSA modulus below OpenSSH's 1024-bit minimum.
    case rsaKeyTooSmall(bits: Int)
    /// The file holds more than one key (OpenSSH never writes this).
    case multipleKeys(Int)
    /// The structure is damaged.
    case malformed(String)
    /// The private half does not match the public key, or a test signature did not verify.
    case inconsistentKey(String)

    public var errorDescription: String? {
        switch self {
        case .notOpenSSHFormat(let detected?):
            "This is a \(detected) key. Convert it to the OpenSSH format first with `ssh-keygen -p -f <file>`."
        case .notOpenSSHFormat(nil):
            "Not an OpenSSH private key (expected -----BEGIN OPENSSH PRIVATE KEY-----)."
        case .publicKey:
            "This is a public key. Choose the private key file instead: it has the same name without .pub."
        case .encrypted:
            "This key is protected by a passphrase. Importing encrypted keys is not supported yet; remove the passphrase with `ssh-keygen -p -f <file>` on a copy, or generate a new key in AeroOps."
        case .unsupportedKeyType(let type):
            "Key type \(type) is not supported. AeroOps serves Ed25519, ECDSA P-256 and RSA keys."
        case .rsaKeyTooSmall(let bits): "RSA keys need at least 1024 bits; this one has \(bits)."
        case .multipleKeys(let n): "The file contains \(n) keys; expected exactly one."
        case .malformed(let why): "The key file is damaged: \(why)."
        case .inconsistentKey(let why): "The key file is inconsistent: \(why)."
        }
    }
}

/// A private key parsed from an unencrypted `openssh-key-v1` file (OpenSSH `PROTOCOL.key`).
struct OpenSSHPrivateKey: Sendable {
    let algorithm: SSHKeyAlgorithm
    let comment: String
    let publicKeyBlob: [UInt8]
    /// What the ``KeychainStore`` keeps: Ed25519 seed, P-256 scalar, or RSA PKCS#1 DER.
    let secret: Data
    let signingKey: any SSHSigningKey

    private static let magic = Array("openssh-key-v1".utf8) + [0]
    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"

    /// Parses the PEM-armoured text of an OpenSSH private key file.
    static func parse(_ text: String) throws(KeyImportError) -> OpenSSHPrivateKey {
        guard let begin = text.range(of: beginMarker), let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) else {
            if isPublicKey(text) { throw .publicKey }
            throw .notOpenSSHFormat(detected: detectOtherFormat(text))
        }
        let base64 = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let binary = Data(base64Encoded: String(base64)) else { throw .malformed("invalid base64") }
        return try parse(binary: Array(binary))
    }

    static func parse(binary: [UInt8]) throws(KeyImportError) -> OpenSSHPrivateKey {
        do {
            return try parseUnchecked(binary)
        } catch let error as KeyImportError {
            throw error
        } catch let error as SSHWireError {
            throw .malformed(error.description)
        } catch {
            throw .malformed(String(describing: error))
        }
    }

    private static func parseUnchecked(_ binary: [UInt8]) throws -> OpenSSHPrivateKey {
        guard binary.starts(with: magic) else { throw KeyImportError.malformed("missing openssh-key-v1 magic") }
        var r = SSHReader(Array(binary.dropFirst(magic.count)))
        let cipher = try r.text("cipher name")
        let kdf = try r.text("kdf name")
        _ = try r.string("kdf options")
        guard cipher == "none", kdf == "none" else { throw KeyImportError.encrypted(cipher: cipher, kdf: kdf) }
        let count = try r.uint32("number of keys")
        guard count == 1 else { throw KeyImportError.multipleKeys(Int(count)) }
        let filePublicBlob = try r.string("public key")
        var p = SSHReader(try r.string("private section"))

        // Matching check integers; with "none" they are plain, so a mismatch means corruption.
        guard try p.uint32("checkint") == (try p.uint32("checkint")) else { throw KeyImportError.malformed("check integers differ") }

        let keyType = try p.text("key type")
        let algorithm: SSHKeyAlgorithm
        let secret: Data
        let signingKey: any SSHSigningKey
        switch keyType {
        case "ssh-ed25519":
            let publicKey = try p.string("ed25519 public key")
            let privateKey = try p.string("ed25519 private key") // seed(32) || public(32)
            guard publicKey.count == 32, privateKey.count == 64 else { throw KeyImportError.malformed("ed25519 key lengths") }
            guard Array(privateKey[32...]) == publicKey else { throw KeyImportError.inconsistentKey("ed25519 public half differs") }
            let seed = Data(privateKey[0..<32])
            let key = Ed25519SigningKey(privateKey: try .init(rawRepresentation: seed))
            guard Array(key.privateKey.publicKey.rawRepresentation) == publicKey else {
                throw KeyImportError.inconsistentKey("ed25519 seed does not produce the stored public key")
            }
            (algorithm, secret, signingKey) = (.ed25519, seed, key)

        case "ecdsa-sha2-nistp256":
            let curve = try p.text("curve")
            let q = try p.string("ecdsa public point")
            let scalar = try p.unsignedMPInt("ecdsa private scalar")
            guard curve == "nistp256" else { throw KeyImportError.unsupportedKeyType("ecdsa-sha2-\(curve)") }
            guard let raw = fixedWidth(scalar, 32) else { throw KeyImportError.malformed("ecdsa private scalar too long") }
            let key = P256SigningKey(privateKey: try .init(rawRepresentation: raw))
            guard Array(key.privateKey.publicKey.x963Representation) == q else {
                throw KeyImportError.inconsistentKey("ecdsa private scalar does not produce the stored public point")
            }
            (algorithm, secret, signingKey) = (.ecdsaP256, Data(raw), key)

        case "ssh-rsa":
            let components = RSAPrivateComponents(
                modulus: try p.unsignedMPInt("rsa n"),
                publicExponent: try p.unsignedMPInt("rsa e"),
                privateExponent: try p.unsignedMPInt("rsa d"),
                iqmp: try p.unsignedMPInt("rsa iqmp"),
                prime1: try p.unsignedMPInt("rsa p"),
                prime2: try p.unsignedMPInt("rsa q"))
            let bits = BigUInt(bigEndian: components.modulus).bitWidth
            guard bits >= 1024 else { throw KeyImportError.rsaKeyTooSmall(bits: bits) }
            let der = Data(try components.pkcs1DER())
            let key: RSASigningKey
            do {
                key = try RSASigningKey(pkcs1DER: der)
            } catch {
                throw KeyImportError.malformed("Security.framework rejected the RSA key: \(error)")
            }
            (algorithm, secret, signingKey) = (.rsa, der, key)

        default:
            throw KeyImportError.unsupportedKeyType(keyType)
        }

        let comment = try p.text("comment")
        // Padding is 1, 2, 3, … up to the cipher block size.
        let padding = p.rest()
        guard padding.count < 256, padding.enumerated().allSatisfy({ $0.element == UInt8(truncatingIfNeeded: $0.offset + 1) }) else {
            throw KeyImportError.malformed("bad padding")
        }
        guard signingKey.publicKeyBlob == filePublicBlob else {
            throw KeyImportError.inconsistentKey("private key does not match the file's public key")
        }
        try selfTest(signingKey)
        return OpenSSHPrivateKey(algorithm: algorithm, comment: comment, publicKeyBlob: filePublicBlob, secret: secret, signingKey: signingKey)
    }

    /// Signs a random message and verifies it, which catches wrong RSA CRT parameters.
    static func selfTest(_ key: any SSHSigningKey) throws {
        let message = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let blob = try key.signature(for: message, flags: AgentMessage.flagRSASHA512)
        guard SignatureVerifier.verify(signatureBlob: blob, publicKeyBlob: key.publicKeyBlob, data: message) else {
            throw KeyImportError.inconsistentKey("test signature did not verify")
        }
    }

    private static func detectOtherFormat(_ text: String) -> String? {
        if text.contains("-----BEGIN RSA PRIVATE KEY-----") { return "PKCS#1 PEM (RSA)" }
        if text.contains("-----BEGIN EC PRIVATE KEY-----") { return "SEC1 PEM (EC)" }
        if text.contains("-----BEGIN DSA PRIVATE KEY-----") { return "PEM (DSA)" }
        if text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return "encrypted PKCS#8 PEM" }
        if text.contains("-----BEGIN PRIVATE KEY-----") { return "PKCS#8 PEM" }
        if text.contains("PuTTY-User-Key-File") { return "PuTTY" }
        return nil
    }

    /// An OpenSSH public key line (`ssh-ed25519 AAAA… comment`, also `ecdsa-` and `sk-` types).
    private static func isPublicKey(_ text: String) -> Bool {
        let line = text.drop { $0.isWhitespace }
        return ["ssh-", "ecdsa-", "sk-"].contains { line.hasPrefix($0) }
    }
}

/// Verifies SSH signature blobs against public key blobs (Ed25519, ECDSA P-256, RSA SHA-2).
/// Used for the import self-test and by the tests.
enum SignatureVerifier {
    static func verify(signatureBlob: [UInt8], publicKeyBlob: [UInt8], data: [UInt8]) -> Bool {
        do {
            var sig = SSHReader(signatureBlob)
            let name = try sig.text()
            let signature = try sig.string()
            var pub = SSHReader(publicKeyBlob)
            let keyType = try pub.text()
            switch (keyType, name) {
            case ("ssh-ed25519", "ssh-ed25519"):
                let key = try Curve25519.Signing.PublicKey(rawRepresentation: try pub.string())
                return key.isValidSignature(signature, for: data)
            case ("ecdsa-sha2-nistp256", "ecdsa-sha2-nistp256"):
                guard try pub.text() == "nistp256" else { return false }
                let key = try P256.Signing.PublicKey(x963Representation: try pub.string())
                var rs = SSHReader(signature)
                guard let r = fixedWidth(try rs.unsignedMPInt(), 32), let s = fixedWidth(try rs.unsignedMPInt(), 32) else { return false }
                let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: r + s)
                return key.isValidSignature(ecdsa, for: data)
            case ("ssh-rsa", "rsa-sha2-256"), ("ssh-rsa", "rsa-sha2-512"):
                let e = try pub.unsignedMPInt()
                let n = try pub.unsignedMPInt()
                let der = DERWriter.sequence([DERWriter.integer(unsigned: n), DERWriter.integer(unsigned: e)])
                let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
                guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil) else { return false }
                let algorithm: SecKeyAlgorithm = name == "rsa-sha2-512" ? .rsaSignatureMessagePKCS1v15SHA512 : .rsaSignatureMessagePKCS1v15SHA256
                return SecKeyVerifySignature(key, algorithm, Data(data) as CFData, Data(signature) as CFData, nil)
            default:
                return false
            }
        } catch {
            return false
        }
    }
}
