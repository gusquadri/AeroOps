import Foundation

/// A read-only snapshot of a LevelDB database directory: every live key with its newest value.
///
/// Chromium keeps IndexedDB in LevelDB. This reads it without LevelDB itself:
/// `CURRENT` names the `MANIFEST`, whose version edits list the live table files and the
/// oldest log still needed; tables (`.ldb`/`.sst`) and logs (`.log`) are then merged, newest
/// sequence number winning, deletions dropping the key.
///
/// The database may be open in another process (Termius running). Each file is read whole in
/// one go; a log's torn last record is ignored, as LevelDB's own recovery does.
/// (Formats: https://github.com/google/leveldb/tree/main/doc, `table_format.md`, `log_format.md`.)
struct LevelDBSnapshot {
    /// Live user keys and their values.
    var entries: [[UInt8]: [UInt8]] = [:]

    /// Refuse to read files bigger than this; Termius's database is a few MB.
    static let maxFileSize = 256 << 20

    init(directory: URL) throws(StorageError) {
        let manifest = try Manifest(Self.read(directory.appendingPathComponent(Self.manifestName(in: directory))))
        var newest = NewestValues()
        for number in manifest.liveTables.sorted() {
            try Table.scan(Self.read(Self.tableURL(number, in: directory))) { newest.record($0, $1, $2) }
        }
        for number in try Self.logNumbers(in: directory) where number >= manifest.minimumLog {
            try WriteAheadLog.scan(Self.read(Self.file(number, "log", in: directory))) { newest.record($0, $1, $2) }
        }
        entries = newest.live
    }

    private static func manifestName(in directory: URL) throws(StorageError) -> String {
        let current = try read(directory.appendingPathComponent("CURRENT"))
        let name = String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.hasPrefix("MANIFEST-"), !name.contains("/") else { throw .corrupt("CURRENT names no MANIFEST") }
        return name
    }

    private static func file(_ number: UInt64, _ suffix: String, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "%06llu.", number) + suffix)
    }

    private static func tableURL(_ number: UInt64, in directory: URL) -> URL {
        let ldb = file(number, "ldb", in: directory)
        return FileManager.default.fileExists(atPath: ldb.path) ? ldb : file(number, "sst", in: directory)
    }

    private static func logNumbers(in directory: URL) throws(StorageError) -> [UInt64] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw .unreadable(path: directory.path, reason: error.localizedDescription)
        }
        return names.compactMap { name in
            guard name.hasSuffix(".log") else { return nil }
            return UInt64(name.dropLast(4))
        }.sorted()
    }

    static func read(_ url: URL) throws(StorageError) -> [UInt8] {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxFileSize else { throw StorageError.corrupt("\(url.lastPathComponent) is too large") }
            return Array(try Data(contentsOf: url, options: .mappedIfSafe))
        } catch let error as StorageError {
            throw error
        } catch {
            throw .unreadable(path: url.path, reason: error.localizedDescription)
        }
    }
}

typealias RecordSink = (_ key: [UInt8], _ sequence: UInt64, _ value: [UInt8]?) -> Void

/// Each key's value at its highest sequence number; `nil` for a deletion.
private struct NewestValues {
    private var values: [[UInt8]: (sequence: UInt64, value: [UInt8]?)] = [:]

    mutating func record(_ key: [UInt8], _ sequence: UInt64, _ value: [UInt8]?) {
        if let existing = values[key], existing.sequence > sequence { return }
        values[key] = (sequence, value)
    }

    var live: [[UInt8]: [UInt8]] { values.compactMapValues { $0.value } }
}

/// The record framing shared by `.log` files and the `MANIFEST`: 32 KiB blocks of
/// `checksum(4) length(2) type(1) data` fragments (full = 1, first = 2, middle = 3, last = 4).
enum LogRecords {
    static let blockSize = 32768

