import AeroCore
import CryptoKit
import Foundation
import KeyAgent
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization
import Testing
@testable import EmbeddedSSH
@testable import SSHKit

@Suite("EmbeddedSSH errors")
struct EmbeddedSSHErrorTests {
    @Test("NIO's errors map to the SSHError cases ssh's stderr maps to")
    func classifiesNIOErrors() {
        #expect(EmbeddedSSHErrors.classify(IOError(errnoCode: ECONNREFUSED, reason: "connect")) as? SSHError == .connectionRefused)
        #expect(EmbeddedSSHErrors.classify(IOError(errnoCode: EHOSTUNREACH, reason: "connect")) as? SSHError == .hostUnreachable)
        #expect(EmbeddedSSHErrors.classify(IOError(errnoCode: ECONNRESET, reason: "read")) as? SSHError == .connectionClosed)
        #expect(EmbeddedSSHErrors.classify(ChannelError.connectTimeout(.seconds(8))) as? SSHError == .timeout)
        #expect(EmbeddedSSHErrors.classify(ChannelError.eof) as? SSHError == .connectionClosed)
        #expect(EmbeddedSSHErrors.classify(ChannelError.ioOnClosedChannel) as? SSHError == .connectionClosed)
        guard case .other = EmbeddedSSHErrors.classify(IOError(errnoCode: EACCES, reason: "socket")) as? SSHError else {
            Issue.record("an unknown errno should be .other")
            return
        }
    }

    @Test("SSHError and CancellationError pass through unchanged")
    func passesThrough() {
        #expect(EmbeddedSSHErrors.classify(SSHError.hostKeyChanged) as? SSHError == .hostKeyChanged)
        #expect(EmbeddedSSHErrors.classify(SSHError.authFailed) as? SSHError == .authFailed)
        #expect(EmbeddedSSHErrors.classify(CancellationError()) is CancellationError)
    }

    @Test("A signal exits 128 + its number where Linux and the BSDs agree, else 255 like ssh")
    func signalExitCodes() {
        #expect(EmbeddedSSHErrors.exitCode(forSignal: "TERM") == 143)
        #expect(EmbeddedSSHErrors.exitCode(forSignal: "KILL") == 137)
        #expect(EmbeddedSSHErrors.exitCode(forSignal: "HUP") == 129)
        #expect(EmbeddedSSHErrors.exitCode(forSignal: "USR1") == 255)
        #expect(EmbeddedSSHErrors.exitCode(forSignal: "") == 255)
    }
}

@Suite("EmbeddedSSH host keys")
struct EmbeddedSSHHostKeyTests {
    @Test("A NIOSSH public key converts to the HostKey ssh-keyscan would report")
    func convertsNIOKeys() throws {
        let ed25519 = Curve25519.Signing.PrivateKey()
        let key = try HostKey(nio: NIOSSHPrivateKey(ed25519Key: ed25519).publicKey)
        #expect(key.type == "ssh-ed25519")
        #expect(key.blob == wireString("ssh-ed25519".utf8) + wireString(ed25519.publicKey.rawRepresentation))

        let p256 = P256.Signing.PrivateKey()
        let ecdsa = try HostKey(nio: NIOSSHPrivateKey(p256Key: p256).publicKey)
        #expect(ecdsa.type == "ecdsa-sha2-nistp256")
        #expect(ecdsa.blob == wireString("ecdsa-sha2-nistp256".utf8) + wireString("nistp256".utf8) + wireString(p256.publicKey.x963Representation))
    }

    @Test("A pinned key passes; no pin, or pins of other types only, is unknown")
    func pinnedAndUnknownKeys() async throws {
        let env = try TestEnvironment()
        let host = RemoteHost.test()
        let pinned = TestKeys.ed25519()
        await #expect(throws: SSHError.hostKeyUnknown) { try await checkHostKey(pinned, for: host, in: env.hostKeys) }

        try await env.hostKeys.trust(pinned, for: host)
        try await checkHostKey(pinned, for: host, in: env.hostKeys)
        await #expect(throws: SSHError.hostKeyUnknown) { try await checkHostKey(TestKeys.ecdsa256(), for: host, in: env.hostKeys) }
        #expect(await !env.hostKeys.isBlocked(host))
    }

