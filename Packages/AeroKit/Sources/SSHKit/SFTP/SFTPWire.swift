import Foundation

/// SFTP version 3 on the wire (draft-ietf-secsh-filexfer-02), as OpenSSH speaks it.
///
/// Every packet is `uint32 length`, `byte type`, then the payload; requests after `INIT`
/// carry a `uint32 id` that the reply echoes. Integers are big-endian; strings are a `uint32`
/// length followed by raw bytes.
enum SFTPWire {
    static let version: UInt32 = 3
    /// Longest packet accepted from the server. OpenSSH's own limit is 256 KiB; this leaves room
    /// for other servers while keeping one bad length from allocating gigabytes.
    static let maxPacketLength = 4 * 1024 * 1024

    enum PacketType: UInt8 {
        case initialize = 1
        case version = 2
        case open = 3
        case close = 4
        case read = 5
        case write = 6
        case lstat = 7
        case fstat = 8
        case setstat = 9
        case fsetstat = 10
        case opendir = 11
        case readdir = 12
        case remove = 13
        case mkdir = 14
        case rmdir = 15
        case realpath = 16
        case stat = 17
        case rename = 18
        case readlink = 19
        case symlink = 20
        case status = 101
        case handle = 102
        case data = 103
        case name = 104
        case attrs = 105
        case extended = 200
        case extendedReply = 201
    }

    /// `SSH_FXF_*` open flags.
    struct OpenFlags: OptionSet, Sendable {
        let rawValue: UInt32
        static let read = OpenFlags(rawValue: 0x01)
        static let write = OpenFlags(rawValue: 0x02)
        static let append = OpenFlags(rawValue: 0x04)
        static let create = OpenFlags(rawValue: 0x08)
        static let truncate = OpenFlags(rawValue: 0x10)
        static let exclusive = OpenFlags(rawValue: 0x20)
    }

    /// `SSH_FILEXFER_ATTR_*` flags.
    enum AttributeFlag {
        static let size: UInt32 = 0x01
        static let uidgid: UInt32 = 0x02
        static let permissions: UInt32 = 0x04
        static let acmodtime: UInt32 = 0x08
        static let extended: UInt32 = 0x8000_0000
    }

    /// A reply from the server, matched to its request by id.
    enum Response: Sendable {
        case status(SFTPStatusCode, message: String)
        case handle(Data)
        case data(Data)
        case name([NameEntry])
        case attrs(SFTPAttributes)
        case extendedReply(Data)
    }

    struct NameEntry: Sendable, Hashable {
        var filename: Data
        var longname: Data
        var attributes: SFTPAttributes
    }

    /// A parsed server packet.
    enum Packet: Sendable {
        /// `SSH_FXP_VERSION` with its extension pairs (name, data).
        case version(UInt32, extensions: [(String, Data)])
        case response(id: UInt32, Response)
    }

    /// Parses one packet body (type byte onwards, without the length).
    static func parse(_ body: Data) throws(SFTPError) -> Packet {
        var reader = Reader(body)
        let typeByte = try reader.u8()
        guard let type = PacketType(rawValue: typeByte) else {
            throw .protocolError("unknown packet type \(typeByte)")
        }
        if type == .version {
            let version = try reader.u32()
            var extensions: [(String, Data)] = []
            while !reader.isAtEnd {
                let name = try reader.string()
                let data = try reader.string()
                extensions.append((String(decoding: name, as: UTF8.self), data))
            }
            return .version(version, extensions: extensions)
        }
        let id = try reader.u32()
        let response: Response
        switch type {
        case .status:
            let code = SFTPStatusCode(rawValue: try reader.u32())
            let message = reader.isAtEnd ? Data() : try reader.string()
            response = .status(code, message: String(decoding: message, as: UTF8.self))
        case .handle:
            response = .handle(try reader.string())
        case .data:
            response = .data(try reader.string())
        case .name:
            let count = try reader.u32()
            guard Int(count) <= reader.remaining / 12 else { throw .protocolError("NAME count \(count) exceeds the packet") }
            var entries: [NameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                let filename = try reader.string()
                let longname = try reader.string()
                let attributes = try reader.attributes()
                entries.append(NameEntry(filename: filename, longname: longname, attributes: attributes))
            }
            response = .name(entries)
        case .attrs:
            response = .attrs(try reader.attributes())
        case .extendedReply:
            response = .extendedReply(reader.rest())
        default:
            throw .protocolError("unexpected packet type \(typeByte) from the server")
        }
        return .response(id: id, response)
    }

