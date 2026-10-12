import Foundation
import Testing
@testable import KeyAgent

/// Keys come from `ssh-keygen` at test time and are deleted right after reading; no key material
/// is committed.
@Suite("openssh-key-v1 import")
struct OpenSSHImportTests {
    @Test(arguments: [
        ("ed25519", nil, SSHKeyAlgorithm.ed25519),
        ("ecdsa", 256, .ecdsaP256),
        ("rsa", 2048, .rsa),
        ("rsa", 3072, .rsa),
    ] as [(String, Int?, SSHKeyAlgorithm)])
    func importsUnencryptedKeys(type: String, bits: Int?, algorithm: SSHKeyAlgorithm) async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let generated = try await GeneratedOpenSSHKey.make(type: type, bits: bits, comment: "alice@laptop", in: dir)

        let key = try OpenSSHPrivateKey.parse(generated.privateKeyText)
        #expect(key.algorithm == algorithm)
        #expect(key.comment == "alice@laptop")
        let publicKey = try SSHPublicKey(authorizedKeysLine: generated.publicKeyLine)
        #expect(Data(key.publicKeyBlob) == publicKey.blob)
        #expect(publicKey.fingerprint == generated.fingerprint)
        #expect(publicKey.authorizedKeysLine(comment: key.comment) == generated.publicKeyLine)

        // Sign with the imported key, and again with a key rebuilt from the stored secret.
        let data = Array("userauth data".utf8)
        let flags = algorithm == .rsa ? AgentMessage.flagRSASHA256 : 0
        for signer in [key.signingKey, try SigningKeyFactory.make(algorithm, secret: key.secret)] {
            let signature = try signer.signature(for: data, flags: flags)
            #expect(SignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: key.publicKeyBlob, data: data))
        }
    }

    @Test func rejectsEncryptedKeys() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let generated = try await GeneratedOpenSSHKey.make(type: "ed25519", passphrase: "correct horse battery", in: dir)
        #expect(throws: KeyImportError.encrypted(cipher: "aes256-ctr", kdf: "bcrypt")) {
            try OpenSSHPrivateKey.parse(generated.privateKeyText)
        }
        #expect(KeyImportError.encrypted(cipher: "aes256-ctr", kdf: "bcrypt").errorDescription?.contains("passphrase") == true)
    }

    @Test(arguments: [384, 521])
    func rejectsOtherECDSACurves(bits: Int) async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let generated = try await GeneratedOpenSSHKey.make(type: "ecdsa", bits: bits, in: dir)
        #expect(throws: KeyImportError.unsupportedKeyType("ecdsa-sha2-nistp\(bits)")) {
            try OpenSSHPrivateKey.parse(generated.privateKeyText)
        }
    }

    @Test func rejectsPEMWithAHint() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let generated = try await GeneratedOpenSSHKey.make(type: "rsa", bits: 2048, format: "PEM", in: dir)
        #expect(throws: KeyImportError.notOpenSSHFormat(detected: "PKCS#1 PEM (RSA)")) {
            try OpenSSHPrivateKey.parse(generated.privateKeyText)
        }
        #expect(KeyImportError.notOpenSSHFormat(detected: "PKCS#1 PEM (RSA)").errorDescription?.contains("ssh-keygen -p") == true)
        #expect(throws: KeyImportError.publicKey) { try OpenSSHPrivateKey.parse(generated.publicKeyLine) }
        #expect(throws: KeyImportError.publicKey) { try OpenSSHPrivateKey.parse("\n" + generated.publicKeyLine) }
        #expect(KeyImportError.publicKey.errorDescription?.contains("without .pub") == true)
        #expect(throws: KeyImportError.notOpenSSHFormat(detected: nil)) { try OpenSSHPrivateKey.parse("hello") }
    }

    @Test func rejectsDamagedKeys() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let generated = try await GeneratedOpenSSHKey.make(type: "ed25519", in: dir)
        let binary = try #require(Self.binary(of: generated.privateKeyText))

        // Mismatched check integers. Layout: magic(15) cipher(4+4) kdf(4+4) kdfopts(4) n(4) pub(4+51) priv-len(4).
        var badCheck = binary
        let checkOffset = 15 + 8 + 8 + 4 + 4 + 4 + 51 + 4
        badCheck[checkOffset] ^= 0xFF
        #expect(throws: KeyImportError.malformed("check integers differ")) { try OpenSSHPrivateKey.parse(binary: badCheck) }

        // Truncated.
        #expect(throws: KeyImportError.self) { try OpenSSHPrivateKey.parse(binary: Array(binary.prefix(binary.count - 40))) }

        // A flipped byte in the private key's public half.
        var badPublic = binary
        badPublic[checkOffset + 8 + 4 + 11 + 4 + 2] ^= 0x01
        #expect(throws: KeyImportError.self) { try OpenSSHPrivateKey.parse(binary: badPublic) }

        // Bad padding.
        var badPadding = binary
        badPadding[badPadding.count - 1] ^= 0x40
        #expect(throws: KeyImportError.malformed("bad padding")) { try OpenSSHPrivateKey.parse(binary: badPadding) }

        #expect(throws: KeyImportError.malformed("missing openssh-key-v1 magic")) { try OpenSSHPrivateKey.parse(binary: [1, 2, 3]) }
    }

    private static func binary(of text: String) -> [UInt8]? {
        let base64 = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: base64).map(Array.init)
    }
}
