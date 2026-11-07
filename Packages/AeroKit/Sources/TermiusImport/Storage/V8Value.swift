/// A JavaScript value as V8's `ValueSerializer` writes it for IndexedDB (structured clone).
///
/// Only what plain data rows hold is modelled; anything else (regexps, buffers, host objects)
/// reads as ``other``.
enum JSValue: Equatable, Sendable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSValue])
    /// Property names in serialization order are not kept; numeric names become strings.
    case object([String: JSValue])
    /// Milliseconds since 1970.
    case date(Double)
    case other

    subscript(key: String) -> JSValue? {
        if case .object(let properties) = self { properties[key] } else { nil }
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var isObject: Bool {
        if case .object = self { true } else { false }
    }

    var isNullish: Bool {
        self == .null || self == .undefined
    }
}

/// Reads a V8 `ValueSerializer` payload (the bytes after the `0xFF <version>` header).
/// Format: v8/src/objects/value-serializer.cc.
struct V8Deserializer {
    private var cursor: ByteCursor
    /// Objects in the order they were opened, for `^` back-references.
    private var objects: [JSValue?] = []
    private var depth = 0
    static let maxDepth = 64

    init(_ bytes: [UInt8], offset: Int = 0) {
        cursor = ByteCursor(bytes, offset: offset)
    }

    /// Reads the version header(s) and one value.
    static func value(from bytes: [UInt8], offset: Int = 0) throws(StorageError) -> JSValue {
        var reader = V8Deserializer(bytes, offset: offset)
        if reader.cursor.peek() == 0xFF {
            _ = try reader.cursor.byte("v8 version tag")
            _ = try reader.cursor.varint("v8 version")
        }
        return try reader.readValue()
    }

