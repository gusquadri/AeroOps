import AeroCore
import Darwin
import Foundation
import KeyAgent
import Testing
@testable import EmbeddedSSH
@testable import SSHKit

/// Long-lived sessions (subsystems, terminals, SFTP) against ``TestSSHServer``.
@Suite("EmbeddedSSH sessions")
struct EmbeddedSSHSessionTests {
    private struct Fixture {
        let env: TestEnvironment
        let server: TestSSHServer
        let host: RemoteHost
        let client: EmbeddedSSHClient

        init(sftpRoot: String? = nil) async throws {
            env = try TestEnvironment()
            server = try await TestSSHServer(sftpRoot: sftpRoot)
            host = try await server.host(in: env)
            client = env.client()
        }

        func tearDown() async {
            await client.disconnectAll()
            await server.close()
        }
    }

    private func collect(_ channel: EmbeddedSSHChannel) async -> String {
        var output = Data()
        for await chunk in channel.incoming { output += chunk }
        return String(decoding: output, as: UTF8.self)
    }

    @Test("A subsystem carries bytes both ways and ends when its input closes")
    func subsystem() async throws {
        let fixture = try await Fixture()
        let channel = try await fixture.client.openSubsystem("echo", on: fixture.host)
        channel.send(Data("hello ".utf8))
        channel.send(Data())
        channel.send(Data("world".utf8))
        channel.closeInput()
        #expect(await collect(channel) == "hello world")
        #expect(await channel.waitForEnd() == nil)
        #expect(channel.exitStatus == 0)
        await fixture.tearDown()
    }

    @Test("Going to the background keeps a session's connection; one that stops answering fails the probe and ends")
    func backgroundAndProbe() async throws {
        let fixture = try await Fixture()
        let channel = try await fixture.client.openSubsystem("echo", on: fixture.host)
        await fixture.client.closeIdleConnections()
        #expect(await channel.isResponsive(within: .seconds(5)))
        channel.send(Data("still here".utf8))
        channel.closeInput()
        #expect(await collect(channel) == "still here")

        let stuck = try await fixture.client.openSubsystem("echo", on: fixture.host)
        await fixture.server.stopAnswering()
        let started = ContinuousClock.now
        #expect(await stuck.isResponsive(within: .milliseconds(300)) == false)
        #expect(.now - started < .seconds(3))
        #expect(await stuck.waitForEnd() == .connectionClosed)
        await fixture.tearDown()
    }

