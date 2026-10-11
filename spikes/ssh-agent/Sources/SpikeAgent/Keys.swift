// Agent key types: Ed25519 (CryptoKit, raw key in Keychain), ECDSA P-256 in the
// Secure Enclave (CryptoKit, wrapped blob in Keychain), RSA (Security.framework).
import CryptoKit
import Foundation
import Security

enum KeyError: Error, CustomStringConvertible {
    case unsupportedFlags(UInt32)
    case security(String, OSStatus?)

    var description: String {
        switch self {
        case .unsupportedFlags(let f): "refusing signature with flags \(f) (no SHA-1 ssh-rsa)"
        case .security(let what, let status):
            "\(what)\(status.map { " (OSStatus \($0): \(SecCopyErrorMessageString($0, nil) as String? ?? "?"))" } ?? "")"
        }
    }
}

protocol AgentKey: Sendable {
    var comment: String { get }
    var keyType: String { get }
    /// Public key blob as sent in IDENTITIES_ANSWER and matched in SIGN_REQUEST.
    var publicKeyBlob: [UInt8] { get }
    /// Returns the full SSH signature blob: string(alg) + string(sig).
    func sign(_ data: [UInt8], flags: UInt32) throws -> [UInt8]
}

extension AgentKey {
    /// One `authorized_keys` / `.pub` line.
    var authorizedKeysLine: String {
        "\(keyType) \(Data(publicKeyBlob).base64EncodedString()) \(comment)"
    }

    var fingerprint: String {
        let digest = SHA256.hash(data: Data(publicKeyBlob))
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

// MARK: Ed25519

struct Ed25519AgentKey: AgentKey {
    let key: Curve25519.Signing.PrivateKey
    let comment: String
    var keyType: String { "ssh-ed25519" }

    var publicKeyBlob: [UInt8] {
        var w = WireWriter()
        w.string("ssh-ed25519")
        w.string(Array(key.publicKey.rawRepresentation)) // 32 bytes
        return w.bytes
    }

    func sign(_ data: [UInt8], flags: UInt32) throws -> [UInt8] {
        let sig = try key.signature(for: Data(data)) // 64 bytes (R || S); CryptoKit's is randomized but valid
        var w = WireWriter()
        w.string("ssh-ed25519")
        w.string(Array(sig))
        return w.bytes
    }
}

// MARK: ECDSA P-256 in the Secure Enclave

struct SecureEnclaveP256AgentKey: AgentKey {
    let key: SecureEnclave.P256.Signing.PrivateKey
    let comment: String
    var keyType: String { "ecdsa-sha2-nistp256" }

    var publicKeyBlob: [UInt8] {
        var w = WireWriter()
        w.string("ecdsa-sha2-nistp256")
        w.string("nistp256")
        w.string(Array(key.publicKey.x963Representation)) // 0x04 || X || Y, 65 bytes
        return w.bytes
    }

    func sign(_ data: [UInt8], flags: UInt32) throws -> [UInt8] {
        // `signature(for: some DataProtocol)` hashes with SHA-256 itself; passing a
        // SHA256Digest would sign a pre-computed digest instead. Do NOT hash twice.
        let sig = try key.signature(for: Data(data))
        let raw = Array(sig.rawRepresentation) // r || s, 32 bytes each, unsigned big-endian
        var inner = WireWriter()
        inner.mpint(unsigned: raw[0..<32])
        inner.mpint(unsigned: raw[32..<64])
        var w = WireWriter()
        w.string("ecdsa-sha2-nistp256")
        w.string(inner.bytes)
        return w.bytes
    }
}

// MARK: RSA via Security.framework

/// SecKey is thread-safe but not annotated Sendable.
final class RSAAgentKey: AgentKey, @unchecked Sendable {
    let key: SecKey
    let comment: String
    let publicKeyBlob: [UInt8]
    var keyType: String { "ssh-rsa" }

    init(key: SecKey, comment: String) throws {
        self.key = key
        self.comment = comment
        guard let pub = SecKeyCopyPublicKey(key) else { throw KeyError.security("no public key", nil) }
        var err: Unmanaged<CFError>?
        guard let pubDER = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
            throw KeyError.security("export RSA public key: \(err!.takeRetainedValue())", nil)
        }
        // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
        var der = DER(Array(pubDER))
        var seq = try der.sequence()
        let n = try seq.integer()
        let e = try seq.integer()
        var w = WireWriter()
        w.string("ssh-rsa")
        w.mpint(unsigned: e)
        w.mpint(unsigned: n)
        publicKeyBlob = w.bytes
    }

    func sign(_ data: [UInt8], flags: UInt32) throws -> [UInt8] {
        let alg: SecKeyAlgorithm
        let name: String
        if flags & AgentMsg.rsaSHA2_512 != 0 {
            (alg, name) = (.rsaSignatureMessagePKCS1v15SHA512, "rsa-sha2-512")
        } else if flags & AgentMsg.rsaSHA2_256 != 0 {
            (alg, name) = (.rsaSignatureMessagePKCS1v15SHA256, "rsa-sha2-256")
        } else {
            throw KeyError.unsupportedFlags(flags)
        }
        var err: Unmanaged<CFError>?
        // The "Message" algorithms hash for us (like CryptoKit's signature(for:)).
        guard let sig = SecKeyCreateSignature(key, alg, Data(data) as CFData, &err) as Data? else {
            throw KeyError.security("RSA sign: \(err!.takeRetainedValue())", nil)
        }
        var w = WireWriter()
        w.string(name)
        w.string(Array(sig))
        return w.bytes
    }

    static func generate(bits: Int = 3072) throws -> SecKey {
        // Not permanent: the key lives only in memory; we persist its PKCS#1 DER ourselves.
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw KeyError.security("RSA generate: \(err!.takeRetainedValue())", nil)
        }
        return k
    }

    static func privateDER(_ key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let d = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw KeyError.security("RSA export: \(err!.takeRetainedValue())", nil)
        }
        return d
    }

    static func load(privateDER: Data) throws -> SecKey {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateWithData(privateDER as CFData, attrs as CFDictionary, &err) else {
            throw KeyError.security("RSA import: \(err!.takeRetainedValue())", nil)
        }
        return k
    }
}

/// Just enough DER to read PKCS#1 RSAPublicKey.
struct DER {
    var r: WireReaderBytes
    init(_ b: [UInt8]) { r = WireReaderBytes(b) }

    private mutating func tlv(expect tag: UInt8) throws -> [UInt8] {
        guard try r.next() == tag else { throw KeyError.security("DER: unexpected tag", nil) }
        var len = Int(try r.next())
        if len & 0x80 != 0 {
            let n = len & 0x7f
            len = 0
            for _ in 0..<n { len = len << 8 | Int(try r.next()) }
        }
        return try r.take(len)
    }

    mutating func sequence() throws -> DER { DER(try tlv(expect: 0x30)) }
    mutating func integer() throws -> [UInt8] { try tlv(expect: 0x02) }
}

struct WireReaderBytes {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { self.b = b }
    mutating func next() throws -> UInt8 {
        guard i < b.count else { throw KeyError.security("DER: truncated", nil) }
        defer { i += 1 }
        return b[i]
    }
    mutating func take(_ n: Int) throws -> [UInt8] {
        guard i + n <= b.count else { throw KeyError.security("DER: truncated", nil) }
        defer { i += n }
        return Array(b[i..<i + n])
    }
}
