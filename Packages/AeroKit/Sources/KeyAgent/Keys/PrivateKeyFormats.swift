import CryptoKit
import Foundation

/// Private key formats other than `openssh-key-v1`, read into the same ``OpenSSHPrivateKey``:
///
/// - PEM: PKCS#1 `RSA PRIVATE KEY`, SEC1 `EC PRIVATE KEY` (P-256) and unencrypted PKCS#8
///   `PRIVATE KEY` (RSA, P-256, Ed25519). Encrypted PEM is refused as ``KeyImportError/encrypted(cipher:kdf:)``.
/// - PuTTY `.ppk` versions 2 and 3, unencrypted, with the file's MAC checked.
///
/// Every key is checked the same way as an OpenSSH one: RSA of at least 1024 bits, and a
/// sign-and-verify self-test.
extension OpenSSHPrivateKey {
    /// Parses a private key in any supported format. Text in no known format throws what
    /// ``parse(_:)`` throws.
    static func parseAnyFormat(_ text: String) throws(KeyImportError) -> OpenSSHPrivateKey {
        do {
            return try otherFormat(text) ?? parse(text)
        } catch let error as KeyImportError {
            throw error
        } catch let error as SSHWireError {
            throw .malformed(error.description)
        } catch {
            throw .malformed(String(describing: error))
        }
    }

    /// The key when `text` is a PuTTY or PEM key; `nil` for anything else, OpenSSH included.
    private static func otherFormat(_ text: String) throws -> OpenSSHPrivateKey? {
        if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return nil }
        if text.hasPrefix(PuTTYKeyFile.prefix) || text.contains("\n" + PuTTYKeyFile.prefix) {
            return try PuTTYKeyFile.parse(text)
        }
        return try PEMBlock(text)?.privateKey()
    }

    /// An RSA key from its components: checked, self-tested, stored as PKCS#1 DER.
    static func rsa(_ components: RSAPrivateComponents, comment: String) throws -> OpenSSHPrivateKey {
        let bits = BigUInt(bigEndian: components.modulus).bitWidth
        guard bits >= 1024 else { throw KeyImportError.rsaKeyTooSmall(bits: bits) }
        let der = Data(try components.pkcs1DER())
        let key: RSASigningKey
        do {
            key = try RSASigningKey(pkcs1DER: der)
        } catch {
            throw KeyImportError.malformed("Security.framework rejected the RSA key: \(error)")
        }
        guard key.publicKeyBlob == PublicKeyBlob.rsa(exponent: components.publicExponent, modulus: components.modulus) else {
            throw KeyImportError.inconsistentKey("RSA public key differs")
        }
        return try checked(.rsa, secret: der, key: key, comment: comment)
    }

    static func ed25519(seed: [UInt8], comment: String) throws -> OpenSSHPrivateKey {
        guard seed.count == 32 else { throw KeyImportError.malformed("ed25519 seed length") }
        let key = Ed25519SigningKey(privateKey: try .init(rawRepresentation: seed))
        return try checked(.ed25519, secret: Data(seed), key: key, comment: comment)
    }

    static func p256(_ privateKey: P256.Signing.PrivateKey, comment: String) throws -> OpenSSHPrivateKey {
        try checked(.ecdsaP256, secret: privateKey.rawRepresentation, key: P256SigningKey(privateKey: privateKey), comment: comment)
    }

    private static func checked(_ algorithm: SSHKeyAlgorithm, secret: Data, key: any SSHSigningKey, comment: String) throws -> OpenSSHPrivateKey {
        try selfTest(key)
        return OpenSSHPrivateKey(algorithm: algorithm, comment: comment, publicKeyBlob: key.publicKeyBlob, secret: secret, signingKey: key)
    }
}

/// One `-----BEGIN <label>-----` block: its label, RFC 1421 headers and decoded body.
struct PEMBlock {
    var label: String
    var headers: [String: String]
    var der: [UInt8]

    init?(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") }) else { return nil }
        label = String(lines[start].dropFirst(11).dropLast(5))
        guard let end = lines[(start + 1)...].firstIndex(of: "-----END \(label)-----") else { return nil }
        let (headers, body) = Self.headersAndBody(lines[(start + 1)..<end])
        guard let data = Data(base64Encoded: body) else { return nil }
        self.headers = headers
        der = Array(data)
    }