    @Test("A missing subsystem is refused; a server that never answers times out; bad names never connect")
    func refusals() async throws {
        let fixture = try await Fixture()
        let (client, host) = (fixture.client, fixture.host)
        await #expect(throws: SSHError.other("The server has no “nope” subsystem.")) {
            try await client.openSubsystem("nope", on: host)
        }
        let started = ContinuousClock.now
        await #expect(throws: SSHError.timeout) {
            try await client.openSubsystem("silent", on: host, timeout: .milliseconds(300))
        }
        #expect(.now - started < .seconds(3))

        for name in ["", "-oProxyCommand=x", "sftp server"] {
            await #expect(throws: SSHError.self) { try await client.openSubsystem(name, on: host) }
        }
        for term in ["", "-x", "xterm 256", String(repeating: "x", count: 65)] {
            await #expect(throws: SSHError.self) {
                try await client.openTerminal(on: host, term: term, size: PseudoTerminalSize(columns: 80, rows: 24))
            }
        }
        await #expect(throws: SSHError.self) {
            try await client.openTerminal(on: host, term: "xterm", size: PseudoTerminalSize(columns: 80, rows: 24), command: "")
        }
        // A command still runs after all that.
        #expect(try await client.run("true", on: host).stdoutString == "ran true\r\n")
        await fixture.tearDown()
    }

    @Test("A terminal gets its pty and modes, resizes, and reports the shell's exit status")
    func terminal() async throws {
        let fixture = try await Fixture()
        let channel = try await fixture.client.openTerminal(
            on: fixture.host, term: "xterm-256color", size: PseudoTerminalSize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 480)
        )
        let terminal = try #require(fixture.server.log.terminals.first)
        #expect(terminal.term == "xterm-256color")
        #expect(terminal.size == PseudoTerminalSize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 480))
        #expect(terminal.modes[3] == 127, "VERASE is DEL")
        #expect(terminal.modes[42] == 1, "IUTF8")

        channel.resize(PseudoTerminalSize(columns: 120, rows: 40))
        channel.resize(PseudoTerminalSize(columns: -5, rows: 1_000_000))
        channel.send(Data("ls\r".utf8))
        channel.send(Data("exit\r".utf8))
        #expect(await collect(channel) == "$ ls\rexit\r")
        #expect(await channel.waitForEnd() == nil)
        #expect(channel.exitStatus == 7)
        #expect(fixture.server.log.windowChanges == [
            PseudoTerminalSize(columns: 120, rows: 40),
            PseudoTerminalSize(columns: 0, rows: Int(UInt16.max)),
        ])
        await fixture.tearDown()
    }

    @Test("A terminal can run a command instead of the shell, and shows its stderr too")
    func terminalCommand() async throws {
        let fixture = try await Fixture()
        let channel = try await fixture.client.openTerminal(
            on: fixture.host, term: "xterm-ghostty", size: PseudoTerminalSize(columns: 80, rows: 24), command: "docker logs -f web"
        )
        #expect(await collect(channel) == "ran docker logs -f web\r\noops\r\n")
        #expect(channel.exitStatus == 0)
        #expect(fixture.server.log.commands == ["docker logs -f web"])
        await fixture.tearDown()
    }

    @Test("Disconnecting the host ends its sessions; dropping the stream closes one")
    func endings() async throws {
        let fixture = try await Fixture()
        let (client, host) = (fixture.client, fixture.host)
        let channel = try await client.openSubsystem("echo", on: host)
        // Commands share the connection with a session.
        #expect(try await client.run("true", on: host).exitCode == 0)
        await client.disconnect(host.id)
        #expect(await collect(channel) == "")
        #expect(await channel.waitForEnd() == .connectionClosed)
        #expect(channel.exitStatus == nil)

        let closed = try await client.openSubsystem("echo", on: host)
        closed.close()
        #expect(await closed.waitForEnd() == .connectionClosed)
        channel.send(Data("ignored".utf8))
        await fixture.tearDown()
    }

    @Test("Cancelling an open throws CancellationError")
    func cancellation() async throws {
        let fixture = try await Fixture()
        let (client, host) = (fixture.client, fixture.host)
        let opening = Task { try await client.openSubsystem("silent", on: host) }
        try await Task.sleep(for: .milliseconds(200))
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        await fixture.tearDown()
    }

    @Test("SFTPClient runs over an EmbeddedSSH channel: listing, transfers larger than the SSH window")
    func sftp() async throws {
        let scratch = try ScratchDirectory()
        let remote = scratch.file("remote").filePath
        let local = scratch.file("local").filePath
        mkdir(remote, 0o755)
        mkdir(local, 0o755)
        var root = [CChar](repeating: 0, count: Int(PATH_MAX))
        let canonicalRemote = String(cString: realpath(remote, &root))
        let fixture = try await Fixture(sftpRoot: remote)

        let sftp = try await SFTPClient.connect(using: fixture.client, to: fixture.host)
        let home = try await sftp.homeDirectory()
        #expect(home.string == canonicalRemote)
        try await sftp.createDirectory(home.appending(component: "folder"))
        #expect(try await sftp.list(home).map(\.displayName) == ["folder"])

        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<(5 << 20)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: URL(filePath: local + "/up.bin"))
        try await sftp.upload(local + "/up.bin", to: home.appending(component: "up.bin"))
        #expect(try Data(contentsOf: URL(filePath: remote + "/up.bin")) == payload)
        try await sftp.download(home.appending(component: "up.bin"), to: local + "/down.bin")
        #expect(try Data(contentsOf: URL(filePath: local + "/down.bin")) == payload)

        sftp.disconnect()
        await #expect(throws: SFTPError.self) { try await sftp.list(home) }
        await fixture.tearDown()
    }

    @Test("SFTP over EmbeddedSSH: a blocked host throws SSHError; a failed start is SFTPError.disconnected")
    func sftpErrors() async throws {
        let fixture = try await Fixture()
        let (client, host) = (fixture.client, fixture.host)
        // The server has no sftp subsystem without a root.
        await #expect(throws: SFTPError.disconnected(.other("The server has no “sftp” subsystem."))) {
            try await SFTPClient.connect(using: client, to: host)
        }
        // On a new connection, an unknown host key and then a changed one, which blocks the host.
        await client.disconnect(host.id)
        try await fixture.env.hostKeys.forget(host)
        await #expect(throws: SFTPError.disconnected(.hostKeyUnknown)) {
            try await SFTPClient.connect(using: client, to: host)
        }
        try await fixture.env.hostKeys.trust(TestKeys.ed25519(), for: host)
        await #expect(throws: SFTPError.disconnected(.hostKeyChanged)) {
            try await SFTPClient.connect(using: client, to: host)
        }
        await #expect(throws: SSHError.hostKeyChanged) {
            try await SFTPClient.connect(using: client, to: host)
        }
        await fixture.tearDown()
    }
}
