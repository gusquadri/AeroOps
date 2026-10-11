// spike-agent — Phase 0 throwaway.
//
//   spike-agent serve   [--socket P] [--keychain legacy|dp] [--group G] [--no-ui] [--keys ed25519,se,rsa]
//   spike-agent probe-keychain [--keychain legacy|dp] [--group G] [--no-ui] [--op add|read|delete]
//   spike-agent probe-se
//   spike-agent selftest
//   spike-agent cleanup [--keychain legacy|dp] [--group G]
import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct Options {
    var command = "serve"
    var socket = NSHomeDirectory() + "/.aeroops/spike-agent.sock"
    var keychain = Keychain(mode: .legacy, noUI: false)
    var keys: Set<String> = ["ed25519", "se", "rsa"]
    var op = "add"

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        var mode = "legacy", group: String?, noUI = false
        if let c = it.next() { command = c }
        while let a = it.next() {
            switch a {
            case "--socket": socket = it.next()!
            case "--keychain": mode = it.next()!
            case "--group": group = it.next()!
            case "--no-ui": noUI = true
            case "--keys": keys = Set(it.next()!.split(separator: ",").map(String.init))
            case "--op": op = it.next()!
            default: fatalError("unknown argument \(a)")
            }
        }
        keychain = Keychain(mode: mode == "dp" ? .dataProtection(accessGroup: group) : .legacy, noUI: noUI)
    }
}

let accounts = ["ed25519", "se-p256", "rsa", "probe"]

func loadKeys(_ o: Options) -> [any AgentKey] {
    let kc = o.keychain
    var keys: [any AgentKey] = []
    log("key store: \(kc.mode)\(kc.noUI ? ", no UI" : "")")

    if o.keys.contains("ed25519") {
        do {
            let (raw, created) = try kc.loadOrCreate("ed25519", label: "AeroOps spike Ed25519") {
                Curve25519.Signing.PrivateKey().rawRepresentation
            }
            let k = Ed25519AgentKey(key: try .init(rawRepresentation: raw), comment: "aeroops-spike-ed25519")
            log("ed25519: \(created ? "generated + stored" : "loaded from Keychain") \(k.fingerprint)")
            keys.append(k)
        } catch { log("ed25519: FAILED \(error)") }
    }

    if o.keys.contains("se") {
        if !SecureEnclave.isAvailable {
            log("se-p256: SecureEnclave.isAvailable == false")
        } else {
            do {
                let (blob, created) = try kc.loadOrCreate("se-p256", label: "AeroOps spike SE P-256 (wrapped)") {
                    // privateKeyUsage only: no Touch ID. Per-key policy would add .userPresence
                    // (or .biometryCurrentSet) here and pass an LAContext when signing.
                    var err: Unmanaged<CFError>?
                    let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &err)!
                    return try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac).dataRepresentation
                }
                let k = SecureEnclaveP256AgentKey(key: try .init(dataRepresentation: blob), comment: "aeroops-spike-se-p256")
                log("se-p256: \(created ? "generated in SE + wrapped blob stored" : "wrapped blob loaded") (\(blob.count) B blob) \(k.fingerprint)")
                keys.append(k)
            } catch { log("se-p256: FAILED \(error)") }
        }
    }

    if o.keys.contains("rsa") {
        do {
            let (der, created) = try kc.loadOrCreate("rsa", label: "AeroOps spike RSA-3072") {
                try RSAAgentKey.privateDER(RSAAgentKey.generate())
            }
            let k = try RSAAgentKey(key: RSAAgentKey.load(privateDER: der), comment: "aeroops-spike-rsa3072")
            log("rsa: \(created ? "generated + stored" : "loaded from Keychain") \(k.fingerprint)")
            keys.append(k)
        } catch { log("rsa: FAILED \(error)") }
    }
    return keys
}

