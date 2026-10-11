import CryptoKit
import Foundation

/// An SSH public key in wire format (the "key blob"), with its OpenSSH presentations.
///
/// ```swift
/// let key = try SSHPublicKey(authorizedKeysLine: "ssh-ed25519 AAAAC3Nza... me@mac")
/// key.fingerprint            // "SHA256:…", as printed by `ssh-keygen -lf`
/// ```
public struct SSHPublicKey: Sendable, Hashable {
    /// The wire-format blob: `string type || key-specific fields`.
    public let blob: Data
    /// The key type named inside the blob, e.g. `ssh-ed25519`.
    public let keyType: String

    /// Wraps a wire-format blob. Throws if it does not start with a key type string.
    public init(blob: Data) throws(SSHWireError) {
        var reader = SSHReader(blob)
        let type = try reader.text("key type")
        guard !type.isEmpty, type.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { throw .malformed("key type") }
        self.blob = blob
        self.keyType = type
    }

    /// Parses an `authorized_keys` / `.pub` line: `type base64-blob [comment]`.
    /// Options before the key type (as allowed in `authorized_keys`) are not supported.
    public init(authorizedKeysLine line: String) throws(SSHWireError) {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 2, let data = Data(base64Encoded: fields[1]) else { throw .malformed("authorized_keys line") }
        try self.init(blob: data)
        guard keyType == fields[0] else { throw .malformed("authorized_keys line (key type does not match blob)") }
    }

    /// The OpenSSH SHA-256 fingerprint: `SHA256:` + unpadded base64 of SHA-256(blob).
    public var fingerprint: String { Self.fingerprint(of: blob) }

    /// One `authorized_keys` line. Control characters in `comment` are replaced by spaces.
    public func authorizedKeysLine(comment: String?) -> String {
        let base = "\(keyType) \(blob.base64EncodedString())"
        guard let comment = comment.map(Self.sanitizedComment), !comment.isEmpty else { return base }
        return "\(base) \(comment)"
    }

    /// The OpenSSH SHA-256 fingerprint of a public key blob.
    public static func fingerprint(of blob: some DataProtocol) -> String {
        let digest = SHA256.hash(data: Data(blob))
        return "SHA256:" + Data(digest).base64EncodedString().replacing("=", with: "")
    }

    /// A comment safe for a one-line `authorized_keys` entry: control characters become
    /// spaces, and leading or trailing whitespace is trimmed.
    public static func sanitizedComment(_ comment: String) -> String {
        String(comment.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Builders for the public key blobs of the key types the agent serves.
enum PublicKeyBlob {
    /// `string "ssh-ed25519" || string pub32`.
    static func ed25519(_ publicKey: some Collection<UInt8>) -> [UInt8] {
        var w = SSHWriter()
        w.string("ssh-ed25519")
        w.string(publicKey)
        return w.bytes
    }

    /// `string "ecdsa-sha2-nistp256" || string "nistp256" || string Q`, Q = `04 || X || Y` (65 bytes).
    static func ecdsaP256(x963 q: some Collection<UInt8>) -> [UInt8] {
        var w = SSHWriter()
        w.string("ecdsa-sha2-nistp256")
        w.string("nistp256")
        w.string(q)
        return w.bytes
    }

    /// `string "ssh-rsa" || mpint e || mpint n`. Note that e comes before n.
    static func rsa(exponent e: [UInt8], modulus n: [UInt8]) -> [UInt8] {
        var w = SSHWriter()
        w.string("ssh-rsa")
        w.mpint(unsigned: e)
        w.mpint(unsigned: n)
        return w.bytes
    }
}
