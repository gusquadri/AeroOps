import Foundation
import Testing
@testable import TermiusImport

@Suite("Termius field encryption")
struct CryptoTests {
    /// RFC 8439 §2.5.2.
    @Test func poly1305Vector() {
        let key = [UInt8](hex: "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
        let tag = Poly1305.tag(Array("Cryptographic Forum Research Group".utf8), key: key)
        #expect(tag == [UInt8](hex: "a8061dc1305136c6c22b8baf0c0127a9"))
    }

    /// NaCl's `core1` test: the HSalsa20 of a shared secret and zeros.
    @Test func hsalsa20Vector() {
        let shared = [UInt8](hex: "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
        let output = Salsa20.hsalsa20(key: shared, input: [UInt8](repeating: 0, count: 16))
        #expect(output == [UInt8](hex: "1b27556473e985d462cd51197a9a46c76009549eac6474f206c4ee0844f68389"))
    }

    private static let key = (0..<32).map { UInt8($0 * 7 & 0xFF) }
    private static let nonce = (0..<24).map { UInt8(200 &- $0) }

    @Test(arguments: ["", "s3cr3t", "pässwörd ☕", String(repeating: "long field ", count: 40)])
    func sealsAndOpens(text: String) throws {
        let cipher = try TermiusFieldCipher(key: Self.key)
        let sealed = cipher.seal(text, nonce: Self.nonce)
        #expect(TermiusFieldCipher.envelope(sealed) != nil)
        #expect(try cipher.decrypt(sealed) == text)
    }

    @Test func plainStringsPassThrough() throws {
        let cipher = try TermiusFieldCipher(key: Self.key)
        for text in ["", "web-1", "10.0.0.1", "dGhpcyBpcyBub3QgYW4gZW52ZWxvcGUgYXQgYWxsLCBqdXN0IHRleHQ="] {
            #expect(try cipher.decrypt(text) == text)
        }
    }

    @Test func wrongKeyOrTamperingFails() throws {
        let sealed = try TermiusFieldCipher(key: Self.key).seal("secret", nonce: Self.nonce)
        let other = try TermiusFieldCipher(key: [UInt8](repeating: 9, count: 32))
        #expect(throws: TermiusImportError.wrongLocalKey) { try other.decrypt(sealed) }

        var bytes = Array(Data(base64Encoded: sealed)!)
        bytes[bytes.count - 1] ^= 1
        let tampered = Data(bytes).base64EncodedString()
        #expect(throws: TermiusImportError.wrongLocalKey) { try TermiusFieldCipher(key: Self.key).decrypt(tampered) }
    }

    @Test func localKeyMustBe32BytesOfBase64() throws {
        #expect(throws: TermiusImportError.badLocalKey) { try TermiusFieldCipher(localKey: "not base64!") }
        #expect(throws: TermiusImportError.badLocalKey) { try TermiusFieldCipher(localKey: Data(count: 16).base64EncodedString()) }
        _ = try TermiusFieldCipher(localKey: Data(Self.key).base64EncodedString() + "\n")
    }

    @Test func secretsAreRedacted() {
        let secret = TermiusSecret("hunter2")
        #expect(secret.reveal() == "hunter2")
        #expect(!"\(secret)".contains("hunter2"))
        #expect(!String(reflecting: secret).contains("hunter2"))
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("hunter2"))
    }
}
