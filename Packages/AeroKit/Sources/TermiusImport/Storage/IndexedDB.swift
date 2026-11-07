import Foundation

/// The rows of Chromium IndexedDB databases kept in one LevelDB directory
/// (`<origin>.indexeddb.leveldb`).
///
/// Keys start with a prefix of database id, object store id and index id
/// (content/browser/indexed_db/indexed_db_leveldb_coding.cc):
/// - `(0, 0, 0)` + `201` + origin + name → the database id (database names);
/// - `(db, 0, 0)` + `50` + store id + `0` → the object store's name;
/// - `(db, store, 1)` + primary key → a row: a version varint, then the serialized value.
struct IndexedDBSnapshot {
    struct Store {
        var name: String
        var rows: [JSValue] = []
        /// Rows whose value could not be decoded (an unsupported wrapper or type).
        var unreadableRows = 0
    }

    /// Database name → its object stores, by store id.
    private(set) var databases: [String: [UInt64: Store]] = [:]

    init(directory: URL) throws(StorageError) {
        try self.init(entries: LevelDBSnapshot(directory: directory).entries)
    }

    init(entries: [[UInt8]: [UInt8]]) throws(StorageError) {
        var raw = RawEntries()
        for (key, value) in entries { try raw.add(key: key, value: value) }
        for (databaseID, name) in raw.databaseNames {
            databases[name] = raw.stores(of: databaseID)
        }
    }

    /// Entries sorted by what their key prefix says they are, before any value is decoded.
    private struct RawEntries {
        var databaseNames: [UInt64: String] = [:]
        var storeNames: [UInt64: [UInt64: String]] = [:]
        var rows: [UInt64: [UInt64: [[UInt8]]]] = [:]

        mutating func add(key: [UInt8], value: [UInt8]) throws(StorageError) {
            guard let prefix = KeyPrefix(key) else { return }
            var rest = ByteCursor(key, offset: prefix.length)
            switch (prefix.database, prefix.objectStore, prefix.index) {
            case (0, 0, 0): try addDatabaseName(&rest, value: value)
            case (let database, 0, 0): try addStoreName(&rest, database: database, value: value)
            case (let database, let store, 1) where store != 0:
                rows[database, default: [:]][store, default: []].append(value)
            default: return
            }
        }

        /// `201`, the origin and the database name; the value is the database id.
        private mutating func addDatabaseName(_ rest: inout ByteCursor, value: [UInt8]) throws(StorageError) {
            guard rest.peek() == 201 else { return }
            _ = try rest.byte("database name tag")
            _ = try IndexedDBSnapshot.stringWithLength(&rest)
            let name = try IndexedDBSnapshot.stringWithLength(&rest)
            var id = ByteCursor(value)
            databaseNames[try id.varint("database id")] = name
        }

        /// `50`, the store id and `0`; the value is the store's name.
        private mutating func addStoreName(_ rest: inout ByteCursor, database: UInt64, value: [UInt8]) throws(StorageError) {
            guard rest.peek() == 50 else { return }
            _ = try rest.byte("object store meta tag")
            let store = try rest.varint("object store id")
            guard try rest.byte("object store meta type") == 0 else { return }
            storeNames[database, default: [:]][store] = IndexedDBSnapshot.utf16BigEndian(value)
        }

        func stores(of databaseID: UInt64) -> [UInt64: Store] {
            (storeNames[databaseID] ?? [:]).reduce(into: [:]) { stores, entry in
                stores[entry.key] = Store(name: entry.value, values: rows[databaseID]?[entry.key] ?? [])
            }
        }
    }

    /// The rows of the database `name`: the store with the same name, else its first store.
    func rows(ofDatabase name: String) -> Store? {
        guard let stores = databases[name] else { return nil }
        return stores.values.first { $0.name == name } ?? stores.min { $0.key < $1.key }?.value
    }

    /// A row value: `version` varint, then Blink's serialized script value. Blink may wrap it
    /// (`0xFF 0x11` then `0x02` = Snappy-compressed; `0x01` = moved to a blob file, unsupported).
    /// Inside: `0xFF <blink version>`, from version 21 a `0xFE` trailer offset (12 bytes), then
    /// V8's `0xFF <version>` and the value.
    static func decodeValue(_ value: [UInt8]) throws(StorageError) -> JSValue {
        var cursor = ByteCursor(value)
        _ = try cursor.varint("record version")
        var payload = Array(value[cursor.offset...])
        if payload.count >= 3, payload[0] == 0xFF, payload[1] == 0x11 {
            switch payload[2] {
            case 0x02: payload = try Snappy.decompress(Array(payload[3...]))
            default: throw .corrupt("value stored outside the database")
            }
        }
        var envelope = ByteCursor(payload)
        if envelope.peek() == 0xFF {
            _ = try envelope.byte("blink version tag")
            let version = try envelope.varint("blink version")
            if version >= 21, envelope.peek() == 0xFE {
                try envelope.skip(13, "blink trailer offset")
            }
        }
        return try V8Deserializer.value(from: payload, offset: envelope.offset)
    }

    /// The `(database, store, index)` prefix: one byte of lengths, then little-endian ids.
    struct KeyPrefix {
        var database: UInt64
        var objectStore: UInt64
        var index: UInt64
        var length: Int

        init?(_ key: [UInt8]) {
            guard let first = key.first else { return nil }
            let databaseWidth = Int(first >> 5) + 1
            let storeWidth = Int((first >> 2) & 7) + 1
            let indexWidth = Int(first & 3) + 1
            length = 1 + databaseWidth + storeWidth + indexWidth
            guard key.count >= length, databaseWidth <= 8, storeWidth <= 8 else { return nil }
            database = key.littleEndian(at: 1, width: databaseWidth)
            objectStore = key.littleEndian(at: 1 + databaseWidth, width: storeWidth)
            index = key.littleEndian(at: 1 + databaseWidth + storeWidth, width: indexWidth)
        }
    }

    /// A varint count of UTF-16 code units, then the units big-endian.
    static func stringWithLength(_ cursor: inout ByteCursor) throws(StorageError) -> String {
        let count = try cursor.length("string length")
        return utf16BigEndian(try cursor.take(count * 2, "string"))
    }

    static func utf16BigEndian(_ bytes: [UInt8]) -> String {
        let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        return String(decoding: units, as: UTF16.self)
    }
}

extension IndexedDBSnapshot.Store {
    init(name: String, values: [[UInt8]]) {
        self.init(name: name)
        for value in values {
            if let row = try? IndexedDBSnapshot.decodeValue(value) { rows.append(row) } else { unreadableRows += 1 }
        }
    }
}
