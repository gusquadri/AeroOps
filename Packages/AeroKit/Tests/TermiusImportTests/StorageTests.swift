import Foundation
import Testing
@testable import TermiusImport

@Suite("Termius storage: Snappy, V8, LevelDB, IndexedDB")
struct StorageTests {
    @Test func snappyLiteralsAndCopies() throws {
        let compressed: [UInt8] = [14, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x01, 0x04, 0x16, 0x01, 0x00]
        #expect(try Snappy.decompress(compressed) == Array("abcdabcddddddd".utf8))
    }

    @Test func snappyLongLiteral() throws {
        let bytes = (0..<300).map { UInt8($0 % 251) }
        let compressed = V8.varint(300) + [61 << 2] + withUnsafeBytes(of: UInt16(299).littleEndian, Array.init) + bytes
        #expect(try Snappy.decompress(compressed) == bytes)
        #expect(try Snappy.decompress(Snappy.literalOnly(bytes)) == bytes)
    }

    @Test func snappyRejectsDamage() {
        #expect(throws: StorageError.self, "truncated literal") { try Snappy.decompress([5, 0x0C, 0x61]) }
        #expect(throws: StorageError.self, "copy before any output") { try Snappy.decompress([4, 0x01, 0x04]) }
        #expect(throws: StorageError.self, "short") { try Snappy.decompress([8, 0x0C, 0x61, 0x62, 0x63, 0x64]) }
        #expect(throws: StorageError.self) { try Snappy.decompress(V8.varint(UInt64(Snappy.maxOutput) + 1)) }
    }

    @Test func v8Values() throws {
        let value = V8.Value.object([
            ("id", .int(-7)),
            ("big", .double(1e12)),
            ("label", .string("web-1")),
            ("wide", .utf16("Café ☕")),
            ("none", .null),
            ("flag", .bool(true)),
            ("list", .array([.int(1), .string("two")])),
            ("ref", .object([("id", .int(3)), ("local_id", .int(4))])),
        ])
        let decoded = try V8Deserializer.value(from: V8.serialize(value))
        #expect(decoded["id"]?.number == -7)
        #expect(decoded["big"]?.number == 1e12)
        #expect(decoded["label"]?.string == "web-1")
        #expect(decoded["wide"]?.string == "Café ☕")
        #expect(decoded["none"] == .null)
        #expect(decoded["flag"]?.bool == true)
        #expect(decoded["list"] == .array([.number(1), .string("two")]))
        #expect(decoded["ref"]?["local_id"]?.number == 4)
    }

    @Test func v8RejectsUnknownTagsAndDeepNesting() {
        #expect(throws: StorageError.self) { try V8Deserializer.value(from: [0xFF, 0x0F, 0x01]) }
        let deep = [UInt8](repeating: UInt8(ascii: "s"), count: 100) + [UInt8(ascii: "0")]
        #expect(throws: StorageError.self) { try V8Deserializer.value(from: deep) }
    }

    @Test func blinkEnvelopes() throws {
        let v8 = V8.serialize(.object([("address", .string("10.0.0.1"))]))
        #expect(try IndexedDBSnapshot.decodeValue(V8.varint(1) + [0xFF, 0x14] + v8)["address"]?.string == "10.0.0.1")
        let trailer: [UInt8] = [0xFE] + [UInt8](repeating: 0, count: 12)
        #expect(try IndexedDBSnapshot.decodeValue(V8.varint(1) + [0xFF, 0x15] + trailer + v8)["address"]?.string == "10.0.0.1")
        let wrapped = V8.varint(1) + [0xFF, 0x11, 0x02] + Snappy.literalOnly([0xFF, 0x14] + v8)
        #expect(try IndexedDBSnapshot.decodeValue(wrapped)["address"]?.string == "10.0.0.1")
        #expect(throws: StorageError.self) { try IndexedDBSnapshot.decodeValue(V8.varint(1) + [0xFF, 0x11, 0x01, 0x00]) }
    }

    @Test(arguments: [false, true])
    func readsADatabaseFromTablesAndLogs(compressed: Bool) throws {
        let fixture = try LevelDBFixture()
        defer { fixture.remove() }
        let host = { (address: String) in IndexedDBFixture.row(.object([("address", .string(address))])) }
        let entries = IndexedDBFixture.database("hosts", id: 2, rows: [host("old.example"), host("b.example"), host("c.example")])
        let overwrite = (entries[2].0, Optional(host("a.example")))
        let deletion = (entries[4].0, [UInt8]?.none)
        let garbage = (entries[4].0.dropLast() + [0x09], Optional<[UInt8]>([0x01, 0xFF, 0x14, 0xFF, 0x0F, 0x07]))
        try fixture.write(
            tableEntries: entries.map { ($0.0, Optional($0.1)) }.sorted { $0.0.lexicographicallyPrecedes($1.0) },
            logEntries: [overwrite, deletion, (Array(garbage.0), garbage.1)],
            compressTable: compressed)

        let snapshot = try IndexedDBSnapshot(directory: fixture.directory)
        let store = try #require(snapshot.rows(ofDatabase: "hosts"))
        #expect(store.name == "hosts")
        #expect(Set(store.rows.compactMap { $0["address"]?.string }) == ["a.example", "b.example"])
        #expect(store.unreadableRows == 1)
        #expect(snapshot.rows(ofDatabase: "groups") == nil)
    }

    @Test func refusesADirectoryWithoutAManifest() throws {
        let fixture = try LevelDBFixture()
        defer { fixture.remove() }
        #expect(throws: StorageError.self) { try LevelDBSnapshot(directory: fixture.directory) }
        try Data("../evil\n".utf8).write(to: fixture.directory.appendingPathComponent("CURRENT"))
        #expect(throws: StorageError.corrupt("CURRENT names no MANIFEST")) { try LevelDBSnapshot(directory: fixture.directory) }
    }

    @Test func tornLogTailIsIgnored() {
        let records = LevelDBFixture.logFile([[1, 2, 3]]) + [0, 0, 0, 0, 50, 0, 1, 9]
        #expect(LogRecords.records(records) == [[1, 2, 3]])
    }
}

