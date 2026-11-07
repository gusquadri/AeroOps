import AeroCore
import AskpassProtocol
import Darwin
import Foundation
import Synchronization
import Testing
@testable import KeyAgent

/// Accepts every peer as a new ssh process, or always as the same one.
private final class FakeAskpassValidator: AskpassPeerValidator {
    private let nextPID = Mutex<pid_t>(40_000)
    private let fixedPID: pid_t?
    private let rejection: String?

    init(fixedPID: pid_t? = nil, rejection: String? = nil) {
        self.fixedPID = fixedPID
        self.rejection = rejection
    }

    func validate(socket fd: Int32) -> AskpassPeerVerdict {
        if let rejection { return .rejected(rejection) }
        if let fixedPID { return .accepted(sshPID: fixedPID) }
        return .accepted(sshPID: nextPID.withLock { $0 += 1; return $0 })
    }
}

@Suite("Host password vault")
struct HostPasswordVaultTests {
    let host = UUID()

    @Test("answers only password hosts with a saved password")
    func answers() throws {
        let store = InMemoryKeychain()
        let vault = HostPasswordVault(keychain: store)
        let request = AskpassRequest(host: host, prompt: "admin@nas's password: ")
        #expect(vault.answer(request) == .failure(.notPasswordHost))

        vault.setPasswordHosts([host])
        #expect(!vault.hasPassword(for: host))
        #expect(vault.answer(request) == .failure(.noPassword))

        try vault.save("hunter2 ünïcode", for: host)
        #expect(vault.hasPassword(for: host))
        #expect(vault.isSaved(host))
        #expect(store.items().map(\.account) == [host.uuidString])
        #expect(store.items().allSatisfy { $0.syncs && !$0.record.contains(Data("hunter2".utf8)) })
        #expect(vault.answer(request) == .success("hunter2 ünïcode"))

        vault.setPasswordHosts([])
        #expect(!vault.hasPassword(for: host))
        #expect(vault.isSaved(host))
        #expect(vault.answer(request) == .failure(.notPasswordHost))

        vault.setPasswordHosts([host])
        try vault.delete(for: host)
        #expect(!vault.hasPassword(for: host) && !vault.isSaved(host))
        #expect(vault.answer(request) == .failure(.noPassword))
    }

    @Test("a password saved on another device is reported once")
    func passwordReplacedElsewhere() throws {
        let store = InMemoryKeychain()
        let vault = HostPasswordVault(keychain: store)
        try vault.save("first", for: host)
        #expect(vault.setPasswordHosts([host]).isEmpty)

        try HostPasswordVault(keychain: store).save("second", for: host)
        #expect(vault.setPasswordHosts([host]) == [host])
        #expect(vault.setPasswordHosts([host]).isEmpty)

        try vault.save("third", for: host)
        #expect(vault.setPasswordHosts([host]).isEmpty)
    }

    @Test("a Keychain that cannot be read reports no replaced passwords")
    func lockedKeychainReportsNoChange() throws {
        let store = LockableKeychain()
        let vault = HostPasswordVault(keychain: store)
        try vault.save("first", for: host)
        vault.setPasswordHosts([host])

        store.setLocked(true)
        #expect(vault.setPasswordHosts([host]).isEmpty)
        #expect(!vault.hasPassword(for: host))

        store.setLocked(false)
        #expect(vault.setPasswordHosts([host]).isEmpty)
        #expect(vault.hasPassword(for: host))
    }

    @Test("setPasswordHosts reads which passwords are saved from the store")
    func cacheFromStore() throws {
        let store = InMemoryKeychain()
        store.save(KeychainItem(account: host.uuidString, syncs: true), secret: Data("from a previous launch".utf8))
        let vault = HostPasswordVault(keychain: store)
        #expect(!vault.hasPassword(for: host))
        vault.setPasswordHosts([host, UUID()])
        #expect(vault.hasPassword(for: host))

        store.save(KeychainItem(account: host.uuidString, syncs: true), secret: Data("two\nlines".utf8))
        #expect(vault.answer(AskpassRequest(host: host, prompt: "Password:")) == .failure(.noPassword))
        #expect(!vault.hasPassword(for: host))
    }

