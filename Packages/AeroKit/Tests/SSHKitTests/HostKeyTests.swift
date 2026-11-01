import AeroCore
import Darwin
import Foundation
import Testing
@testable import SSHKit

@Suite("Host keys")
struct HostKeyTests {
    @Test("fingerprints, sizes and labels match ssh-keygen -lf")
    func matchesSSHKeygen() async throws {
        let scratch = try ScratchDirectory()
        let keys = [
            try HostKey(type: "ssh-ed25519", base64: DevServerKeys.ed25519),
            try HostKey(type: "ecdsa-sha2-nistp256", base64: DevServerKeys.ecdsa),
            try HostKey(type: "ssh-rsa", base64: DevServerKeys.rsa),
            TestKeys.ed25519(),
            TestKeys.ecdsa384(),
            TestKeys.ecdsa521(),
        ]
        for (index, key) in keys.enumerated() {
            let file = try scratch.write("k\(index).pub", "\(key.type) \(key.base64) test\(index)\n")
            let result = try await runTool("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", file.filePath])
            #expect(result.status == 0, "\(result.stderr)")
            // "256 SHA256:koNW6c... test0 (ED25519)"
            let expected = "\(key.bits.map(String.init) ?? "?") \(key.fingerprint) test\(index) (\(key.displayType))"
            #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        }
        #expect(keys[0].fingerprint == "SHA256:koNW6caWP9qADQ1kYhXgl2kfMSyJ2dLyxE1SOhdE8lg")
        #expect(keys[2].bits == 3072)
    }

    @Test("rejects malformed keys")
    func rejectsMalformed() {
        #expect(throws: HostKeyError.self) { try HostKey(type: "ssh-ed25519", base64: "not base64!") }
        #expect(throws: HostKeyError.self) { try HostKey(type: "ssh-rsa", base64: DevServerKeys.ed25519) }
        #expect(throws: HostKeyError.self) { try HostKey(type: "ssh-ed25519", base64: "AAAA") }
    }

    @Test("Codable round trip uses the known_hosts fields")
    func codable() throws {
        let key = DevServerKeys.ed25519Key
        let data = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(HostKey.self, from: data) == key)
        #expect(String(decoding: data, as: UTF8.self).contains(DevServerKeys.ed25519.replacing("/", with: "\\/")))
    }
}

@Suite("known_hosts")
struct KnownHostsTests {
    let ed = DevServerKeys.ed25519Key
    let ecdsa = try! HostKey(type: "ecdsa-sha2-nistp256", base64: DevServerKeys.ecdsa)

    @Test("parses entries, comma lists, wildcards, negation and markers; keeps other lines")
    func parse() {
        let other = TestKeys.ed25519()
        let text = """
        # comment line

        [localhost]:2222 ssh-ed25519 \(DevServerKeys.ed25519) some comment
        web1,10.0.0.12 ecdsa-sha2-nistp256 \(DevServerKeys.ecdsa)
        *.example.com,!bad.example.com ssh-ed25519 \(other.base64)
        @revoked [localhost]:2222 ssh-ed25519 \(other.base64)
        @cert-authority * ssh-ed25519 \(other.base64)
        garbage line
        """
        let file = KnownHostsFile(text: text)
        #expect(file.keys(for: "[localhost]:2222") == [ed])
        #expect(file.keys(for: "[LOCALHOST]:2222") == [ed])
        #expect(file.keys(for: "localhost").isEmpty)
        #expect(file.keys(for: "10.0.0.12") == [ecdsa])
        #expect(file.keys(for: "web1") == [ecdsa])
        #expect(file.keys(for: "a.example.com") == [other])
        #expect(file.keys(for: "bad.example.com").isEmpty)
        #expect(file.text == text + "\n")
    }

    @Test("add appends once; remove drops names from lists and deletes empty entries")
    func addRemove() {
        var file = KnownHostsFile(text: "# keep\nweb1,[localhost]:2222 ssh-ed25519 \(DevServerKeys.ed25519)\n")
        let addedExisting = file.add(ed, for: "[localhost]:2222")
        let addedNew = file.add(ecdsa, for: "[localhost]:2222")
        #expect(!addedExisting)
        #expect(addedNew)
        #expect(file.keys(for: "[localhost]:2222") == [ed, ecdsa])

        let removed = file.remove(name: "[LocalHost]:2222")
        #expect(removed == 2)
        #expect(file.keys(for: "[localhost]:2222").isEmpty)
        #expect(file.keys(for: "web1") == [ed])
        #expect(file.text == "# keep\nweb1 ssh-ed25519 \(DevServerKeys.ed25519)\n")
    }

