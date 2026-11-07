import CryptoKit
import Foundation
import Testing
@testable import KeyAgent

/// PEM and PuTTY keys, as Termius and other clients store them. Keys come from `ssh-keygen` and
/// `puttygen` (or CryptoKit) at test time; no key material is committed.
@Suite("PEM and PuTTY key import")
struct PrivateKeyFormatsTests {
    static let puttygen = ["/opt/homebrew/bin/puttygen", "/usr/local/bin/puttygen", "/usr/bin/puttygen"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func expectUsable(_ key: OpenSSHPrivateKey, matches publicKeyLine: String) throws {
        let publicKey = try SSHPublicKey(authorizedKeysLine: publicKeyLine)
        #expect(Data(key.publicKeyBlob) == publicKey.blob)
        let data = Array("userauth data".utf8)
        let flags = key.algorithm == .rsa ? AgentMessage.flagRSASHA256 : 0
        for signer in [key.signingKey, try SigningKeyFactory.make(key.algorithm, secret: key.secret)] {
            let signature = try signer.signature(for: data, flags: flags)
            #expect(SignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: key.publicKeyBlob, data: data))
        }
    }

    @Test(arguments: [
        ("rsa", 2048, "PEM", "RSA PRIVATE KEY"),
        ("rsa", 3072, "PKCS8", "PRIVATE KEY"),
        ("ecdsa", 256, "PEM", "EC PRIVATE KEY"),
        ("ecdsa", 256, "PKCS8", "PRIVATE KEY"),
    ] as [(String, Int, String, String)])
    func importsPEM(type: String, bits: Int, format: String, label: String) async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let generated = try await GeneratedOpenSSHKey.make(type: type, bits: bits, format: format, in: dir)
        #expect(generated.privateKeyText.hasPrefix("-----BEGIN \(label)-----"))
        let key = try OpenSSHPrivateKey.parseAnyFormat(generated.privateKeyText)
        try expectUsable(key, matches: generated.publicKeyLine)
        #expect(KeyStore.importIssue(generated.privateKeyText) == nil)
    }

    @Test func importsPKCS8Ed25519() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let der: [UInt8] = [0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
            + Array(privateKey.rawRepresentation)
        let pem = "-----BEGIN PRIVATE KEY-----\n\(Data(der).base64EncodedString(options: .lineLength64Characters))\n-----END PRIVATE KEY-----\n"
        let key = try OpenSSHPrivateKey.parseAnyFormat(pem)
        #expect(key.algorithm == .ed25519)
        #expect(key.publicKeyBlob == PublicKeyBlob.ed25519(Array(privateKey.publicKey.rawRepresentation)))
    }