    @Test("refuses passwords ssh cannot send", arguments: [
        ("", Askpass.PasswordProblem.empty),
        ("a\nb", .lineBreak),
        ("a\rb", .lineBreak),
        (String(repeating: "x", count: Askpass.maxPasswordBytes + 1), .tooLong),
    ])
    func unusable(_ password: String, _ problem: Askpass.PasswordProblem) {
        let store = InMemoryKeychain()
        let vault = HostPasswordVault(keychain: store)
        #expect(throws: HostPasswordError.unusable(problem)) { try vault.save(password, for: host) }
        #expect(throws: HostPasswordError.unusable(problem)) { try vault.beginTemporary(password, for: host) }
        #expect(store.items().isEmpty)
    }

    @Test("a test password works only for its host and its token, until ended")
    func temporary() throws {
        let store = InMemoryKeychain()
        let vault = HostPasswordVault(keychain: store)
        let token = try vault.beginTemporary("draft", for: host)
        #expect(Askpass.isValidToken(token))
        #expect(vault.answer(AskpassRequest(host: host, token: token, prompt: "Password:")) == .success("draft"))
        #expect(vault.answer(AskpassRequest(host: UUID(), token: token, prompt: "Password:")) == .failure(.unknownToken))
        #expect(vault.answer(AskpassRequest(host: host, token: Askpass.makeToken(), prompt: "Password:")) == .failure(.unknownToken))
        #expect(store.items().isEmpty)
        #expect(!vault.hasPassword(for: host))

        vault.endTemporary(token)
        #expect(vault.answer(AskpassRequest(host: host, token: token, prompt: "Password:")) == .failure(.unknownToken))
    }
}

@Suite("Askpass server")
struct AskpassServerTests {
    let host = UUID()

    private func start(
        _ dir: TempDirectory, validator: any AskpassPeerValidator = FakeAskpassValidator()
    ) throws -> (AskpassServer, HostPasswordVault) {
        let vault = HostPasswordVault(keychain: InMemoryKeychain())
        let server = AskpassServer(socketURL: dir.appending("aero/askpass.sock"), vault: vault, validator: validator)
        try server.start()
        return (server, vault)
    }