    @Test("hashed names written by ssh-keygen -H match; our entries are found by ssh-keygen -F")
    func interoperatesWithSSHKeygen() async throws {
        let scratch = try ScratchDirectory()
        var file = KnownHostsFile()
        file.add(ed, for: "[localhost]:2222")
        file.add(ecdsa, for: "example.com")
        let url = try scratch.write("known_hosts", file.text, mode: 0o600)

        let found = try await runTool("/usr/bin/ssh-keygen", ["-F", "[localhost]:2222", "-f", url.filePath])
        #expect(found.status == 0)
        #expect(found.stdout.contains("[localhost]:2222 ssh-ed25519 \(DevServerKeys.ed25519)"))

        let hashed = try await runTool("/usr/bin/ssh-keygen", ["-H", "-f", url.filePath])
        #expect(hashed.status == 0, "\(hashed.stderr)")
        let hashedText = try #require(scratch.read("known_hosts"))
        #expect(hashedText.hasPrefix("|1|"))
        #expect(!hashedText.contains("localhost"))

        var parsed = KnownHostsFile(text: hashedText)
        #expect(parsed.keys(for: "[localhost]:2222") == [ed])
        #expect(parsed.keys(for: "example.com") == [ecdsa])
        #expect(parsed.keys(for: "other.com").isEmpty)
        let removed = parsed.remove(name: "[localhost]:2222")
        #expect(removed == 1)
        #expect(parsed.keys(for: "[localhost]:2222").isEmpty)
        #expect(parsed.keys(for: "example.com") == [ecdsa])
    }

    @Test("glob follows OpenSSH match_pattern")
    func glob() {
        func g(_ p: String, _ t: String) -> Bool { KnownHostsFile.glob(Array(p.utf8), Array(t.utf8)) }
        #expect(g("*", "anything"))
        #expect(g("10.0.0.?", "10.0.0.7"))
        #expect(!g("10.0.0.?", "10.0.0.17"))
        #expect(g("*.example.com", "a.b.example.com"))
        #expect(!g("*.example.com", "example.com"))
        #expect(g("a*b*c", "aXXbYYc"))
    }
}

@Suite("HostKeyStore")
struct HostKeyStoreTests {
    let scratch: ScratchDirectory
    let context: SSHContext
    let host = RemoteHost.test()

    init() throws {
        scratch = try ScratchDirectory()
        try scratch.write("scan.out", DevServerKeys.keyscanOutput)
        let keyscan = try scratch.script("keyscan", "cat \(ShellQuote.quote(scratch.file("scan.out").filePath))")
        let ssh = try scratch.script("ssh", "echo called >> \(ShellQuote.quote(scratch.file("ssh.log").filePath)); exit 0")
        context = SSHContext(paths: scratch.paths(), sshExecutable: ssh, keyscanExecutable: keyscan)
    }

    @Test("TOFU: unknown, then trusted after trust(), persisted as [host]:port with 0600")
    func trustOnFirstUse() async throws {
        let store = HostKeyStore(context: context, keychain: InMemoryKeychain())
        guard case .unknown(let offered) = try await store.verify(host) else {
            Issue.record("expected unknown")
            return
        }
        #expect(offered.map(\.displayType) == ["RSA", "ECDSA", "ED25519"])
        let ed = try #require(offered.first { $0.type == "ssh-ed25519" })
        try await store.trust(ed, for: host)
        try await store.trust(ed, for: host) // idempotent

        #expect(try await store.verify(host) == .trusted(ed))
        #expect(try await store.pinnedKeys(for: host) == [ed])
        let text = try String(contentsOf: context.knownHostsFile, encoding: .utf8)
        #expect(text == "[localhost]:2222 ssh-ed25519 \(DevServerKeys.ed25519)\n")
        var info = stat()
        lstat(context.knownHostsFile.filePath, &info)
        #expect(info.st_mode & 0o777 == 0o600)

        try await store.forget(host)
        #expect(try await store.pinnedKeys(for: host).isEmpty)
    }

    @Test("a changed key blocks the host until the user replaces the pin")
    func changedKeyBlocks() async throws {
        let store = HostKeyStore(context: context, keychain: InMemoryKeychain())
        let pinned = TestKeys.ed25519()
        try await store.trust(pinned, for: host)

        guard case .changed(let old, let offered) = try await store.verify(host) else {
            Issue.record("expected changed")
            return
        }
        #expect(old == [pinned])
        #expect(offered.count == 3)
        #expect(await store.isBlocked(host))
        #expect(await store.blockedHosts["[localhost]:2222"]?.pinned == [pinned])

        // The runner refuses before ssh starts.
        let runner = SSHRunner(context: context, hostKeys: store)
        await #expect(throws: SSHError.hostKeyChanged) { try await runner.run("true", on: host) }
        await #expect(throws: SSHError.hostKeyChanged) { try await runner.stream("true", on: host) }
        #expect(scratch.read("ssh.log") == nil)

        // Adding the new key next to the old one is refused without explicit replacement.
        let real = DevServerKeys.ed25519Key
        await #expect(throws: HostKeyError.self) { try await store.trust(real, for: host) }
        try await store.trust(real, for: host, replacingPinned: true)
        #expect(await !store.isBlocked(host))
        #expect(try await store.pinnedKeys(for: host) == [real])
        #expect(try await runner.run("true", on: host).succeeded)
        #expect(scratch.read("ssh.log") == "called\n")
    }