    /// RFC 1421 `Name: value` headers come before the base64 body.
    private static func headersAndBody(_ lines: ArraySlice<String>) -> (headers: [String: String], body: String) {
        var headers: [String: String] = [:]
        var body = ""
        for line in lines {
            if body.isEmpty, let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                body += line
            }
        }
        return (headers, body)
    }

    /// Algorithm OIDs, as their DER-encoded contents.
    private static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let ed25519: [UInt8] = [0x2B, 0x65, 0x70]

    func privateKey() throws -> OpenSSHPrivateKey {
        try refuseEncrypted()
        switch label {
        case "RSA PRIVATE KEY":
            return try OpenSSHPrivateKey.rsa(Self.pkcs1(der), comment: "")
        case "EC PRIVATE KEY":
            return try Self.ec(der)
        case "PRIVATE KEY":
            return try Self.pkcs8(der)
        case "ENCRYPTED PRIVATE KEY":
            throw KeyImportError.encrypted(cipher: "PKCS#8", kdf: "PBES2")
        case "DSA PRIVATE KEY":
            throw KeyImportError.unsupportedKeyType("ssh-dss")
        default:
            throw KeyImportError.notOpenSSHFormat(detected: "PEM (\(label))")
        }
    }

    /// Legacy OpenSSL encryption: `Proc-Type: 4,ENCRYPTED` and `DEK-Info: <cipher>,<iv>`.
    private func refuseEncrypted() throws {
        guard headers["proc-type"]?.uppercased().contains("ENCRYPTED") == true else { return }
        let cipher = headers["dek-info"]?.split(separator: ",").first.map(String.init) ?? "unknown"
        throw KeyImportError.encrypted(cipher: cipher, kdf: "PEM")
    }

    /// PKCS#1 `RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }`.
    static func pkcs1(_ der: [UInt8]) throws -> RSAPrivateComponents {
        var outer = DERReader(der)
        var key = try outer.sequence("RSAPrivateKey")
        guard try key.unsignedInteger("version").isEmpty else { throw KeyImportError.unsupportedKeyType("multi-prime RSA") }
        let n = try key.unsignedInteger("modulus")
        let e = try key.unsignedInteger("publicExponent")
        let d = try key.unsignedInteger("privateExponent")
        let p = try key.unsignedInteger("prime1")
        let q = try key.unsignedInteger("prime2")
        _ = try key.unsignedInteger("exponent1")
        _ = try key.unsignedInteger("exponent2")
        let qInv = try key.unsignedInteger("coefficient")
        return RSAPrivateComponents(modulus: n, publicExponent: e, privateExponent: d, iqmp: qInv, prime1: p, prime2: q)
    }

    /// SEC1 `ECPrivateKey` (or PKCS#8 around one) on P-256. CryptoKit reads named curves; keys
    /// written with explicit curve parameters (ssh-keygen with LibreSSL does this) are read by
    /// ``sec1(_:)``.
    /// `sec1Key` is the `ECPrivateKey` inside a PKCS#8 `der`; `nil` when `der` is one.
    private static func ec(_ der: [UInt8], sec1Key: [UInt8]? = nil) throws -> OpenSSHPrivateKey {
        let privateKey: P256.Signing.PrivateKey
        if let named = try? P256.Signing.PrivateKey(derRepresentation: der) {
            privateKey = named
        } else if let explicit = try sec1(sec1Key ?? der) {
            privateKey = explicit
        } else {
            throw KeyImportError.unsupportedKeyType("EC key (only P-256 is supported)")
        }
        return try OpenSSHPrivateKey.p256(privateKey, comment: "")
    }

    /// `ECPrivateKey ::= SEQUENCE { version 1, privateKey OCTET STRING, [0] parameters, [1] publicKey }`.
    ///
    /// The 32-byte scalar is taken as a P-256 key only when the curve is named P-256, or when
    /// the parameters are explicit and the file's public key is the scalar's point on P-256
    /// (which a key on any other curve can't match). `nil` for anything else.
    private static func sec1(_ der: [UInt8]) throws -> P256.Signing.PrivateKey? {
        guard let fields = try ECPrivateKeyFields(der), fields.scalar.count == 32,
              let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: fields.scalar) else { return nil }
        guard let point = fields.publicPoint else { return fields.namedP256 ? privateKey : nil }
        return point == Array(privateKey.publicKey.x963Representation) ? privateKey : nil
    }

    /// PKCS#8 `PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, OCTET STRING key }`.
    private static func pkcs8(_ der: [UInt8]) throws -> OpenSSHPrivateKey {
        var outer = DERReader(der)
        var info = try outer.sequence("PrivateKeyInfo")
        _ = try info.unsignedInteger("version")
        var algorithm = try info.sequence("AlgorithmIdentifier")
        let oid = try algorithm.element(tag: 0x06, "algorithm")
        let key = try info.element(tag: 0x04, "privateKey")
        switch oid {
        case rsaEncryption:
            return try OpenSSHPrivateKey.rsa(pkcs1(key), comment: "")
        case ecPublicKey:
            return try ec(der, sec1Key: key)
        case ed25519:
            return try OpenSSHPrivateKey.ed25519(seed: ed25519Seed(key), comment: "")
        default:
            throw KeyImportError.unsupportedKeyType("PKCS#8 key")
        }
    }
}

