/// Why Termius's storage could not be read.
public enum StorageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The bytes don't follow the format; `what` names the structure.
    case corrupt(String)
    /// A file could not be read.
    case unreadable(path: String, reason: String)

    public var description: String {
        switch self {
        case .corrupt(let what): "damaged data (\(what))"
        case .unreadable(let path, let reason): "can't read \(path): \(reason)"
        }
    }
}

/// A bounds-checked reader over bytes. Every read throws ``StorageError/corrupt(_:)`` instead
/// of trapping, because the input is another app's files.
struct ByteCursor {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: Int { max(0, bytes.count - offset) }

    func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    mutating func byte(_ what: String) throws(StorageError) -> UInt8 {
        guard offset < bytes.count else { throw .corrupt("\(what) truncated") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func take(_ count: Int, _ what: String) throws(StorageError) -> [UInt8] {
        guard count >= 0, count <= remaining else { throw .corrupt("\(what) truncated") }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func skip(_ count: Int, _ what: String) throws(StorageError) {
        guard count >= 0, count <= remaining else { throw .corrupt("\(what) truncated") }
        offset += count
    }

    /// LEB128 (LevelDB, Chromium and V8 varints), at most 64 bits.
    mutating func varint(_ what: String) throws(StorageError) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let next = try byte(what)
            guard shift < 64 else { throw .corrupt("\(what) varint too long") }
            result |= UInt64(next & 0x7F) << shift
            if next < 0x80 { return result }
            shift += 7
        }
    }

    /// A varint that must fit an `Int` length.
    mutating func length(_ what: String) throws(StorageError) -> Int {
        let value = try varint(what)
        guard value <= UInt64(Int32.max) else { throw .corrupt("\(what) too large") }
        return Int(value)
    }

    mutating func littleEndian(_ width: Int, _ what: String) throws(StorageError) -> UInt64 {
        let raw = try take(width, what)
        return raw.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}

extension Array where Element == UInt8 {
    /// Little-endian unsigned integer of the first `width` bytes from `start`.
    func littleEndian(at start: Int, width: Int) -> UInt64 {
        (0..<width).reversed().reduce(0) { $0 << 8 | UInt64(self[start + $1]) }
    }
}
