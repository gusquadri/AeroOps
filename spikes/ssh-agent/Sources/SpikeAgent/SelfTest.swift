// In-process protocol round trips with ephemeral keys (no Keychain, no socket).
import CryptoKit
import Foundation
import Security

func selfTest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        log("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    // mpint edge cases (RFC 4251 §5)
    var w = WireWriter(); w.mpint(unsigned: [0x00, 0x00])
    check(w.bytes == [0, 0, 0, 0], "mpint(0) is empty string")
    w = WireWriter(); w.mpint(unsigned: [0x00, 0x80, 0x01])
    check(w.bytes == [0, 0, 0, 3, 0x00, 0x80, 0x01], "mpint strips zeros, re-adds 0x00 for high bit")
    w = WireWriter(); w.mpint(unsigned: [0x00, 0x7f])
    check(w.bytes == [0, 0, 0, 1, 0x7f], "mpint no pad when high bit clear")

    do {
        let ed = Ed25519AgentKey(key: .init(), comment: "t-ed25519")
        let rsa = try RSAAgentKey(key: RSAAgentKey.generate(bits: 2048), comment: "t-rsa")
        var keys: [any AgentKey] = [ed, rsa]
        let se = SecureEnclave.isAvailable ? SecureEnclaveP256AgentKey(key: try .init(), comment: "t-se") : nil
        if let se { keys.append(se) }
        let server = AgentServer(keys: keys, socketPath: "/unused")

        let ids = server.handle([AgentMsg.requestIdentities], conn: 0)
        var ir = WireReader(ids)
        check(try ir.u8() == AgentMsg.identitiesAnswer && ir.u32() == UInt32(keys.count), "IDENTITIES_ANSWER lists \(keys.count) keys")

        func sign(_ k: any AgentKey, _ data: [UInt8], flags: UInt32) -> (alg: String, sig: [UInt8])? {
            var req = WireWriter()
            req.u8(AgentMsg.signRequest); req.string(k.publicKeyBlob); req.string(data); req.u32(flags)
            let resp = server.handle(req.bytes, conn: 0)
            var r = WireReader(resp)
            guard (try? r.u8()) == AgentMsg.signResponse, let blob = try? r.string() else { return nil }
            var br = WireReader(blob)
            guard let alg = try? br.string(), let sig = try? br.string() else { return nil }
            return (String(decoding: alg, as: UTF8.self), sig)
        }

        for i in 0..<20 {
            let data = (0..<100).map { _ in UInt8.random(in: 0...255) }
            if let (alg, sig) = sign(ed, data, flags: 0) {
                if i == 0 { check(alg == "ssh-ed25519" && ed.key.publicKey.isValidSignature(sig, for: data), "ed25519 sign/verify") }
            } else { check(false, "ed25519 sign") }

            if let se {
                guard let (alg, sig) = sign(se, data, flags: 0) else { check(false, "se sign"); continue }
                // Decode string(mpint r || mpint s), left-pad to 32 bytes each.
                var sr = WireReader(sig)
                let pad = { (b: [UInt8]) -> [UInt8] in let m = Array(b.drop(while: { $0 == 0 })); return Array(repeating: 0, count: max(0, 32 - m.count)) + m }
                let r = pad(try sr.string()), s = pad(try sr.string())
                let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: r + s)
                let ok = alg == "ecdsa-sha2-nistp256" && se.key.publicKey.isValidSignature(ecdsa, for: data)
                if !ok || i == 19 { check(ok, "SE ecdsa-sha2-nistp256 mpint r/s round trip (20 signatures)") }
                if !ok { break }
            }
        }

        let data = Array("hello".utf8)
        let pub = SecKeyCopyPublicKey(rsa.key)!
        for (flags, name, alg) in [(UInt32(2), "rsa-sha2-256", SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256),
                                   (4, "rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512),
                                   (6, "rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512)] {
            let res = sign(rsa, data, flags: flags)
            let ok = res.map { $0.alg == name && SecKeyVerifySignature(pub, alg, Data(data) as CFData, Data($0.sig) as CFData, nil) } ?? false
            check(ok, "rsa flags=\(flags) -> \(name) verifies")
        }
        check(sign(rsa, data, flags: 0) == nil, "rsa flags=0 (SHA-1 ssh-rsa) refused")

        var unknown = WireWriter()
        unknown.u8(AgentMsg.signRequest); unknown.string([1, 2, 3]); unknown.string(data); unknown.u32(0)
        check(server.handle(unknown.bytes, conn: 0) == [AgentMsg.failure], "unknown key -> FAILURE")
        check(server.handle([AgentMsg.signRequest, 0, 0], conn: 0) == [AgentMsg.failure], "truncated -> FAILURE")
        for t: UInt8 in [17, 18, 19, 22, 23, 25] {
            check(server.handle([t], conn: 0) == [AgentMsg.failure], "\(AgentMsg.name(t)) refused")
        }
    } catch {
        check(false, "unexpected error \(error)")
    }
    log("selftest: \(failures == 0 ? "all passed" : "\(failures) failure(s)")")
    return failures == 0 ? 0 : 1
}
