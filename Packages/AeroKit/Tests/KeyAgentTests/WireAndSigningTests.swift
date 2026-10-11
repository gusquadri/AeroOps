import CryptoKit
import Foundation
import Security
import Testing
@testable import KeyAgent

@Suite("SSH wire encoding")
struct WireTests {
    @Test func stringsAndIntegersRoundTrip() throws {
        var w = SSHWriter()
        w.byte(13)
        w.bool(true)
        w.uint32(0xDEAD_BEEF)
        w.string("ssh-ed25519")
        w.string([UInt8]())
        #expect(w.bytes == [13, 1, 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 0])

        var r = SSHReader(w.bytes)
        #expect(try r.byte() == 13)
        #expect(try r.bool())
        #expect(try r.uint32() == 0xDEAD_BEEF)
        #expect(try r.text() == "ssh-ed25519")
        #expect(try r.string().isEmpty)
        #expect(r.isAtEnd)
    }

    @Test(arguments: [
        ([UInt8](), [UInt8]()),
        ([0], []),
        ([0, 0, 0x7F], [0x7F]),
        ([0x80], [0x00, 0x80]),
        ([0x00, 0xFF, 0x01], [0x00, 0xFF, 0x01]),
        ([0x01, 0x02], [0x01, 0x02]),
    ])
    func mpintEncoding(magnitude: [UInt8], expected: [UInt8]) throws {
        var w = SSHWriter()
        w.mpint(unsigned: magnitude)
        var r = SSHReader(w.bytes)
        #expect(try r.string() == expected)
        var back = SSHReader(w.bytes)
        #expect(try back.unsignedMPInt() == Array(magnitude.drop(while: { $0 == 0 })))
    }

    @Test func negativeMPIntIsRejected() {
        var w = SSHWriter()
        w.string([0x80, 0x01])
        var r = SSHReader(w.bytes)
        #expect(throws: SSHWireError.malformed("mpint (negative)")) { try r.unsignedMPInt() }
    }

    @Test func truncatedInputThrows() {
        var r = SSHReader([0, 0, 0, 9, 1, 2])
        #expect(throws: SSHWireError.truncated("key blob")) { try r.string("key blob") }
        var short = SSHReader([0, 1])
        #expect(throws: SSHWireError.self) { try short.uint32() }
        var empty = SSHReader([UInt8]())
        #expect(throws: SSHWireError.self) { try empty.byte() }
    }

    @Test func frameIsLengthPrefixed() {
        #expect(SSHWriter.frame([11]) == [0, 0, 0, 1, 11])
    }

    @Test func fixedWidthPadsAndRejects() {
        #expect(fixedWidth([1, 2], 4) == [0, 0, 1, 2])
        #expect(fixedWidth([0, 0, 1], 1) == [1])
        #expect(fixedWidth([1, 2, 3], 2) == nil)
    }

    @Test func publicKeyParsingAndFingerprint() throws {
        let blob = Data(PublicKeyBlob.ed25519([UInt8](repeating: 0xAB, count: 32)))
        let key = try SSHPublicKey(blob: blob)
        #expect(key.keyType == "ssh-ed25519")
        let line = key.authorizedKeysLine(comment: "me@mac\nevil")
        #expect(line == "ssh-ed25519 \(blob.base64EncodedString()) me@mac evil")
        let parsed = try SSHPublicKey(authorizedKeysLine: line)
        #expect(parsed == key)
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(!key.fingerprint.contains("="))
        #expect(throws: SSHWireError.self) { try SSHPublicKey(authorizedKeysLine: "ssh-rsa \(blob.base64EncodedString())") }
    }
}

@Suite("Big integers and DER")
struct EncodingTests {
    @Test func bigUIntMatchesUInt64Arithmetic() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let a = UInt64.random(in: 0...UInt64.max, using: &generator)
            let m = UInt64.random(in: 1...UInt64.max >> UInt64.random(in: 0...62, using: &generator), using: &generator)
            #expect(BigUInt(a).remainder(dividingBy: BigUInt(m)) == BigUInt(a % m))
            #expect(BigUInt(bigEndian: BigUInt(a).bigEndianBytes) == BigUInt(a))
            if a > 0 { #expect(BigUInt(a).subtractingOne() == BigUInt(a - 1)) }
        }
        #expect(BigUInt(0).bitWidth == 0)
        #expect(BigUInt(1 << 40).bitWidth == 41)
    }

    @Test func rsaComponentsRebuildTheSameKey() throws {
        // Take a Security.framework key apart into OpenSSH's n, e, d, iqmp, p, q and rebuild it.
        let der = try makeRSAKeyDER()
        var outer = DERReader(Array(der))
        var seq = try outer.sequence()
        _ = try seq.unsignedInteger() // version
        let n = try seq.unsignedInteger(), e = try seq.unsignedInteger(), d = try seq.unsignedInteger()
        let p = try seq.unsignedInteger(), q = try seq.unsignedInteger()
        let dP = try seq.unsignedInteger(), dQ = try seq.unsignedInteger(), iqmp = try seq.unsignedInteger()
        let rebuilt = try RSAPrivateComponents(modulus: n, publicExponent: e, privateExponent: d, iqmp: iqmp, prime1: p, prime2: q).pkcs1DER()
        var check = DERReader(rebuilt)
        var fields = try check.sequence()
        let values = try (0..<9).map { _ in try fields.unsignedInteger() }
        #expect(values == [[], n, e, d, p, q, dP, dQ, iqmp])
        #expect(rebuilt == Array(der))
    }
}