    @Test("ssh reporting a changed key blocks the host")
    func sshReportBlocks() async throws {
        let banner = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r
        Host key verification failed.\r
        """
        try scratch.write("banner", banner)
        let ssh = try scratch.script("ssh-changed", "cat \(ShellQuote.quote(scratch.file("banner").filePath)) >&2; exit 255")
        let context = SSHContext(paths: scratch.paths(), sshExecutable: ssh)
        let store = HostKeyStore(context: context, keychain: InMemoryKeychain())
        let runner = SSHRunner(context: context, hostKeys: store)
        let result = try await runner.run("true", on: host)
        #expect(result.transportError == .hostKeyChanged)
        #expect(await store.isBlocked(host))
        await store.unblock(host)
        #expect(await !store.isBlocked(host))
    }

    @Test("a key trusted on one device reaches the other's known_hosts copy, and so does forgetting it")
    func pinsSyncBetweenDevices() async throws {
        let pins = InMemoryKeychain()
        let mac = HostKeyStore(keychain: pins, knownHostsFile: scratch.file("mac_known_hosts"))
        let phone = HostKeyStore(keychain: pins, knownHostsFile: scratch.file("phone_known_hosts"))
        try await phone.trust(DevServerKeys.ed25519Key, for: host)
        #expect(pins.items().map(\.syncs) == [true])

        #expect(try await mac.refreshKnownHostsFile())
        #expect(scratch.read("mac_known_hosts") == "[localhost]:2222 ssh-ed25519 \(DevServerKeys.ed25519)\n")
        #expect(try await mac.refreshKnownHostsFile() == false)
        try await phone.forget(host)
        #expect(try await mac.refreshKnownHostsFile())
        #expect(scratch.read("mac_known_hosts") == "")
        #expect(pins.items().isEmpty)
    }

    @Test("a synced item whose name is not one literal host never reaches known_hosts")
    func syncedPinNamesAreLiteral() async throws {
        let pins = InMemoryKeychain()
        let line = "ssh-ed25519 \(DevServerKeys.ed25519)"
        for name in ["*", "a,b", "x\n* \(line)"] {
            try pins.save(KeychainItem(account: name, record: Data("\(name) \(line)\n".utf8), syncs: true), secret: Data())
        }
        let store = HostKeyStore(keychain: pins, knownHostsFile: scratch.file("known_hosts"))
        try await store.refreshKnownHostsFile()
        #expect(scratch.read("known_hosts") == "")
    }

    @Test("a key accepted on another device lifts the block here")
    func syncedPinLiftsBlock() async throws {
        let pins = InMemoryKeychain()
        let mac = HostKeyStore(keychain: pins, knownHostsFile: scratch.file("mac_known_hosts"))
        let phone = HostKeyStore(keychain: pins, knownHostsFile: scratch.file("phone_known_hosts"))
        try await mac.trust(DevServerKeys.ed25519Key, for: host)
        await mac.block(host)

        #expect(try await mac.refreshKnownHostsFile() == false)
        #expect(await mac.isBlocked(host))

        try await phone.forget(host)
        try await phone.trust(HostKey(type: "ecdsa-sha2-nistp256", base64: DevServerKeys.ecdsa), for: host)
        #expect(try await mac.refreshKnownHostsFile())
        #expect(await !mac.isBlocked(host))
    }

    @Test("scanner arguments and failure classification")
    func scannerErrors() async throws {
        let scanner = HostKeyScanner()
        #expect(scanner.arguments(address: "localhost", port: 2222) == ["-t", "ed25519,ecdsa,rsa", "-p", "2222", "-T", "5", "--", "localhost"])
        await #expect(throws: HostKeyError.self) { try await scanner.scan(address: "-oProxyCommand=x", port: 22) }
        await #expect(throws: HostKeyError.self) { try await scanner.scan(address: "host", port: 0) }

        #expect(throws: SSHError.connectionRefused) {
            try HostKeyScanner.parse(stdout: "", stderr: "write (localhost): Broken pipe\r\nwrite (localhost): Broken pipe\r\n")
        }
        #expect(throws: SSHError.nameResolutionFailed) {
            try HostKeyScanner.parse(stdout: "", stderr: "getaddrinfo nonexistent-host.invalid: nodename nor servname provided, or not known\r\n")
        }
        #expect(throws: SSHError.timeout) { try HostKeyScanner.parse(stdout: "", stderr: "") }
        #expect(throws: SSHError.self) { try HostKeyScanner.parse(stdout: "# localhost:2222 SSH-2.0-OpenSSH_10.3\n", stderr: "") }
        #expect(try HostKeyScanner.parse(stdout: DevServerKeys.keyscanOutput + DevServerKeys.keyscanOutput, stderr: "").count == 3)
    }
}