    @Test func refusesEncryptedPEM() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let generated = try await GeneratedOpenSSHKey.make(type: "rsa", bits: 2048, passphrase: "correct horse battery", format: "PEM", in: dir)
        guard case .encrypted(_, "PEM")? = KeyStore.importIssue(generated.privateKeyText) else {
            Issue.record("expected an encrypted-key error")
            return
        }
        let pkcs8 = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n"
        #expect(KeyStore.importIssue(pkcs8) == .encrypted(cipher: "PKCS#8", kdf: "PBES2"))
    }

    @Test func otherPEMAndGarbage() {
        let dsa = "-----BEGIN DSA PRIVATE KEY-----\nAAAA\n-----END DSA PRIVATE KEY-----\n"
        #expect(KeyStore.importIssue(dsa) == .unsupportedKeyType("ssh-dss"))
        let cert = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
        #expect(KeyStore.importIssue(cert) == .notOpenSSHFormat(detected: "PEM (CERTIFICATE)"))
        #expect(KeyStore.importIssue("hello") == .notOpenSSHFormat(detected: nil))
    }

    @Test(.enabled(if: PrivateKeyFormatsTests.puttygen != nil, "puttygen is not installed"), arguments: [
        ("ed25519", nil, 2), ("ed25519", nil, 3),
        ("rsa", 2048, 2), ("rsa", 2048, 3),
        ("ecdsa", 256, 2), ("ecdsa", 256, 3),
    ] as [(String, Int?, Int)])
    func importsPuTTYFiles(type: String, bits: Int?, version: Int) async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let generated = try await GeneratedOpenSSHKey.make(type: type, bits: bits, comment: "putty@test", in: dir)
        let source = dir.appending("source"), output = dir.appending("key.ppk")
        try Data(generated.privateKeyText.utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try await runProcess(try #require(Self.puttygen), [
            source.path, "-O", "private", "--ppk-param", "version=\(version)", "-o", output.path,
        ])
        try #require(result.status == 0, "puttygen failed: \(result.stderr)")
        let ppk = try String(contentsOf: output, encoding: .utf8)
        try FileManager.default.removeItem(at: output)

        #expect(ppk.hasPrefix("PuTTY-User-Key-File-\(version):"))
        let key = try OpenSSHPrivateKey.parseAnyFormat(ppk)
        #expect(key.comment == "putty@test")
        try expectUsable(key, matches: generated.publicKeyLine)
    }

    /// An Ed25519 `.ppk` built here, MAC included, so the format is covered without puttygen.
    static func ppk(version: Int, seed: [UInt8], publicKey: [UInt8], encryption: String = "none", comment: String = "built") -> String {
        func string(_ bytes: [UInt8]) -> [UInt8] { withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init) + bytes }
        let algorithm = "ssh-ed25519"
        let publicBlob = string(Array(algorithm.utf8)) + string(publicKey)
        let privateBlob = string(seed)
        let macInput = [Array(algorithm.utf8), Array(encryption.utf8), Array(comment.utf8), publicBlob, privateBlob].flatMap(string)
        let mac: [UInt8] = version == 2
            ? Array(HMAC<Insecure.SHA1>.authenticationCode(for: macInput, using: SymmetricKey(data: Insecure.SHA1.hash(data: Array("putty-private-key-file-mac-key".utf8)))))
            : Array(HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: Data())))
        var lines = ["PuTTY-User-Key-File-\(version): \(algorithm)", "Encryption: \(encryption)", "Comment: \(comment)"]
        lines += ["Public-Lines: 1", Data(publicBlob).base64EncodedString()]
        if version == 3, encryption != "none" {
            lines += ["Key-Derivation: Argon2id", "Argon2-Memory: 8192", "Argon2-Passes: 13", "Argon2-Parallelism: 1", "Argon2-Salt: 00"]
        }
        lines += ["Private-Lines: 1", Data(privateBlob).base64EncodedString()]
        lines += ["Private-MAC: \(mac.map { String(format: "%02x", $0) }.joined())"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    @Test(arguments: [2, 3])
    func importsABuiltPuTTYFileAndChecksItsMAC(version: Int) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let seed = Array(privateKey.rawRepresentation), publicKey = Array(privateKey.publicKey.rawRepresentation)
        let text = Self.ppk(version: version, seed: seed, publicKey: publicKey)
        let key = try OpenSSHPrivateKey.parseAnyFormat(text)
        #expect(key.algorithm == .ed25519)
        #expect(key.comment == "built")
        #expect(key.publicKeyBlob == PublicKeyBlob.ed25519(publicKey))

        let tampered = text.replacingOccurrences(of: "Comment: built", with: "Comment: built!")
        #expect(throws: KeyImportError.inconsistentKey("PuTTY key file MAC does not match")) {
            try OpenSSHPrivateKey.parseAnyFormat(tampered)
        }
        let other = Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        #expect(throws: KeyImportError.self) {
            try OpenSSHPrivateKey.parseAnyFormat(Self.ppk(version: version, seed: seed, publicKey: other))
        }
    }

    @Test func refusesEncryptedAndUnknownPuTTYFiles() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let encrypted = Self.ppk(version: 3, seed: Array(privateKey.rawRepresentation),
                                 publicKey: Array(privateKey.publicKey.rawRepresentation), encryption: "aes256-cbc")
        #expect(KeyStore.importIssue(encrypted) == .encrypted(cipher: "aes256-cbc", kdf: "Argon2"))
        #expect(KeyStore.importIssue("PuTTY-User-Key-File-4: ssh-ed25519\n") == .unsupportedKeyType("PuTTY key file version 4"))
        #expect(KeyStore.importIssue("PuTTY-User-Key-File-2: ssh-ed25519\nEncryption: none\n") != nil)
    }
}
