import Foundation

/// Just enough DER to read and write PKCS#1 RSA keys (`SEQUENCE` of `INTEGER`s).
struct DERReader {
    private var reader: DERCursor

    init(_ bytes: [UInt8]) { reader = DERCursor(bytes) }

    var isAtEnd: Bool { reader.isAtEnd }

    private mutating func element(tag: UInt8, _ what: String) throws(SSHWireError) -> [UInt8] {
        guard try reader.next(what) == tag else { throw .malformed("DER \(what): unexpected tag") }
        var length = Int(try reader.next(what))
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard (1...4).contains(count) else { throw .malformed("DER \(what): length") }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(try reader.next(what)) }
        }
        return try reader.take(length, what)
    }

    /// The contents of a `SEQUENCE`.
    mutating func sequence(_ what: String = "sequence") throws(SSHWireError) -> DERReader {
        DERReader(try element(tag: 0x30, what))
    }

    /// A non-negative `INTEGER` as an unsigned big-endian magnitude without leading zeros.
    mutating func unsignedInteger(_ what: String = "integer") throws(SSHWireError) -> [UInt8] {
        let raw = try element(tag: 0x02, what)
        if let first = raw.first, first & 0x80 != 0 { throw .malformed("DER \(what): negative") }
        return Array(raw.drop(while: { $0 == 0 }))
    }
}

/// A bounds-checked byte cursor for ``DERReader``.
struct DERCursor {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func next(_ what: String) throws(SSHWireError) -> UInt8 {
        guard index < bytes.count else { throw .truncated("DER \(what)") }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func take(_ count: Int, _ what: String) throws(SSHWireError) -> [UInt8] {
        guard count >= 0, bytes.count - index >= count else { throw .truncated("DER \(what)") }
        defer { index += count }
        return Array(bytes[index..<index + count])
    }
}

enum DERWriter {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var n = count
        while n > 0 { bytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// A non-negative `INTEGER` from an unsigned big-endian magnitude.
    static func integer(unsigned magnitude: [UInt8]) -> [UInt8] {
        var m = Array(magnitude.drop(while: { $0 == 0 }))
        if m.isEmpty { m = [0] } else if m[0] & 0x80 != 0 { m.insert(0, at: 0) }
        return [0x02] + length(m.count) + m
    }

    static func sequence(_ elements: [[UInt8]]) -> [UInt8] {
        let body = elements.flatMap { $0 }
        return [0x30] + length(body.count) + body
    }
}

/// The components of an RSA private key as stored by OpenSSH (`n, e, d, iqmp, p, q`).
struct RSAPrivateComponents: Sendable {
    var modulus: [UInt8]
    var publicExponent: [UInt8]
    var privateExponent: [UInt8]
    /// q⁻¹ mod p (PKCS#1 `coefficient`).
    var iqmp: [UInt8]
    var prime1: [UInt8]
    var prime2: [UInt8]

    /// PKCS#1 `RSAPrivateKey` DER, as `SecKeyCreateWithData` expects.
    ///
    /// OpenSSH files carry no CRT exponents, so `dP = d mod (p-1)` and `dQ = d mod (q-1)` are
    /// computed here. The result is verified by a sign/verify round trip at import.
    func pkcs1DER() throws(SSHWireError) -> [UInt8] {
        let d = BigUInt(bigEndian: privateExponent)
        let p = BigUInt(bigEndian: prime1)
        let q = BigUInt(bigEndian: prime2)
        guard !p.isZero, !q.isZero, !d.isZero else { throw .malformed("RSA private key (zero component)") }
        let dP = d.remainder(dividingBy: p.subtractingOne())
        let dQ = d.remainder(dividingBy: q.subtractingOne())
        return DERWriter.sequence([
            DERWriter.integer(unsigned: []), // version 0 (two-prime)
            DERWriter.integer(unsigned: modulus),
            DERWriter.integer(unsigned: publicExponent),
            DERWriter.integer(unsigned: privateExponent),
            DERWriter.integer(unsigned: prime1),
            DERWriter.integer(unsigned: prime2),
            DERWriter.integer(unsigned: dP.bigEndianBytes),
            DERWriter.integer(unsigned: dQ.bigEndianBytes),
            DERWriter.integer(unsigned: iqmp),
        ])
    }
}

/// Minimal unsigned big integer: just what the CRT exponents need (`a mod m`, `a - 1`).
/// Little-endian 32-bit limbs; bit-serial division is plenty fast for 4096-bit keys.
struct BigUInt: Equatable, Sendable {
    private(set) var limbs: [UInt32]

    init(bigEndian bytes: [UInt8]) {
        var limbs: [UInt32] = []
        var index = bytes.count
        while index > 0 {
            let start = max(0, index - 4)
            limbs.append(bytes[start..<index].reduce(0) { $0 << 8 | UInt32($1) })
            index = start
        }
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    var bigEndianBytes: [UInt8] {
        var bytes: [UInt8] = []
        for limb in limbs.reversed() {
            bytes.append(contentsOf: [UInt8(limb >> 24), UInt8(limb >> 16 & 0xff), UInt8(limb >> 8 & 0xff), UInt8(limb & 0xff)])
        }
        return Array(bytes.drop(while: { $0 == 0 }))
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    private func bit(_ i: Int) -> Bool { limbs[i / 32] >> UInt32(i % 32) & 1 == 1 }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    /// `self - other`; requires `self >= other`.
    private mutating func subtract(_ other: BigUInt) {
        var borrow: UInt64 = 0
        for i in limbs.indices {
            let rhs = UInt64(i < other.limbs.count ? other.limbs[i] : 0) + borrow
            let lhs = UInt64(limbs[i])
            if lhs >= rhs {
                limbs[i] = UInt32(lhs - rhs)
                borrow = 0
            } else {
                limbs[i] = UInt32(lhs + (1 << 32) - rhs)
                borrow = 1
            }
        }
        normalize()
    }

    /// `self << 1 | bit`.
    private mutating func shiftLeftOne(insert bit: Bool) {
        var carry: UInt32 = bit ? 1 : 0
        for i in limbs.indices {
            let next = limbs[i] >> 31
            limbs[i] = limbs[i] << 1 | carry
            carry = next
        }
        if carry != 0 { limbs.append(carry) }
    }

    func subtractingOne() -> BigUInt {
        guard !isZero else { return self }
        var result = self
        result.subtract(BigUInt(1))
        return result
    }

    /// `self mod divisor`; `divisor` must be non-zero.
    func remainder(dividingBy divisor: BigUInt) -> BigUInt {
        precondition(!divisor.isZero, "division by zero")
        var r = BigUInt(limbs: [])
        for i in stride(from: bitWidth - 1, through: 0, by: -1) {
            r.shiftLeftOne(insert: bit(i))
            if !(r < divisor) { r.subtract(divisor) }
        }
        return r
    }
}
