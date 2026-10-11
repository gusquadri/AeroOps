import CryptoKit
import Foundation

/// A server's public host key in OpenSSH wire format.
public struct HostKey: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The algorithm name, e.g. `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`.
    public let type: String
    /// The key blob (what known_hosts stores base64-encoded).
    public let blob: Data

    /// Parses the `type` and base64 fields of a known_hosts or `ssh-keyscan` line.
    /// The blob must decode and must start with the same algorithm name.
    public init(type: String, base64: String) throws(HostKeyError) {
        guard let blob = Data(base64Encoded: base64), !blob.isEmpty else {
            throw .invalidKey("\(type) key is not valid base64")
        }
        var reader = WireReader(blob)
        guard let embedded = reader.string(), String(decoding: embedded, as: UTF8.self) == type else {
            throw .invalidKey("\(type) key blob does not match its type")
        }
        self.type = type
        self.blob = blob
    }

    /// The blob, base64-encoded as in known_hosts.
    public var base64: String { blob.base64EncodedString() }

    /// `SHA256:<base64 without padding>`, exactly as `ssh-keygen -lf` and ssh's prompts print it.
    public var fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Short algorithm label as printed by `ssh-keygen -l`: `ED25519`, `ECDSA`, `RSA`, ...
    public var displayType: String {
        switch type {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case "sk-ssh-ed25519@openssh.com": "ED25519-SK"
        case "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK"
        case let other where other.hasPrefix("ecdsa-sha2-"): "ECDSA"
        default: type
        }
    }

    /// Key size in bits as printed by `ssh-keygen -l`, when known for the algorithm.
    public var bits: Int? {
        switch type {
        case "ssh-ed25519", "sk-ssh-ed25519@openssh.com", "ecdsa-sha2-nistp256", "sk-ecdsa-sha2-nistp256@openssh.com":
            return 256
        case "ecdsa-sha2-nistp384":
            return 384
        case "ecdsa-sha2-nistp521":
            return 521
        case "ssh-rsa":
            var reader = WireReader(blob)
            _ = reader.string() // type
            _ = reader.string() // e
            return reader.string().map(Self.bitLength)
        case "ssh-dss":
            var reader = WireReader(blob)
            _ = reader.string() // type
            return reader.string().map(Self.bitLength) // p
        default:
            return nil
        }
    }

    /// `ED25519 SHA256:...`.
    public var description: String { "\(displayType) \(fingerprint)" }

    /// Bit length of an unsigned big-endian mpint.
    private static func bitLength(_ bytes: Data) -> Int {
        guard let index = bytes.firstIndex(where: { $0 != 0 }) else { return 0 }
        let leading = bytes[index]
        return (bytes.endIndex - index - 1) * 8 + (8 - leading.leadingZeroBitCount)
    }

    // MARK: Codable (as the two known_hosts fields)

    private enum CodingKeys: String, CodingKey { case type, key }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            type: container.decode(String.self, forKey: .type),
            base64: container.decode(String.self, forKey: .key)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(base64, forKey: .key)
    }
}

/// Reads SSH wire-format `string`s (uint32 big-endian length + bytes).
private struct WireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func string() -> Data? {
        guard data.endIndex - offset >= 4 else { return nil }
        let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        offset += 4
        guard length >= 0, data.endIndex - offset >= length else { return nil }
        defer { offset += length }
        return data[offset..<offset + length]
    }
}

/// Host-key and known_hosts failures.
public enum HostKeyError: Error, Sendable, Hashable, LocalizedError {
    /// A key that does not parse.
    case invalidKey(String)
    /// The host's address or port cannot be scanned.
    case invalidHost(String)
    /// known_hosts exists but cannot be read.
    case knownHostsUnreadable(String)
    /// known_hosts could not be written.
    case knownHostsWriteFailed(String)
    /// ``HostKeyStore/trust(_:for:replacingPinned:)`` would add a key of a type that already has
    /// a different pinned key. Pass `replacingPinned: true` after the user confirmed the change.
    case conflictsWithPinnedKey(pinned: [HostKey])

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let reason): "Invalid host key: \(reason)."
        case .invalidHost(let reason): "Invalid host: \(reason)."
        case .knownHostsUnreadable(let reason): "Could not read known_hosts: \(reason)"
        case .knownHostsWriteFailed(let reason): "Could not write known_hosts: \(reason)"
        case .conflictsWithPinnedKey(let pinned):
            "A different key is already trusted for this host (\(pinned.map(\.description).joined(separator: ", ")))."
        }
    }
}