    /// Whole records in file order. A truncated or zero-filled tail ends the file.
    static func records(_ file: [UInt8]) -> [[UInt8]] {
        var assembler = Assembler()
        for start in stride(from: 0, to: file.count, by: blockSize) {
            guard assembler.read(file[start..<min(start + blockSize, file.count)]) else { break }
        }
        return assembler.records
    }

    private struct Assembler {
        private(set) var records: [[UInt8]] = []
        private var pending: [UInt8]?

        /// Reads one block's fragments, up to any preallocated zeros at its end. `false` once the
        /// file's tail is torn or holds an unknown fragment type.
        mutating func read(_ block: ArraySlice<UInt8>) -> Bool {
            var offset = block.startIndex
            while offset + 7 <= block.endIndex {
                let length = Int(block[offset + 4]) | Int(block[offset + 5]) << 8
                let type = block[offset + 6]
                if type == 0 && length == 0 { return true }
                guard offset + 7 + length <= block.endIndex else { return false }
                guard add(type, block[(offset + 7)..<(offset + 7 + length)]) else { return false }
                offset += 7 + length
            }
            return true
        }

        private mutating func add(_ type: UInt8, _ fragment: ArraySlice<UInt8>) -> Bool {
            switch type {
            case 1: records.append(Array(fragment)); pending = nil
            case 2: pending = Array(fragment)
            case 3: pending?.append(contentsOf: fragment)
            case 4: finish(fragment)
            default: return false
            }
            return true
        }

        private mutating func finish(_ fragment: ArraySlice<UInt8>) {
            if let pending { records.append(pending + fragment) }
            pending = nil
        }
    }
}

/// A `.log` file: write batches of `sequence(8) count(4)` then `type key [value]` records.
enum WriteAheadLog {
    static func scan(_ file: [UInt8], _ record: RecordSink) throws(StorageError) {
        for batch in LogRecords.records(file) {
            var cursor = ByteCursor(batch)
            let sequence = try cursor.littleEndian(8, "batch sequence")
            let count = try cursor.littleEndian(4, "batch count")
            for index in 0..<count {
                let type = try cursor.byte("batch record type")
                let key = try cursor.take(cursor.length("batch key length"), "batch key")
                switch type {
                case 1: record(key, sequence &+ index, try cursor.take(cursor.length("batch value length"), "batch value"))
                case 0: record(key, sequence &+ index, nil)
                default: throw .corrupt("unknown write batch record type \(type)")
                }
            }
        }
    }
}

/// The version edits in a `MANIFEST`: which table files are live and which logs are needed.
struct Manifest {
    private(set) var liveTables: Set<UInt64> = []
    private var logNumber: UInt64 = 0
    private var previousLog: UInt64 = 0

    /// Logs numbered below this are already in tables.
    var minimumLog: UInt64 { previousLog == 0 ? logNumber : min(logNumber, previousLog) }

    init(_ file: [UInt8]) throws(StorageError) {
        for edit in LogRecords.records(file) {
            var cursor = ByteCursor(edit)
            while !cursor.isAtEnd {
                let tag = try cursor.varint("manifest tag")
                apply(tag, try Self.fields(of: tag, &cursor))
            }
        }
    }

    private mutating func apply(_ tag: UInt64, _ numbers: [UInt64]) {
        switch tag {
        case 2: logNumber = numbers[0]
        case 6: liveTables.remove(numbers[1])
        case 7: liveTables.insert(numbers[1])
        case 9: previousLog = numbers[0]
        default: break
        }
    }

    private enum Field { case number, bytes }

    /// The fields after each version edit tag (leveldb `db/version_edit.cc`).
    private static let layouts: [UInt64: [Field]] = [
        1: [.bytes], 2: [.number], 3: [.number], 4: [.number], 5: [.number, .bytes],
        6: [.number, .number], 7: [.number, .number, .number, .bytes, .bytes], 9: [.number],
    ]