    /// What the helper does, off the cooperative pool (the client blocks on the socket).
    private func ask(
        _ server: AskpassServer, host: UUID, token: String? = nil, prompt: String = "admin@nas's password: "
    ) async -> Result<String, AskpassFailure> {
        var environment = [
            Askpass.Environment.socket: server.socketURL.path(percentEncoded: false),
            Askpass.Environment.host: host.uuidString,
        ]
        environment[Askpass.Environment.token] = token
        let helperEnvironment = environment
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Result { () throws(AskpassFailure) in
                    try AskpassClient.password(prompt: prompt, environment: helperEnvironment)
                })
            }
        }
    }

    @Test("hands the saved password to a trusted helper and reports it")
    func answers() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, vault) = try start(dir)
        defer { server.stop() }
        vault.setPasswordHosts([host])
        try vault.save("s3cret", for: host)
        var events = server.events.makeAsyncIterator()

        #expect(await ask(server, host: host) == .success("s3cret"))
        #expect(await events.next() == AskpassEvent(host: host, viaToken: false, outcome: .answered))
        #expect(await ask(server, host: host, prompt: "(admin@nas) Password: ") == .success("s3cret"))
        #expect(await events.next()?.outcome == .answered)
    }

    @Test("answers each ssh process once: a second prompt means the password was rejected")
    func oncePerProcess() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, vault) = try start(dir, validator: FakeAskpassValidator(fixedPID: 4242))
        defer { server.stop() }
        vault.setPasswordHosts([host])
        try vault.save("wrong", for: host)
        var events = server.events.makeAsyncIterator()

        #expect(await ask(server, host: host) == .success("wrong"))
        #expect(await events.next()?.outcome == .answered)
        #expect(await ask(server, host: host) == .failure(AskpassFailure(AskpassRefusal.alreadyAnswered.description)))
        #expect(await events.next() == AskpassEvent(host: host, viaToken: false, outcome: .refused(.alreadyAnswered)))
    }

    @Test("refuses with a reason that never contains the password", arguments: [
        (false, AskpassRefusal.noPassword),
        (true, AskpassRefusal.unknownToken),
    ])
    func refusals(_ useToken: Bool, _ refusal: AskpassRefusal) async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, vault) = try start(dir)
        defer { server.stop() }
        vault.setPasswordHosts([host])
        var events = server.events.makeAsyncIterator()
        let token = useToken ? Askpass.makeToken() : nil
        #expect(await ask(server, host: host, token: token) == .failure(AskpassFailure(refusal.description)))
        #expect(await events.next() == AskpassEvent(host: host, viaToken: useToken, outcome: .refused(refusal)))
    }

    @Test("a host that does not use a password gets nothing, even with one saved")
    func notPasswordHost() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, vault) = try start(dir)
        defer { server.stop() }
        try vault.save("old", for: host)
        let result = await ask(server, host: host)
        #expect(result == .failure(AskpassFailure(AskpassRefusal.notPasswordHost.description)))
    }

    @Test("a test token answers for its host without a saved password")
    func token() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, vault) = try start(dir)
        defer { server.stop() }
        let token = try vault.beginTemporary("draft", for: host)
        var events = server.events.makeAsyncIterator()
        #expect(await ask(server, host: host, token: token) == .success("draft"))
        #expect(await events.next() == AskpassEvent(host: host, viaToken: true, outcome: .answered))
    }

    @Test("an untrusted peer is refused before the vault is asked")
    func untrustedPeer() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, vault) = try start(dir, validator: FakeAskpassValidator(rejection: "not the helper"))
        defer { server.stop() }
        vault.setPasswordHosts([host])
        try vault.save("s3cret", for: host)
        var events = server.events.makeAsyncIterator()
        guard case .failure(let failure) = await ask(server, host: host) else {
            Issue.record("an untrusted peer got the password")
            return
        }
        #expect(failure.message == "the askpass helper could not be verified: not the helper")
        #expect(await events.next() == AskpassEvent(host: host, viaToken: false, outcome: .refused(.untrustedPeer("not the helper"))))
    }

    @Test("a raw request for something other than the password is refused")
    func notPasswordPrompt() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let (server, vault) = try start(dir)
        defer { server.stop() }
        vault.setPasswordHosts([host])
        try vault.save("s3cret", for: host)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        #expect(connectUnixSocket(fd, server.socketURL.path(percentEncoded: false)) == 0)
        AskpassWire.configure(fd, timeoutSeconds: 10)
        let request = AskpassRequest(host: host, prompt: "Enter passphrase for key '/home/admin/.ssh/id_ed25519': ")
        #expect(AskpassWire.writeAll(fd, AskpassWire.line(request)))
        let reply = try #require(AskpassWire.readLine(fd).flatMap { AskpassWire.decode(AskpassReply.self, from: $0) })
        #expect(reply.password == nil)
        #expect(reply.refusal == AskpassRefusal.notPasswordPrompt.description)
    }

    @Test("the production validator rejects anything but the signed helper under ssh")
    func productionValidator() async throws {
        #expect(SignedAskpassPeerValidator(teamIdentifier: "ABC\" or 1").teamIdentifier == nil)
        #expect(SignedAskpassPeerValidator(teamIdentifier: "ABCDE12345").teamIdentifier == "ABCDE12345")

        for validator in [SignedAskpassPeerValidator(teamIdentifier: nil), SignedAskpassPeerValidator(teamIdentifier: "ABCDE12345")] {
            let dir = try TempDirectory()
            defer { dir.remove() }
            let (server, vault) = try start(dir, validator: validator)
            defer { server.stop() }
            vault.setPasswordHosts([host])
            try vault.save("s3cret", for: host)
            guard case .failure(let failure) = await ask(server, host: host) else {
                Issue.record("the test process got the password")
                continue
            }
            #expect(failure.message.hasPrefix("the askpass helper could not be verified: "), "\(failure.message)")
        }
    }
}