    @Test("A different key of a pinned type blocks the host")
    func changedKeyBlocks() async throws {
        let env = try TestEnvironment()
        let host = RemoteHost.test()
        try await env.hostKeys.trust(TestKeys.ed25519(), for: host)
        let offered = TestKeys.ed25519()
        await #expect(throws: SSHError.hostKeyChanged) { try await checkHostKey(offered, for: host, in: env.hostKeys) }
        let block = try #require(await env.hostKeys.block(for: host))
        #expect(block.offered == [offered])
    }

    @Test("The scanner refuses an address ssh would read as an option before connecting")
    func scannerValidatesInput() async {
        let scanner = EmbeddedHostKeyScanner()
        await #expect(throws: HostKeyError.self) { try await scanner.scan(address: "-oProxyCommand=x", port: 22) }
        await #expect(throws: HostKeyError.self) { try await scanner.scan(address: "localhost", port: 0) }
    }

    @Test("The scanner reports a closed port like the client does")
    func scannerClosedPort() async {
        await #expect(throws: SSHError.connectionRefused) { try await EmbeddedHostKeyScanner().scan(address: "127.0.0.1", port: 1) }
    }
}

@Suite("EmbeddedSSH authentication")
struct EmbeddedSSHAuthenticationTests {
    @Test("A password host offers its saved password once, and only if the server takes passwords")
    func passwordOffers() async throws {
        let env = try TestEnvironment()
        let host = RemoteHost.test(auth: .password)
        env.vault.setPasswordHosts([host.id])
        try env.vault.save("hunter2!", for: host.id)

        let offer = try await UserAuthDelegate.offer(0, host: host, credentials: env.credentials, methods: .all)
        #expect(offer.username == "dev")
        guard case .password(let password) = offer.offer else {
            Issue.record("expected a password offer, got \(offer.offer)")
            return
        }
        #expect(password.password == "hunter2!")

        await #expect(throws: SSHError.authFailed) {
            try await UserAuthDelegate.offer(1, host: host, credentials: env.credentials, methods: .all)
        }
        await #expect(throws: SSHError.authFailed) {
            try await UserAuthDelegate.offer(0, host: host, credentials: env.credentials, methods: .publicKey)
        }
        var noVault = env.credentials
        noVault.passwords = nil
        await #expect(throws: SSHError.authFailed) {
            try await UserAuthDelegate.offer(0, host: host, credentials: noVault, methods: .all)
        }
        await #expect(throws: SSHError.authFailed) {
            try await UserAuthDelegate.offer(0, host: .test(auth: .password), credentials: env.credentials, methods: .all)
        }
    }

    @Test("A key host offers each of its candidate keys once, then fails")
    func keyOffers() async throws {
        let env = try TestEnvironment()
        let first = try await env.keyStore.generate(.ed25519, name: "first", policy: .always)
        let second = try await env.keyStore.generate(.ed25519, name: "second", policy: .always)
        let host = RemoteHost.test()

        var offered: [String] = []
        for attempt in 0..<2 {
            let offer = try await UserAuthDelegate.offer(attempt, host: host, credentials: env.credentials, methods: .all)
            guard case .privateKey(let key) = offer.offer else {
                Issue.record("expected a key offer, got \(offer.offer)")
                return
            }
            offered.append(String(openSSHPublicKey: key.publicKey))
        }
        let expected = try await [first, second].asyncMap { try await publicKeyField(env.keyStore.authorizedKeysLine(for: $0.id)) }
        #expect(Set(offered) == Set(expected))
        await #expect(throws: SSHError.authFailed) {
            try await UserAuthDelegate.offer(2, host: host, credentials: env.credentials, methods: .all)
        }
        await #expect(throws: SSHError.authFailed) {
            try await UserAuthDelegate.offer(0, host: host, credentials: env.credentials, methods: .password)
        }
    }

    @Test("A host that names its key offers only that one; an unknown key id offers none")
    func namedKey() async throws {
        let env = try TestEnvironment()
        _ = try await env.keyStore.generate(.ed25519, name: "other", policy: .always)
        let chosen = try await env.keyStore.generate(.ed25519, name: "chosen", policy: .always)
        #expect(await UserAuthDelegate.candidateKeys(for: .test(keyId: chosen.id.uuidString), in: env.keyStore) == [chosen.id])
        #expect(await UserAuthDelegate.candidateKeys(for: .test(keyId: "not-a-uuid"), in: env.keyStore).isEmpty)
        await #expect(throws: SSHError.authFailed) {
            try await UserAuthDelegate.offer(0, host: .test(keyId: "not-a-uuid"), credentials: env.credentials, methods: .all)
        }
        let missing = RemoteHost.test(keyId: UUID().uuidString)
        await #expect(throws: (any Error).self) {
            try await UserAuthDelegate.offer(0, host: missing, credentials: env.credentials, methods: .all)
        }
    }

    @Test("RSA keys are not offered: NIOSSH cannot sign with them")
    func skipsRSA() async throws {
        let env = try TestEnvironment()
        let file = env.scratch.file("rsa")
        let keygen = try await runTool("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-C", "aero-e-rsa", "-f", file.filePath])
        try #require(keygen.status == 0, "\(keygen.stderr)")
        let text = try String(contentsOf: file, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        let rsa = try await env.keyStore.importOpenSSHPrivateKey(text, policy: .always)
        let ed25519 = try await env.keyStore.generate(.ed25519, name: "ed", policy: .always)
        #expect(rsa.algorithm == .rsa)
        #expect(await UserAuthDelegate.candidateKeys(for: .test(), in: env.keyStore) == [ed25519.id])
    }

    @Test("Each key's policy is asked before it is offered; a refusal fails the login")
    func policyGatesOffers() async throws {
        let denying = try TestEnvironment(approve: false)
        _ = try await denying.keyStore.generate(.ed25519, name: "touch", policy: .everySignature)
        await #expect(throws: SSHError.authFailed) {
            try await UserAuthDelegate.offer(0, host: .test(), credentials: denying.credentials, methods: .all)
        }
        #expect(denying.verifier.reasons.count == 1)
        #expect(denying.verifier.reasons.first?.contains("“touch”") == true)

        let approving = try TestEnvironment()
        _ = try await approving.keyStore.generate(.ed25519, name: "session", policy: .oncePerSession)
        let credentials = approving.credentials
        for _ in 0..<3 {
            _ = try await UserAuthDelegate.offer(0, host: .test(), credentials: credentials, methods: .all)
        }
        #expect(approving.verifier.reasons.count == 1, "once per session asks once")
    }

    private func publicKeyField(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }
}

