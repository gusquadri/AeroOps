// SSH wire encoding (RFC 4251 §5) as used by draft-miller-ssh-agent.
import Foundation

enum WireError: Error, CustomStringConvertible {
    case truncated(String)
    case tooLarge(Int)

    var description: String {
        switch self {
        case .truncated(let what): "truncated message while reading \(what)"
        case .tooLarge(let n): "message too large: \(n) bytes"
        }
    }
}

struct WireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u32(_ v: UInt32) {
        bytes.append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    /// SSH `string`: uint32 length + raw bytes.
    mutating func string(_ b: some Collection<UInt8>) {
        u32(UInt32(b.count))
        bytes.append(contentsOf: b)
    }

    mutating func string(_ s: String) { string(Array(s.utf8)) }

    /// SSH `mpint` from an unsigned big-endian magnitude: strip leading zero
    /// bytes, then prepend 0x00 if the top bit is set so the value stays positive.
    mutating func mpint(unsigned magnitude: some Collection<UInt8>) {
        var m = Array(magnitude.drop(while: { $0 == 0 }))
        if let first = m.first, first & 0x80 != 0 { m.insert(0, at: 0) }
        string(m)
    }

    /// Wraps the payload as an agent message: uint32 length + payload.
    static func frame(_ payload: [UInt8]) -> [UInt8] {
        var w = WireWriter()
        w.u32(UInt32(payload.count))
        w.bytes.append(contentsOf: payload)
        return w.bytes
    }
}

struct WireReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func u8(_ what: String = "byte") throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated(what) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u32(_ what: String = "uint32") throws -> UInt32 {
        guard remaining >= 4 else { throw WireError.truncated(what) }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string(_ what: String = "string") throws -> [UInt8] {
        let n = Int(try u32(what))
        guard remaining >= n else { throw WireError.truncated(what) }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
}

/// Agent message numbers (draft-miller-ssh-agent §6.1).
enum AgentMsg {
    static let failure: UInt8 = 5
    static let success: UInt8 = 6
    static let requestIdentities: UInt8 = 11
    static let identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13
    static let signResponse: UInt8 = 14
    static let extensionRequest: UInt8 = 27

    static let rsaSHA2_256: UInt32 = 2
    static let rsaSHA2_512: UInt32 = 4

    static func name(_ t: UInt8) -> String {
        switch t {
        case 11: "REQUEST_IDENTITIES"
        case 13: "SIGN_REQUEST"
        case 17: "ADD_IDENTITY"
        case 18: "REMOVE_IDENTITY"
        case 19: "REMOVE_ALL_IDENTITIES"
        case 20: "ADD_SMARTCARD_KEY"
        case 21: "REMOVE_SMARTCARD_KEY"
        case 22: "LOCK"
        case 23: "UNLOCK"
        case 25: "ADD_ID_CONSTRAINED"
        case 26: "ADD_SMARTCARD_KEY_CONSTRAINED"
        case 27: "EXTENSION"
        default: "type \(t)"
        }
    }
}

extension Collection<UInt8> {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
