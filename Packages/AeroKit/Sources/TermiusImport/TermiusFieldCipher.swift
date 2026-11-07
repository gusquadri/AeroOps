import Foundation

/// Decrypts Termius's encrypted fields.
///
/// Each encrypted string is base64 of `0x04 0x01 | nonce(24) | secretbox(MAC + ciphertext)`,
/// sealed with the 32-byte key Termius keeps in the Keychain as `localKey` (base64). Strings that
/// aren't in that form are stored in the clear and returned as they are.
struct TermiusFieldCipher: Sendable {
    static let header: [UInt8] = [0x04, 0x01]
    static let overhead = header.count + SecretBox.nonceSize + SecretBox.macSize

    private let key: [UInt8]

    init(key: [UInt8]) throws(TermiusImportError) {
        guard key.count == SecretBox.keySize else { throw .badLocalKey }
        self.key = key
    }

    /// The Keychain item's text: base64 of 32 bytes.
    init(localKey: String) throws(TermiusImportError) {
        guard let data = Data(base64Encoded: localKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .badLocalKey
        }
        try self.init(key: Array(data))
    }

    /// Whether `text` looks like an encrypted field.
    static func envelope(_ text: String) -> [UInt8]? {
        let length = text.utf8.count
        guard length >= 56, length % 4 == 0, let data = Data(base64Encoded: text), data.count >= overhead else { return nil }
        let bytes = Array(data)
        return bytes.starts(with: header) ? bytes : nil
    }

    /// The plaintext of an encrypted field; any other string unchanged.
    func decrypt(_ text: String) throws(TermiusImportError) -> String {
        guard let envelope = Self.envelope(text) else { return text }
        let nonce = Array(envelope[2..<(2 + SecretBox.nonceSize)])
        let box = Array(envelope[(2 + SecretBox.nonceSize)...])
        guard let plaintext = SecretBox.open(box, nonce: nonce, key: key) else { throw .wrongLocalKey }
        return String(decoding: plaintext, as: UTF8.self)
    }

    /// Encrypts like Termius does. Tests build fixtures with it.
    func seal(_ text: String, nonce: [UInt8]) -> String {
        precondition(nonce.count == SecretBox.nonceSize)
        let subkey = Salsa20.hsalsa20(key: key, input: Array(nonce[0..<16]))
        let message = Array(text.utf8)
        let stream = Salsa20.keystream(key: subkey, nonce: Array(nonce[16..<24]), count: 32 + message.count)
        let ciphertext = message.enumerated().map { $0.element ^ stream[32 + $0.offset] }
        let mac = Poly1305.tag(ciphertext, key: Array(stream[0..<32]))
        return Data(Self.header + nonce + mac + ciphertext).base64EncodedString()
    }
}
