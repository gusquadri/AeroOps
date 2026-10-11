import Foundation

/// A truncated or malformed SSH wire-format value (RFC 4251 §5).
public enum SSHWireError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The data ended while reading the named field.
    case truncated(String)
    /// The named field has an invalid value.
    case malformed(String)

    public var description: String {
        switch self {
        case .truncated(let what): "truncated data while reading \(what)"
        case .malformed(let what): "malformed \(what)"
        }
    }
}

/// Builds SSH wire-format data: `byte`, `boolean`, `uint32`, `string` and `mpint` (RFC 4251 §5).
struct SSHWriter: Sendable {
    private(set) var bytes: [UInt8] = []

    init() {}

    mutating func byte(_ value: UInt8) { bytes.append(value) }

    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }

    mutating func uint32(_ value: UInt32) {
        bytes.append(contentsOf: [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    /// SSH `string`: a `uint32` length followed by the raw bytes.
    mutating func string(_ value: some Collection<UInt8>) {
        uint32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    /// SSH `string` holding UTF-8 text.
    mutating func string(_ value: String) { string(Array(value.utf8)) }

    /// SSH `mpint` from an unsigned big-endian magnitude.
    ///
    /// Leading zero bytes are stripped, then `0x00` is prepended when the top bit is set so the
    /// value stays positive. About half of all ECDSA `r`/`s` values need that pad, so getting it
    /// wrong makes logins fail intermittently.
    mutating func mpint(unsigned magnitude: some Collection<UInt8>) {
        var m = Array(magnitude.drop(while: { $0 == 0 }))
        if let first = m.first, first & 0x80 != 0 { m.insert(0, at: 0) }
        string(m)
    }

    /// Appends bytes without a length prefix.
    mutating func raw(_ value: some Collection<UInt8>) { bytes.append(contentsOf: value) }

    /// Wraps an agent message payload in its `uint32` length frame.
    static func frame(_ payload: [UInt8]) -> [UInt8] {
        var w = SSHWriter()
        w.string(payload)
        return w.bytes
    }
}

/// Reads SSH wire-format data. Every read checks bounds and throws ``SSHWireError`` instead of trapping.
struct SSHReader: Sendable {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ data: Data) { self.bytes = Array(data) }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func byte(_ what: String = "byte") throws(SSHWireError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated(what) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bool(_ what: String = "boolean") throws(SSHWireError) -> Bool {
        try byte(what) != 0
    }

    mutating func uint32(_ what: String = "uint32") throws(SSHWireError) -> UInt32 {
        guard remaining >= 4 else { throw .truncated(what) }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string(_ what: String = "string") throws(SSHWireError) -> [UInt8] {
        let count = Int(try uint32(what))
        guard remaining >= count else { throw .truncated(what) }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// An SSH `string` decoded as UTF-8 (invalid sequences are replaced, never trapped on).
    mutating func text(_ what: String = "string") throws(SSHWireError) -> String {
        String(decoding: try string(what), as: UTF8.self)
    }

    /// An SSH `mpint` that must be non-negative, returned as its unsigned big-endian magnitude
    /// without leading zero bytes (zero is the empty array).
    mutating func unsignedMPInt(_ what: String = "mpint") throws(SSHWireError) -> [UInt8] {
        let raw = try string(what)
        if let first = raw.first, first & 0x80 != 0 { throw .malformed("\(what) (negative)") }
        return Array(raw.drop(while: { $0 == 0 }))
    }

    /// Reads exactly `count` raw bytes.
    mutating func raw(_ count: Int, _ what: String = "bytes") throws(SSHWireError) -> [UInt8] {
        guard count >= 0, remaining >= count else { throw .truncated(what) }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// The unread bytes.
    mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }
}

/// Left-pads (or validates) an unsigned big-endian magnitude to exactly `width` bytes.
func fixedWidth(_ magnitude: [UInt8], _ width: Int) -> [UInt8]? {
    let trimmed = Array(magnitude.drop(while: { $0 == 0 }))
    guard trimmed.count <= width else { return nil }
    return Array(repeating: 0, count: width - trimmed.count) + trimmed
}