@Suite("EmbeddedSSH client without a server")
struct EmbeddedSSHClientTests {
    @Test("Requests ssh would refuse are refused before connecting")
    func validatesRequests() async throws {
        let client = try TestEnvironment().client()
        for (command, host) in [
            ("", RemoteHost.test()),
            ("echo a\u{0}b", .test()),
            ("true", .test(address: "-oProxyCommand=x")),
            ("true", .test(user: "a b")),
            ("true", .test(port: 0)),
            ("true", .test(port: 70000)),
        ] {
            do {
                _ = try await client.run(command, on: host)
                Issue.record("\(command) on \(host.address) should be refused")
            } catch let error as SSHError {
                guard case .invalidRequest = error else {
                    Issue.record("expected invalidRequest, got \(error)")
                    continue
                }
            }
            await #expect(throws: SSHError.self) { _ = try await client.stream(command, on: host) }
        }
    }

    @Test("A blocked host is refused without connecting")
    func refusesBlockedHosts() async throws {
        let env = try TestEnvironment()
        let host = RemoteHost.test(address: "127.0.0.1", port: 1)
        await env.hostKeys.block(host)
        let client = env.client()
        await #expect(throws: SSHError.hostKeyChanged) { try await client.run("true", on: host) }
        await #expect(throws: SSHError.hostKeyChanged) { try await client.stream("true", on: host) }
    }