    /// A tag's varint fields in order; length-prefixed fields are skipped.
    private static func fields(of tag: UInt64, _ cursor: inout ByteCursor) throws(StorageError) -> [UInt64] {
        guard let layout = layouts[tag] else { throw .corrupt("unknown manifest tag \(tag)") }
        var numbers: [UInt64] = []
        for field in layout {
            switch field {
            case .number: numbers.append(try cursor.varint("manifest field"))
            case .bytes: try cursor.skip(cursor.length("manifest field"), "manifest field")
            }
        }
        return numbers
    }
}

/// A sorted table file: data blocks indexed by an index block, found through the 48-byte footer.
enum Table {
    static let magic: UInt64 = 0xDB47_7524_8B80_FB57

    static func scan(_ file: [UInt8], _ record: RecordSink) throws(StorageError) {
        for (_, handle) in try entries(indexBlock(file)) {
            var cursor = ByteCursor(handle)
            let data = try block(file, offset: cursor.varint("block offset"), size: cursor.varint("block size"))
            for (internalKey, value) in try entries(data) {
                try emit(internalKey, value, record)
            }
        }
    }

    /// The index block, found through the 48-byte footer.
    private static func indexBlock(_ file: [UInt8]) throws(StorageError) -> [UInt8] {
        guard file.count >= 48, file.littleEndian(at: file.count - 8, width: 8) == magic else {
            throw .corrupt("table footer")
        }
        var footer = ByteCursor(Array(file[(file.count - 48)...]))
        _ = try footer.varint("metaindex offset")
        _ = try footer.varint("metaindex size")
        let indexOffset = try footer.varint("index offset")
        return try block(file, offset: indexOffset, size: footer.varint("index size"))
    }

    /// An internal key is the user key, then 8 bytes of `sequence << 8 | type`.
    private static func emit(_ internalKey: [UInt8], _ value: [UInt8], _ record: RecordSink) throws(StorageError) {
        guard internalKey.count >= 8 else { throw .corrupt("internal key") }
        let trailer = internalKey.littleEndian(at: internalKey.count - 8, width: 8)
        let key = Array(internalKey[..<(internalKey.count - 8)])
        switch trailer & 0xFF {
        case 1: record(key, trailer >> 8, value)
        case 0: record(key, trailer >> 8, nil)
        default: throw .corrupt("internal key type")
        }
    }

    /// A block's contents, Snappy-decompressed when its trailer says so.
    static func block(_ file: [UInt8], offset: UInt64, size: UInt64) throws(StorageError) -> [UInt8] {
        guard offset <= UInt64(file.count), size <= UInt64(file.count), offset + size + 5 <= UInt64(file.count) else {
            throw .corrupt("block handle out of range")
        }
        let start = Int(offset), end = Int(offset + size)
        let raw = Array(file[start..<end])
        switch file[end] {
        case 0: return raw
        case 1: return try Snappy.decompress(raw)
        case let type: throw .corrupt("block compression type \(type)")
        }
    }

    /// Prefix-compressed `shared non_shared value_length key_delta value` entries, up to the
    /// restart array at the end of the block.
    static func entries(_ block: [UInt8]) throws(StorageError) -> [([UInt8], [UInt8])] {
        guard block.count >= 4 else { throw .corrupt("block too short") }
        let restarts = Int(block.littleEndian(at: block.count - 4, width: 4))
        let end = block.count - 4 - restarts * 4
        guard restarts >= 0, end >= 0 else { throw .corrupt("block restart array") }
        var cursor = ByteCursor(Array(block[..<end]))
        var key: [UInt8] = []
        var result: [([UInt8], [UInt8])] = []
        while !cursor.isAtEnd {
            let shared = try cursor.length("shared key length")
            let unshared = try cursor.length("key length")
            let valueLength = try cursor.length("value length")
            guard shared <= key.count else { throw .corrupt("shared key prefix") }
            key = Array(key[..<shared]) + (try cursor.take(unshared, "key"))
            result.append((key, try cursor.take(valueLength, "value")))
        }
        return result
    }
}