func probeKeychain(_ o: Options) -> Int32 {
    let kc = o.keychain
    let payload = Data("not-a-secret-probe".utf8)
    log("probe \(o.op) on \(kc.mode)\(kc.noUI ? " (no UI)" : "")")
    do {
        switch o.op {
        case "add":
            kc.delete("probe")
            try kc.add("probe", data: payload, label: "AeroOps spike probe")
            log("add OK")
            let back = try kc.read("probe")
            log("read-back: \(back == payload ? "OK" : "MISMATCH")")
        case "read":
            let back = try kc.read("probe")
            log("read: \(back == nil ? "not found" : back == payload ? "OK" : "MISMATCH")")
        case "delete":
            log("delete: OSStatus \(kc.delete("probe"))")
        case "update":
            var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Keychain.service, kSecAttrAccount: "probe"]
            if case .dataProtection = kc.mode { q[kSecUseDataProtectionKeychain] = true }
            log("update: OSStatus \(SecItemUpdate(q as CFDictionary, [kSecValueData: payload] as CFDictionary))")
        default:
            log("unknown op"); return 2
        }
        return 0
    } catch {
        log("\(error)")
        return 1
    }
}

func probeSecureEnclave() -> Int32 {
    log("SecureEnclave.isAvailable = \(SecureEnclave.isAvailable)")
    guard SecureEnclave.isAvailable else { return 1 }
    let msg = Data("aeroops secure enclave probe".utf8)
    do {
        let k = try SecureEnclave.P256.Signing.PrivateKey()
        let sig = try k.signature(for: msg)
        log("default key: blob \(k.dataRepresentation.count) B, sign+verify(message) = \(k.publicKey.isValidSignature(sig, for: msg))")
        // Confirms signature(for: data) == signature over SHA256(data):
        log("verifies as digest SHA256(msg): \(k.publicKey.isValidSignature(sig, for: SHA256.hash(data: msg)))")

        let reloaded = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: k.dataRepresentation)
        let sig2 = try reloaded.signature(for: msg)
        log("reloaded from dataRepresentation: same pubkey = \(reloaded.publicKey.rawRepresentation == k.publicKey.rawRepresentation), verify = \(k.publicKey.isValidSignature(sig2, for: msg))")

        // Touch ID policy hook: key requires user presence; signing with an
        // LAContext that forbids interaction must fail fast instead of prompting.
        var err: Unmanaged<CFError>?
        let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &err)!
        let gated = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac)
        log("userPresence key created (creation needs no auth)")
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let gatedNoUI = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: gated.dataRepresentation, authenticationContext: ctx)
        do {
            _ = try gatedNoUI.signature(for: msg)
            log("userPresence key signed WITHOUT auth?!")
        } catch {
            let ns = error as NSError
            log("userPresence sign with interactionNotAllowed -> \(ns.domain) \(ns.code): \(ns.localizedDescription)")
        }
        return 0
    } catch {
        let ns = error as NSError
        log("Secure Enclave error: \(ns.domain) \(ns.code) \(ns)")
        return 1
    }
}

// MARK: entry point

let opts = Options(CommandLine.arguments)
if opts.keychain.noUI, case .legacy = opts.keychain.mode {
    log("SecKeychainSetUserInteractionAllowed(false) -> \(setLegacyKeychainUserInteraction(allowed: false).map(String.init) ?? "symbol missing")")
}
log("pid \(getpid()) exe \(executablePath(getpid()))")

switch opts.command {
case "serve":
    let keys = loadKeys(opts)
    guard !keys.isEmpty else { log("no keys loaded"); exit(1) }
    for k in keys { log("pub: \(k.authorizedKeysLine)") }
    let server = AgentServer(keys: keys, socketPath: opts.socket)
    do { try server.bindAndListen() } catch { log("\(error)"); exit(1) }
    signal(SIGPIPE, SIG_IGN)
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { log("signal \(sig): removing socket, exiting"); server.shutdown(); exit(0) }
        s.resume()
        sources.append(s)
    }
    Thread.detachNewThread { server.acceptLoop() }
    dispatchMain()

case "probe-keychain":
    exit(probeKeychain(opts))

case "probe-se":
    exit(probeSecureEnclave())

case "selftest":
    exit(selfTest())

case "cleanup":
    for a in accounts {
        let s = opts.keychain.delete(a)
        log("delete \(a) from \(opts.keychain.mode): OSStatus \(s)\(s == errSecItemNotFound ? " (not found)" : "")")
    }

default:
    log("unknown command \(opts.command)")
    exit(2)
}
