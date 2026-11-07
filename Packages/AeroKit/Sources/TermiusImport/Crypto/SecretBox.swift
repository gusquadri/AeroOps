/// NaCl `crypto_secretbox_open` (XSalsa20-Poly1305), which Termius uses for its field
/// encryption. CryptoKit has neither Salsa20 nor a standalone Poly1305, so both are here,
/// after the reference designs (Salsa20 and Poly1305 by D. J. Bernstein; the 26-bit-limb
/// Poly1305 follows poly1305-donna).
enum SecretBox {
    static let keySize = 32
    static let nonceSize = 24
    static let macSize = 16

    /// Decrypts `box` (MAC then ciphertext) with `key` and `nonce`; `nil` if the MAC doesn't verify.
    static func open(_ box: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard key.count == keySize, nonce.count == nonceSize, box.count >= macSize else { return nil }
        let subkey = Salsa20.hsalsa20(key: key, input: Array(nonce[0..<16]))
        let ciphertext = Array(box[macSize...])
        var stream = Salsa20.keystream(key: subkey, nonce: Array(nonce[16..<24]), count: 32 + ciphertext.count)
        defer { wipe(&stream) }
        let mac = Poly1305.tag(ciphertext, key: Array(stream[0..<32]))
        guard constantTimeEqual(mac, Array(box[0..<macSize])) else { return nil }
        return zip(ciphertext, stream[32...]).map { $0 ^ $1 }
    }

    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
    }
}

enum Salsa20 {
    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]

    private static func words(_ bytes: [UInt8]) -> [UInt32] {
        stride(from: 0, to: bytes.count, by: 4).map { UInt32(truncatingIfNeeded: bytes.littleEndian(at: $0, width: 4)) }
    }

    private static func state(key: [UInt8], input: [UInt8]) -> [UInt32] {
        let k = words(key), n = words(input)
        return [sigma[0], k[0], k[1], k[2], k[3], sigma[1], n[0], n[1], n[2], n[3], sigma[2], k[4], k[5], k[6], k[7], sigma[3]]
    }

    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        value << count | value >> (32 - count)
    }

    private static func quarter(_ x: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        x[b] ^= rotl(x[a] &+ x[d], 7)
        x[c] ^= rotl(x[b] &+ x[a], 9)
        x[d] ^= rotl(x[c] &+ x[b], 13)
        x[a] ^= rotl(x[d] &+ x[c], 18)
    }

    private static func rounds(_ x: inout [UInt32]) {
        for _ in 0..<10 {
            quarter(&x, 0, 4, 8, 12); quarter(&x, 5, 9, 13, 1); quarter(&x, 10, 14, 2, 6); quarter(&x, 15, 3, 7, 11)
            quarter(&x, 0, 1, 2, 3); quarter(&x, 5, 6, 7, 4); quarter(&x, 10, 11, 8, 9); quarter(&x, 15, 12, 13, 14)
        }
    }

    private static func bytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) } }
    }

    /// HSalsa20: the XSalsa20 subkey from a 32-byte key and the nonce's first 16 bytes.
    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        var x = state(key: key, input: input)
        rounds(&x)
        return bytes([x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9]])
    }

    /// `count` bytes of Salsa20 keystream for an 8-byte nonce, block counter from 0.
    static func keystream(key: [UInt8], nonce: [UInt8], count: Int) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(count + 64)
        var counter: UInt64 = 0
        while output.count < count {
            let counterBytes = (0..<8).map { UInt8(truncatingIfNeeded: counter >> (8 * UInt64($0))) }
            let initial = state(key: key, input: nonce + counterBytes)
            var x = initial
            rounds(&x)
            output += bytes((0..<16).map { x[$0] &+ initial[$0] })
            counter += 1
        }
        return Array(output[0..<count])
    }
}

private func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(truncatingIfNeeded: bytes.littleEndian(at: offset, width: 4))
}

/// Poly1305 in five 26-bit limbs.
struct Poly1305 {
    private static let mask: UInt32 = 0x3FF_FFFF
    private let r: [UInt32]
    private let pad: [UInt32]
    private var h: [UInt32] = [0, 0, 0, 0, 0]

    /// The 16-byte tag of `message` under a one-time 32-byte key.
    static func tag(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        var poly = Poly1305(key: key)
        for start in stride(from: 0, to: message.count, by: 16) {
            poly.absorb(Array(message[start..<min(start + 16, message.count)]))
        }
        return poly.finish()
    }

    private init(key: [UInt8]) {
        r = [
            le32(key, 0) & 0x3FF_FFFF, (le32(key, 3) >> 2) & 0x3FF_FF03, (le32(key, 6) >> 4) & 0x3FF_C0FF,
            (le32(key, 9) >> 6) & 0x3F0_3FFF, (le32(key, 12) >> 8) & 0x00F_FFFF,
        ]
        pad = (0..<4).map { le32(key, 16 + 4 * $0) }
    }

    private mutating func absorb(_ chunk: [UInt8]) {
        let block = chunk + [1] + [UInt8](repeating: 0, count: 16 - chunk.count)
        let high: UInt32 = chunk.count == 16 ? 1 << 24 : 0
        h[0] &+= le32(block, 0) & Self.mask
        h[1] &+= (le32(block, 3) >> 2) & Self.mask
        h[2] &+= (le32(block, 6) >> 4) & Self.mask
        h[3] &+= (le32(block, 9) >> 6) & Self.mask
        h[4] &+= (le32(block, 12) >> 8) | high
        multiply()
    }

    /// `h *= r` modulo 2^130 - 5, with a partial carry.
    private mutating func multiply() {
        let product = (0..<5).map { i in
            (0..<5).reduce(UInt64(0)) { sum, j in sum + UInt64(h[j]) * UInt64(j <= i ? r[i - j] : r[5 + i - j] * 5) }
        }
        var carry: UInt64 = 0
        for i in 0..<5 {
            let value = product[i] + carry
            h[i] = UInt32(value & UInt64(Self.mask))
            carry = value >> 26
        }
        h[0] &+= UInt32(carry) &* 5
        h[1] &+= h[0] >> 26
        h[0] &= Self.mask
    }

    /// Fully carries `h`, reduces it below 2^130 - 5 in constant time, and adds the pad.
    private func finish() -> [UInt8] {
        var h = h, c: UInt32 = 0
        for i in 1..<5 { h[i] &+= c; c = h[i] >> 26; h[i] &= Self.mask }
        h[0] &+= c &* 5; c = h[0] >> 26; h[0] &= Self.mask
        h[1] &+= c

        var g = [UInt32](repeating: 0, count: 5)
        c = 5
        for i in 0..<4 { g[i] = h[i] &+ c; c = g[i] >> 26; g[i] &= Self.mask }
        g[4] = h[4] &+ c &- (1 << 26)
        let takeG = (g[4] >> 31) &- 1
        let n = (0..<5).map { (h[$0] & ~takeG) | (g[$0] & takeG) }

        let words = [n[0] | n[1] << 26, n[1] >> 6 | n[2] << 20, n[2] >> 12 | n[3] << 14, n[3] >> 18 | n[4] << 8]
        var f: UInt64 = 0
        var out: [UInt8] = []
        for i in 0..<4 {
            f = UInt64(words[i]) + UInt64(pad[i]) + (f >> 32)
            out += (0..<4).map { UInt8(truncatingIfNeeded: f >> (8 * UInt64($0))) }
        }
        return out
    }
}