    /// Builds one framed packet.
    struct Writer {
        private(set) var body = Data()

        init(_ type: PacketType) {
            body.append(type.rawValue)
        }

        mutating func u8(_ value: UInt8) {
            body.append(value)
        }

        mutating func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.bigEndian) { body.append(contentsOf: $0) }
        }

        mutating func u64(_ value: UInt64) {
            withUnsafeBytes(of: value.bigEndian) { body.append(contentsOf: $0) }
        }

        mutating func string(_ value: Data) {
            u32(UInt32(value.count))
            body.append(value)
        }

        mutating func string(_ value: String) {
            string(Data(value.utf8))
        }

        mutating func attributes(_ value: SFTPAttributes) {
            var flags: UInt32 = 0
            if value.size != nil { flags |= AttributeFlag.size }
            if value.uid != nil, value.gid != nil { flags |= AttributeFlag.uidgid }
            if value.permissions != nil { flags |= AttributeFlag.permissions }
            if value.accessTime != nil, value.modificationTime != nil { flags |= AttributeFlag.acmodtime }
            u32(flags)
            if let size = value.size { u64(size) }
            if let uid = value.uid, let gid = value.gid {
                u32(uid)
                u32(gid)
            }
            if let permissions = value.permissions { u32(permissions) }
            if let accessTime = value.accessTime, let modificationTime = value.modificationTime {
                u32(accessTime)
                u32(modificationTime)
            }
        }

        /// The packet with its length prefix.
        var framed: Data {
            var packet = Data(capacity: body.count + 4)
            withUnsafeBytes(of: UInt32(body.count).bigEndian) { packet.append(contentsOf: $0) }
            packet.append(body)
            return packet
        }
    }

    /// Reads fields from a packet body.
    struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool { offset >= data.endIndex }
        var remaining: Int { data.endIndex - offset }

        mutating func u8() throws(SFTPError) -> UInt8 {
            guard remaining >= 1 else { throw .protocolError("truncated packet") }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func u32() throws(SFTPError) -> UInt32 {
            guard remaining >= 4 else { throw .protocolError("truncated packet") }
            var value: UInt32 = 0
            for index in offset..<(offset + 4) { value = value << 8 | UInt32(data[index]) }
            offset += 4
            return value
        }

        mutating func u64() throws(SFTPError) -> UInt64 {
            let high = try u32()
            let low = try u32()
            return UInt64(high) << 32 | UInt64(low)
        }

        mutating func string() throws(SFTPError) -> Data {
            let length = Int(try u32())
            guard remaining >= length else { throw .protocolError("string longer than the packet") }
            defer { offset += length }
            return Data(data[offset..<(offset + length)])
        }

        mutating func attributes() throws(SFTPError) -> SFTPAttributes {
            let flags = try u32()
            var attributes = SFTPAttributes()
            if flags & AttributeFlag.size != 0 { attributes.size = try u64() }
            if flags & AttributeFlag.uidgid != 0 {
                attributes.uid = try u32()
                attributes.gid = try u32()
            }
            if flags & AttributeFlag.permissions != 0 { attributes.permissions = try u32() }
            if flags & AttributeFlag.acmodtime != 0 {
                attributes.accessTime = try u32()
                attributes.modificationTime = try u32()
            }
            if flags & AttributeFlag.extended != 0 {
                let count = try u32()
                guard Int(count) <= remaining / 8 else { throw .protocolError("extended attribute count exceeds the packet") }
                for _ in 0..<count {
                    _ = try string()
                    _ = try string()
                }
            }
            return attributes
        }

        mutating func rest() -> Data {
            defer { offset = data.endIndex }
            return Data(data[offset..<data.endIndex])
        }
    }

    /// Splits a byte stream into packet bodies.
    struct Framer {
        private var buffer = Data()

        /// Appends `chunk` and returns every complete packet body in it.
        mutating func append(_ chunk: Data) throws(SFTPError) -> [Data] {
            buffer.append(chunk)
            var packets: [Data] = []
            var start = buffer.startIndex
            while buffer.endIndex - start >= 4 {
                var length = 0
                for index in start..<(start + 4) { length = length << 8 | Int(buffer[index]) }
                guard length >= 1, length <= SFTPWire.maxPacketLength else {
                    throw .protocolError("invalid packet length \(length)")
                }
                guard buffer.endIndex - start - 4 >= length else { break }
                packets.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
                start += 4 + length
            }
            if start != buffer.startIndex {
                buffer = Data(buffer[start..<buffer.endIndex])
            }
            return packets
        }
    }
}