    mutating func readValue() throws(StorageError) -> JSValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw .corrupt("value nested too deeply") }
        let tag = try nextTag()
        guard let read = Self.readers[tag] else { throw .corrupt("unsupported v8 tag 0x\(String(tag, radix: 16))") }
        return try read(&self)
    }

    /// The next tag, past any alignment padding.
    private mutating func nextTag() throws(StorageError) -> UInt8 {
        var tag = try cursor.byte("v8 tag")
        while tag == 0 { tag = try cursor.byte("v8 tag") }
        return tag
    }

    private typealias Reader = @Sendable (inout V8Deserializer) throws(StorageError) -> JSValue

    private static let readers: [UInt8: Reader] = {
        var table: [Character: Reader] = [
            "_": { _ in .undefined },
            "-": { _ in .undefined },
            "0": { _ in .null },
            "T": { _ in .bool(true) },
            "F": { _ in .bool(false) },
            "I": { reader throws(StorageError) in .number(Double(try reader.zigzag())) },
            "U": { reader throws(StorageError) in .number(Double(try reader.cursor.varint("uint32"))) },
            "N": { reader throws(StorageError) in .number(try reader.double()) },
            "Z": { reader throws(StorageError) in try reader.skipBigInt(); return .other },
            "\"": { reader throws(StorageError) in .string(try reader.latin1String()) },
            "c": { reader throws(StorageError) in .string(try reader.utf16String()) },
            "S": { reader throws(StorageError) in .string(try reader.utf8String()) },
            "^": { reader throws(StorageError) in try reader.backReference() },
            "o": { reader throws(StorageError) in try reader.object() },
            "A": { reader throws(StorageError) in try reader.denseArray() },
            "a": { reader throws(StorageError) in try reader.sparseArray() },
            "s": { reader throws(StorageError) in try reader.wrappedString() },
            "R": { reader throws(StorageError) in try reader.regExp() },
            ";": { reader throws(StorageError) in try reader.collection(end: UInt8(ascii: ":")) },
            "'": { reader throws(StorageError) in try reader.collection(end: UInt8(ascii: ",")) },
        ]
        table.merge(boxed) { $1 }
        return Dictionary(uniqueKeysWithValues: table.map { ($0.key.asciiValue!, $0.value) })
    }()

    /// Boxed primitives, dates and buffers: objects that later `^` references can point at.
    private static let boxed: [Character: Reader] = [
        "D": { reader throws(StorageError) in reader.remember(.date(try reader.double())) },
        "y": { reader in reader.remember(.bool(true)) },
        "x": { reader in reader.remember(.bool(false)) },
        "n": { reader throws(StorageError) in reader.remember(.number(try reader.double())) },
        "z": { reader throws(StorageError) in try reader.skipBigInt(); return reader.remember(.other) },
        "B": { reader throws(StorageError) in
            try reader.cursor.skip(reader.cursor.length("array buffer length"), "array buffer")
            return reader.remember(.other)
        },
    ]

    private mutating func zigzag() throws(StorageError) -> Int64 {
        let raw = try cursor.varint("int32")
        return Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
    }

    private mutating func utf8String() throws(StorageError) -> String {
        String(decoding: try cursor.take(cursor.length("utf8 length"), "utf8 string"), as: UTF8.self)
    }

    private mutating func backReference() throws(StorageError) -> JSValue {
        let id = try cursor.length("object reference")
        guard id < objects.count, let value = objects[id] else { throw .corrupt("object reference") }
        return value
    }

    private mutating func wrappedString() throws(StorageError) -> JSValue {
        let id = reserve()
        let value = try readValue()
        objects[id] = value
        return value
    }

    private mutating func regExp() throws(StorageError) -> JSValue {
        let id = reserve()
        _ = try readValue()
        _ = try cursor.varint("regexp flags")
        objects[id] = .other
        return .other
    }

    private mutating func reserve() -> Int {
        objects.append(nil)
        return objects.count - 1
    }

    private mutating func remember(_ value: JSValue) -> JSValue {
        objects.append(value)
        return value
    }

    private mutating func double() throws(StorageError) -> Double {
        Double(bitPattern: try cursor.littleEndian(8, "double"))
    }

    private mutating func skipBigInt() throws(StorageError) {
        let bitfield = try cursor.varint("bigint bitfield")
        try cursor.skip(Int((bitfield >> 1) & 0x3FFF_FFFF), "bigint digits")
    }

    private mutating func latin1String() throws(StorageError) -> String {
        let bytes = try cursor.take(cursor.length("one-byte string length"), "one-byte string")
        return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    private mutating func utf16String() throws(StorageError) -> String {
        let count = try cursor.length("two-byte string length")
        guard count % 2 == 0 else { throw .corrupt("two-byte string length") }
        let bytes = try cursor.take(count, "two-byte string")
        let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    private mutating func propertyName() throws(StorageError) -> String {
        switch try readValue() {
        case .string(let name): return name
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        default: throw .corrupt("property name")
        }
    }

    /// Properties until `end`, which is followed by a property count (and for arrays, a length).
    private mutating func properties(until end: UInt8, into properties: inout [String: JSValue]) throws(StorageError) {
        while true {
            guard let next = peekSkippingPadding() else { throw .corrupt("object truncated") }
            if next == end {
                _ = try cursor.byte("end tag")
                return
            }
            let name = try propertyName()
            properties[name] = try readValue()
        }
    }

    private mutating func peekSkippingPadding() -> UInt8? {
        while cursor.peek() == 0 { _ = try? cursor.byte("padding") }
        return cursor.peek()
    }

    private mutating func object() throws(StorageError) -> JSValue {
        let id = reserve()
        var values: [String: JSValue] = [:]
        try properties(until: UInt8(ascii: "{"), into: &values)
        _ = try cursor.varint("property count")
        objects[id] = .object(values)
        return .object(values)
    }

    private mutating func denseArray() throws(StorageError) -> JSValue {
        let id = reserve()
        let length = try cursor.length("array length")
        var elements: [JSValue] = []
        elements.reserveCapacity(min(length, 4096))
        for _ in 0..<length { elements.append(try readValue()) }
        var extra: [String: JSValue] = [:]
        try properties(until: UInt8(ascii: "$"), into: &extra)
        _ = try cursor.varint("property count")
        _ = try cursor.varint("array length")
        objects[id] = .array(elements)
        return .array(elements)
    }

    private mutating func sparseArray() throws(StorageError) -> JSValue {
        let id = reserve()
        let length = try cursor.length("sparse array length")
        var values: [String: JSValue] = [:]
        try properties(until: UInt8(ascii: "@"), into: &values)
        _ = try cursor.varint("property count")
        _ = try cursor.varint("array length")
        let elements = (0..<min(length, 4096)).map { values[String($0)] ?? .undefined }
        objects[id] = .array(elements)
        return .array(elements)
    }

    /// Maps and sets: values until `end` and a count. Their contents are not needed.
    private mutating func collection(end: UInt8) throws(StorageError) -> JSValue {
        let id = reserve()
        while true {
            guard let next = peekSkippingPadding() else { throw .corrupt("collection truncated") }
            if next == end {
                _ = try cursor.byte("end tag")
                _ = try cursor.varint("collection count")
                objects[id] = .other
                return .other
            }
            _ = try readValue()
        }
    }
}