    @Test("Connection errors are SSHErrors")
    func connectionErrors() async throws {
        let client = try TestEnvironment().client()
        await #expect(throws: SSHError.connectionRefused) { try await client.run("true", on: .test(address: "127.0.0.1", port: 1)) }
        await #expect(throws: SSHError.nameResolutionFailed) {
            try await client.run("true", on: .test(address: "aeroops-no-such-host.invalid", port: 22), timeout: .seconds(15))
        }
        let lines = try await client.stream("true", on: .test(address: "127.0.0.1", port: 1))
        await #expect(throws: SSHError.connectionRefused) { for try await _ in lines {} }
    }

    @Test("The timeout covers the login: a server that never answers times out like ssh")
    func timesOutDuringLogin() async throws {
        let server = try await SilentServer()
        let client = try TestEnvironment().client()
        let host = RemoteHost.test(address: "127.0.0.1", port: server.port)

        let result = try await client.run("true", on: host, timeout: .milliseconds(500))
        #expect(result.timedOut)
        #expect(result.exitCode == 255)
        #expect(result.duration < .seconds(3))

        let lines = try await client.stream("true", on: host, timeout: .milliseconds(500))
        await #expect(throws: SSHError.timeout) { for try await _ in lines {} }
        await client.disconnectAll()
        await server.close()
    }

    @Test("Cancelling a run throws CancellationError; cancelling a stream finishes it")
    func cancellation() async throws {
        let server = try await SilentServer()
        let client = try TestEnvironment().client()
        let host = RemoteHost.test(address: "127.0.0.1", port: server.port)

        let run = Task { try await client.run("true", on: host) }
        try await Task.sleep(for: .milliseconds(200))
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }

        let stream = Task {
            var count = 0
            for try await _ in try await client.stream("true", on: host) { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(200))
        stream.cancel()
        #expect(try await stream.value == 0)
        await server.close()
    }
}

@Suite("EmbeddedSSH connection pool")
struct ConnectionPoolTests {
    @Test("Concurrent callers share one login; another connection opens only when every session slot is taken")
    func sharesLogins() async throws {
        let server = try await SilentServer()
        let logins = Counter()
        let pool = ConnectionPool { _ in
            logins.increment()
            try await Task.sleep(for: .milliseconds(100))
            return try await server.connection()
        }
        let host = RemoteHost.test(port: server.port)
        let reservations = try await withThrowingTaskGroup(of: (connection: SSHConnection, reused: Bool).self) { group in
            for _ in 0..<10 { group.addTask { try await pool.reserve(for: host) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(logins.value == 2)
        #expect(Set(reservations.map { ObjectIdentifier($0.connection) }).count == 2)
        #expect(reservations.allSatisfy { !$0.reused })

        let full = try #require(reservations.first { reservation in
            reservations.filter { $0.connection === reservation.connection }.count == SSHConnection.maxSessions
        }?.connection)
        full.release()
        let again = try await pool.reserve(for: host)
        #expect(again.reused)
        #expect(logins.value == 2)
        await pool.disconnectAll()
        await server.close()
    }

    @Test("A closed connection is replaced; a settings change drops the old one")
    func replacesConnections() async throws {
        let server = try await SilentServer()
        let logins = Counter()
        let pool = ConnectionPool { _ in
            logins.increment()
            return try await server.connection()
        }
        let host = RemoteHost.test(port: server.port)
        let first = try await pool.reserve(for: host).connection
        try await first.channel.close()
        let second = try await pool.reserve(for: host)
        #expect(second.connection !== first)
        #expect(!second.reused)
        #expect(logins.value == 2)

        var changed = host
        changed.user = "other"
        let third = try await pool.reserve(for: changed)
        #expect(third.connection !== second.connection)
        try await second.connection.channel.closeFuture.get()
        #expect(logins.value == 3)

        await pool.disconnect(host.id)
        try await third.connection.channel.closeFuture.get()
        await server.close()
    }

    @Test("A failed login fails every caller waiting for it; the next call tries again")
    func sharesFailures() async throws {
        let logins = Counter()
        let pool = ConnectionPool { _ in
            logins.increment()
            try await Task.sleep(for: .milliseconds(100))
            throw SSHError.authFailed
        }
        let host = RemoteHost.test()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await #expect(throws: SSHError.authFailed) { try await pool.reserve(for: host) }
                }
            }
            try await group.waitForAll()
        }
        #expect(logins.value == 1)
        await #expect(throws: SSHError.authFailed) { try await pool.reserve(for: host) }
        #expect(logins.value == 2)
    }
}

final class Counter: Sendable {
    private let state = Mutex(0)

    func increment() {
        state.withLock { $0 += 1 }
    }

    var value: Int { state.withLock { $0 } }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