/// The fields of a SEC1 `ECPrivateKey` that tell which curve it is on.
private struct ECPrivateKeyFields {
    private static let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]

    var scalar: [UInt8]
    /// The parameters name P-256, rather than spelling a curve out.
    var namedP256 = false
    /// The uncompressed public point, when the key includes it.
    var publicPoint: [UInt8]?

    /// `nil` when the version isn't 1, the curve is named but isn't P-256, or the public key is malformed.
    init?(_ der: [UInt8]) throws {
        var outer = DERReader(der)
        var key = try outer.sequence("ECPrivateKey")
        guard try key.unsignedInteger("version") == [1] else { return nil }
        scalar = try key.element(tag: 0x04, "privateKey")
        if key.nextTag == 0xA0 {
            guard let named = try Self.namesP256(key.element(tag: 0xA0, "parameters")) else { return nil }
            namedP256 = named
        }
        if key.nextTag == 0xA1 {
            guard let point = try Self.point(key.element(tag: 0xA1, "publicKey")) else { return nil }
            publicPoint = point
        }
    }

    /// `true` for the named curve P-256, `false` for explicit parameters, `nil` for another named curve.
    private static func namesP256(_ parameters: [UInt8]) throws -> Bool? {
        var reader = DERReader(parameters)
        guard reader.nextTag == 0x06 else { return false }
        return try reader.element(tag: 0x06, "curve") == prime256v1 ? true : nil
    }

    /// The BIT STRING's point; `nil` when it has unused bits.
    private static func point(_ wrapper: [UInt8]) throws -> [UInt8]? {
        var reader = DERReader(wrapper)
        let bits = try reader.element(tag: 0x03, "publicKey bits")
        return bits.first == 0 ? Array(bits.dropFirst()) : nil
    }
}

/// `CurvePrivateKey ::= OCTET STRING`, the 32-byte seed.
private func ed25519Seed(_ key: [UInt8]) throws -> [UInt8] {
    var inner = DERReader(key)
    return try inner.element(tag: 0x04, "Ed25519 seed")
}

/// PuTTY's `.ppk` key file (PuTTY manual, appendix C), unencrypted versions 2 and 3.
///
/// The MAC covers the algorithm, encryption, comment, public blob and private blob, each as an
/// SSH `string`. Version 2 uses HMAC-SHA-1 keyed with SHA-1 of `putty-private-key-file-mac-key`
/// (plus the empty passphrase); version 3 uses HMAC-SHA-256 with an empty key.
struct PuTTYKeyFile {
    static let prefix = "PuTTY-User-Key-File-"

    var version: Int
    var algorithm: String
    var encryption: String
    var comment: String
    var publicBlob: [UInt8]
    var privateBlob: [UInt8]
    var mac: String

    static func parse(_ text: String) throws -> OpenSSHPrivateKey {
        let file = try PuTTYKeyFile(text)
        guard file.mac == file.expectedMAC() else { throw KeyImportError.inconsistentKey("PuTTY key file MAC does not match") }
        let key = try file.key()
        guard key.publicKeyBlob == file.publicBlob else {
            throw KeyImportError.inconsistentKey("private key does not match the file's public key")
        }
        return key
    }

