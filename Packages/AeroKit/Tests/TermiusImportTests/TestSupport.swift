import Foundation
@testable import TermiusImport

/// Builds V8 serialized values (v8/src/objects/value-serializer.cc), the way Chromium stores
/// IndexedDB rows, so tests never need a real Termius database.
enum V8 {
    indirect enum Value {
        case null, bool(Bool), int(Int32), double(Double), string(String), utf16(String)
        case object([(String, Value)])
        case array([Value])
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    /// `0xFF 0x0F`, then the value.
    static func serialize(_ value: Value) -> [UInt8] {
        [0xFF, 0x0F] + encode(value)
    }

    static func encode(_ value: Value) -> [UInt8] {
        switch value {
        case .object(let properties):
            var bytes: [UInt8] = [UInt8(ascii: "o")]
            for (name, value) in properties { bytes += encode(.string(name)) + encode(value) }
            return bytes + [UInt8(ascii: "{")] + varint(UInt64(properties.count))
        case .array(let elements):
            var bytes: [UInt8] = [UInt8(ascii: "A")] + varint(UInt64(elements.count))
            for element in elements { bytes += encode(element) }
            return bytes + [UInt8(ascii: "$")] + varint(0) + varint(UInt64(elements.count))
        default:
            return scalar(value)
        }
    }

    private static func scalar(_ value: Value) -> [UInt8] {
        switch value {
        case .null: return [UInt8(ascii: "0")]
        case .bool(let flag): return [UInt8(ascii: flag ? "T" : "F")]
        case .int(let number):
            let zigzag = UInt32(bitPattern: (number << 1) ^ (number >> 31))
            return [UInt8(ascii: "I")] + varint(UInt64(zigzag))
        case .double(let number):
            return [UInt8(ascii: "N")] + withUnsafeBytes(of: number.bitPattern.littleEndian, Array.init)
        default:
            return text(value)
        }
    }

    private static func text(_ value: Value) -> [UInt8] {
        switch value {
        case .string(let text):
            let bytes = Array(text.unicodeScalars.map { UInt8($0.value) })
            return [UInt8(ascii: "\"")] + varint(UInt64(bytes.count)) + bytes
        case .utf16(let text):
            let bytes = text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            return [UInt8(ascii: "c")] + varint(UInt64(bytes.count)) + bytes
        default:
            return []
        }
    }
}

/// A LevelDB directory written by hand: `CURRENT`, a `MANIFEST`, one table and one log.
struct LevelDBFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termius-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Writes `tableEntries` into table 5 (sequence numbers from 1) and `logEntries` into log 6
    /// as one write batch starting at sequence 100. A `nil` value is a deletion.
    func write(tableEntries: [([UInt8], [UInt8]?)], logEntries: [([UInt8], [UInt8]?)], compressTable: Bool = false) throws {
        try Data("MANIFEST-000004\n".utf8).write(to: directory.appendingPathComponent("CURRENT"))

        var edit: [UInt8] = []
        edit += V8.varint(1) + V8.varint(26) + Array("leveldb.BytewiseComparator".utf8)
        edit += V8.varint(2) + V8.varint(6)
        edit += V8.varint(7) + V8.varint(0) + V8.varint(5) + V8.varint(100) + V8.varint(1) + [0x00] + V8.varint(1) + [0xFF]
        try Data(Self.logFile([edit])).write(to: directory.appendingPathComponent("MANIFEST-000004"))

        try Data(Self.table(tableEntries, compressed: compressTable)).write(to: directory.appendingPathComponent("000005.ldb"))

        var batch: [UInt8] = withUnsafeBytes(of: UInt64(100).littleEndian, Array.init)
        batch += withUnsafeBytes(of: UInt32(logEntries.count).littleEndian, Array.init)
        for (key, value) in logEntries {
            if let value {
                batch += [1] + V8.varint(UInt64(key.count)) + key + V8.varint(UInt64(value.count)) + value
            } else {
                batch += [0] + V8.varint(UInt64(key.count)) + key
            }
        }
        try Data(Self.logFile([batch])).write(to: directory.appendingPathComponent("000006.log"))
        try Data(Self.logFile([[0xDE, 0xAD]])).write(to: directory.appendingPathComponent("000003.log"))
    }

    /// Full-type records, no checksum (the reader doesn't verify it).
    static func logFile(_ records: [[UInt8]]) -> [UInt8] {
        records.flatMap { record in
            [0, 0, 0, 0, UInt8(record.count & 0xFF), UInt8(record.count >> 8), 1] + record
        }
    }

    static func block(_ entries: [([UInt8], [UInt8])]) -> [UInt8] {
        var bytes: [UInt8] = []
        for (key, value) in entries {
            bytes += V8.varint(0) + V8.varint(UInt64(key.count)) + V8.varint(UInt64(value.count)) + key + value
        }
        return bytes + [0, 0, 0, 0] + [1, 0, 0, 0]
    }

    static func table(_ entries: [([UInt8], [UInt8]?)], compressed: Bool) -> [UInt8] {
        let internalEntries = entries.enumerated().map { index, entry in
            let trailer = UInt64(index + 1) << 8 | (entry.1 == nil ? 0 : 1)
            return (entry.0 + withUnsafeBytes(of: trailer.littleEndian, Array.init), entry.1 ?? [])
        }
        var data = block(internalEntries)
        if compressed { data = Snappy.literalOnly(data) }
        var file = data + [compressed ? 1 : 0, 0, 0, 0, 0]
        let index = block([([0xFF], V8.varint(0) + V8.varint(UInt64(data.count)))])
        let indexOffset = file.count
        file += index + [0, 0, 0, 0, 0]
        var footer = V8.varint(0) + V8.varint(0) + V8.varint(UInt64(indexOffset)) + V8.varint(UInt64(index.count))
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        footer += withUnsafeBytes(of: Table.magic.littleEndian, Array.init)
        return file + footer
    }
}

extension Snappy {
    /// A valid Snappy stream holding `bytes` as literals.
    static func literalOnly(_ bytes: [UInt8]) -> [UInt8] {
        var output = V8.varint(UInt64(bytes.count))
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(offset + 60, bytes.count)])
            output += [UInt8(chunk.count - 1) << 2] + chunk
            offset += chunk.count
        }
        return output
    }
}

/// IndexedDB keys and values for one database holding one object store.
enum IndexedDBFixture {
    static func utf16BigEndian(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    static func stringWithLength(_ text: String) -> [UInt8] {
        V8.varint(UInt64(text.utf16.count)) + utf16BigEndian(text)
    }

    /// Entries naming database `id` as `name`, with store 1 of the same name holding `rows`.
    static func database(_ name: String, id: UInt8, rows: [[UInt8]]) -> [([UInt8], [UInt8])] {
        var entries: [([UInt8], [UInt8])] = []
        entries.append(([0x00, 0, 0, 0, 201] + stringWithLength("file__0") + stringWithLength(name), V8.varint(UInt64(id))))
        entries.append(([0x00, id, 0, 0, 50] + V8.varint(1) + [0], utf16BigEndian(name)))
        for (index, row) in rows.enumerated() {
            entries.append(([0x00, id, 1, 1, 0x03] + withUnsafeBytes(of: Double(index + 1).bitPattern.littleEndian, Array.init), row))
        }
        return entries
    }

    /// A stored row: record version, Blink's `0xFF 0x14` header, then the V8 value.
    static func row(_ value: V8.Value) -> [UInt8] {
        V8.varint(1) + [0xFF, 0x14] + V8.serialize(value)
    }
}

extension [UInt8] {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }
}
