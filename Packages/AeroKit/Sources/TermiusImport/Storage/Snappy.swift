/// Raw (unframed) Snappy decompression, as LevelDB uses for table blocks and Chromium for
/// compressed IndexedDB values.
///
/// Format: a varint uncompressed length, then literal and copy elements
/// (https://github.com/google/snappy/blob/main/format_description.txt).
enum Snappy {
    /// Refuses anything claiming to expand past this; Termius's tables are a few MB.
    static let maxOutput = 64 << 20

    static func decompress(_ input: [UInt8]) throws(StorageError) -> [UInt8] {
        var cursor = ByteCursor(input)
        let length = try cursor.varint("snappy length")
        guard length <= UInt64(maxOutput) else { throw .corrupt("snappy block too large") }
        var output: [UInt8] = []
        output.reserveCapacity(Int(length))
        while !cursor.isAtEnd {
            try element(&cursor, into: &output)
            guard output.count <= Int(length) else { throw .corrupt("snappy output overruns its length") }
        }
        guard output.count == Int(length) else { throw .corrupt("snappy output is shorter than its length") }
        return output
    }

    private static func element(_ cursor: inout ByteCursor, into output: inout [UInt8]) throws(StorageError) {
        let tag = try cursor.byte("snappy tag")
        let offsetWidth = [0, 1, 2, 4][Int(tag & 3)]
        guard offsetWidth > 0 else {
            output += try literal(tag, &cursor)
            return
        }
        let count = offsetWidth == 1 ? Int((tag >> 2) & 7) + 4 : Int(tag >> 2) + 1
        let low = Int(try cursor.littleEndian(offsetWidth, "snappy offset"))
        let offset = offsetWidth == 1 ? Int(tag >> 5) << 8 | low : low
        try copy(&output, offset: offset, count: count)
    }

    private static func literal(_ tag: UInt8, _ cursor: inout ByteCursor) throws(StorageError) -> [UInt8] {
        var count = Int(tag >> 2)
        if count >= 60 {
            count = Int(try cursor.littleEndian(count - 59, "snappy literal length"))
        }
        return try cursor.take(count + 1, "snappy literal")
    }

    /// Copies `count` bytes from `offset` back; the ranges may overlap (run-length style).
    private static func copy(_ output: inout [UInt8], offset: Int, count: Int) throws(StorageError) {
        guard offset > 0, offset <= output.count else { throw .corrupt("snappy copy offset out of range") }
        let start = output.count - offset
        for index in 0..<count {
            output.append(output[start + index])
        }
    }
}