    /// Reads the fields in order, stopping at the encryption line for an encrypted file.
    init(_ text: String) throws {
        var lines = Lines(text)
        version = try Self.version(lines.first)
        algorithm = try lines.header("\(Self.prefix)\(version)")
        encryption = try lines.header("Encryption")
        comment = try lines.header("Comment")
        guard encryption == "none" else {
            throw KeyImportError.encrypted(cipher: encryption, kdf: version == 3 ? "Argon2" : "PuTTY")
        }
        publicBlob = try lines.base64("Public-Lines")
        privateBlob = try lines.base64("Private-Lines")
        mac = try lines.header("Private-MAC").lowercased()
    }

    private static func version(_ line: String?) throws -> Int {
        guard let line, line.hasPrefix(prefix), let version = Int(line.dropFirst(prefix.count).prefix { $0 != ":" }) else {
            throw KeyImportError.malformed("PuTTY key: header")
        }
        guard version == 2 || version == 3 else { throw KeyImportError.unsupportedKeyType("PuTTY key file version \(version)") }
        return version
    }

    private func expectedMAC() -> String {
        let fields = [Array(algorithm.utf8), Array(encryption.utf8), Array(comment.utf8), publicBlob, privateBlob]
        let input = fields.flatMap { withUnsafeBytes(of: UInt32($0.count).bigEndian, Array.init) + $0 }
        guard version == 2 else {
            return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: Data()))).hex
        }
        let macKey = SymmetricKey(data: Insecure.SHA1.hash(data: Array("putty-private-key-file-mac-key".utf8)))
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for: input, using: macKey)).hex
    }

    private func key() throws -> OpenSSHPrivateKey {
        var pub = SSHReader(publicBlob)
        guard try pub.text("key type") == algorithm else { throw KeyImportError.inconsistentKey("PuTTY key type differs") }
        var priv = SSHReader(privateBlob)
        switch algorithm {
        case "ssh-rsa": return try rsa(&pub, &priv)
        case "ssh-ed25519": return try ed25519(&priv)
        case "ecdsa-sha2-nistp256": return try p256(&priv)
        default: throw KeyImportError.unsupportedKeyType(algorithm)
        }
    }

    private func rsa(_ pub: inout SSHReader, _ priv: inout SSHReader) throws -> OpenSSHPrivateKey {
        let e = try pub.unsignedMPInt("rsa e")
        let n = try pub.unsignedMPInt("rsa n")
        let d = try priv.unsignedMPInt("rsa d")
        let p = try priv.unsignedMPInt("rsa p")
        let q = try priv.unsignedMPInt("rsa q")
        let iqmp = try priv.unsignedMPInt("rsa iqmp")
        let components = RSAPrivateComponents(modulus: n, publicExponent: e, privateExponent: d, iqmp: iqmp, prime1: p, prime2: q)
        return try .rsa(components, comment: comment)
    }

    /// PuTTY writes the private integer little-endian, which is the seed as is.
    private func ed25519(_ priv: inout SSHReader) throws -> OpenSSHPrivateKey {
        var seed = try priv.string("ed25519 private key")
        if seed.count == 33, seed.last == 0 { seed.removeLast() }
        while seed.count < 32 { seed.append(0) }
        return try .ed25519(seed: seed, comment: comment)
    }

    private func p256(_ priv: inout SSHReader) throws -> OpenSSHPrivateKey {
        guard let raw = fixedWidth(try priv.unsignedMPInt("ecdsa private scalar"), 32) else {
            throw KeyImportError.malformed("ecdsa private scalar too long")
        }
        return try .p256(P256.Signing.PrivateKey(rawRepresentation: raw), comment: comment)
    }

    /// The file's lines from the header on, read front to back.
    private struct Lines {
        private var lines: ArraySlice<String>

        init(_ text: String) {
            lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }[...]
                .drop { !$0.hasPrefix(PuTTYKeyFile.prefix) }
        }

        var first: String? { lines.first }

        mutating func header(_ name: String) throws -> String {
            guard let line = lines.first, line.hasPrefix(name + ":") else {
                throw KeyImportError.malformed("PuTTY key: missing \(name)")
            }
            lines.removeFirst()
            return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        }

        /// A line count, then that many lines of base64.
        mutating func base64(_ name: String) throws -> [UInt8] {
            guard let count = Int(try header(name)), (0...4096).contains(count), lines.count >= count else {
                throw KeyImportError.malformed("PuTTY key: \(name)")
            }
            let body = lines.prefix(count).joined()
            lines.removeFirst(count)
            guard let data = Data(base64Encoded: body) else { throw KeyImportError.malformed("PuTTY key: invalid base64") }
            return Array(data)
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