@Suite("Signing keys")
struct SigningTests {
    private func verify(_ key: any SSHSigningKey, flags: UInt32 = 0, data: [UInt8] = Array("hello agent".utf8)) throws -> String? {
        let blob = try key.signature(for: data, flags: flags)
        #expect(SignatureVerifier.verify(signatureBlob: blob, publicKeyBlob: key.publicKeyBlob, data: data))
        #expect(!SignatureVerifier.verify(signatureBlob: blob, publicKeyBlob: key.publicKeyBlob, data: data + [0]))
        return signatureAlgorithm(blob)
    }

    @Test func ed25519() throws {
        let key = Ed25519SigningKey(privateKey: .init())
        #expect(try verify(key) == "ssh-ed25519")
        var r = SSHReader(key.publicKeyBlob)
        #expect(try r.text() == "ssh-ed25519")
        #expect(try r.string().count == 32)
    }

    @Test func ecdsaP256ManyTimes() throws {
        // About half of all r and s values need the mpint 0x00 pad; 200 rounds hit both cases.
        let key = P256SigningKey(privateKey: .init())
        for i in 0..<200 {
            #expect(try verify(key, data: Array("message \(i)".utf8)) == "ecdsa-sha2-nistp256")
        }
    }

    @Test func ecdsaSignatureEncodesRAndSAsMPInts() throws {
        var raw = [UInt8](repeating: 0, count: 64)
        raw[0] = 0x80 // r needs a pad byte
        raw[33] = 0x01 // s has a leading zero to strip
        let blob = ecdsaP256SignatureBlob(raw: Data(raw))
        var r = SSHReader(blob)
        #expect(try r.text() == "ecdsa-sha2-nistp256")
        var inner = SSHReader(try r.string())
        #expect(try inner.string().count == 33)
        #expect(try inner.string().count == 31)
    }

    @Test(.enabled(if: SecureEnclave.isAvailable)) func secureEnclaveP256() throws {
        let key = SecureEnclaveP256SigningKey(privateKey: try .init())
        for _ in 0..<20 { #expect(try verify(key) == "ecdsa-sha2-nistp256") }
        let reloaded = try SigningKeyFactory.make(.secureEnclaveP256, secret: key.privateKey.dataRepresentation)
        #expect(reloaded.publicKeyBlob == key.publicKeyBlob)
    }

    @Test func rsaFlags() throws {
        let key = try RSASigningKey(pkcs1DER: try makeRSAKeyDER())
        #expect(key.bitCount == 2048)
        #expect(try verify(key, flags: 2) == "rsa-sha2-256")
        #expect(try verify(key, flags: 4) == "rsa-sha2-512")
        #expect(try verify(key, flags: 6) == "rsa-sha2-512")
        #expect(throws: SigningError.sha1Refused(flags: 0)) { try key.signature(for: [1, 2, 3], flags: 0) }
        #expect(throws: SigningError.sha1Refused(flags: 1)) { try key.signature(for: [1, 2, 3], flags: 1) }
    }

    @Test func factoryRebuildsKeysFromSecrets() throws {
        let ed = Curve25519.Signing.PrivateKey()
        #expect(try SigningKeyFactory.make(.ed25519, secret: ed.rawRepresentation).publicKeyBlob == PublicKeyBlob.ed25519(ed.publicKey.rawRepresentation))
        let p256 = P256.Signing.PrivateKey()
        #expect(try SigningKeyFactory.make(.ecdsaP256, secret: p256.rawRepresentation).publicKeyBlob == PublicKeyBlob.ecdsaP256(x963: p256.publicKey.x963Representation))
        #expect(try SigningKeyFactory.make(.rsa, secret: try makeRSAKeyDER()).algorithm == .rsa)
        #expect(throws: SigningError.self) { try SigningKeyFactory.make(.ed25519, secret: Data([1, 2, 3])) }
        #expect(throws: SigningError.self) { try SigningKeyFactory.make(.rsa, secret: Data([0x30, 0x00])) }
    }
}
