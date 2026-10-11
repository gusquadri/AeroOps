import Foundation
import Testing
@testable import TerminalKit

@Suite("TerminalCommandLine")
struct TerminalCommandLineTests {
    private let spec = TerminalLaunchSpec(
        executable: "/usr/bin/ssh",
        arguments: ["-F", "/Users/me/.aeroops/ssh_config", "aero-1"],
        title: "web-01"
    )

    @Test("wraps the program in env + sh -c with the nonce title reports")
    func wrapsCommand() {
        let line = TerminalCommandLine(spec: spec, nonce: "abc123")
        #expect(line.command.hasPrefix("/usr/bin/env /bin/sh -c '"))
        #expect(line.command.contains("aeroops-start-abc123"))
        #expect(line.command.contains("aeroops-exit-abc123"))
        #expect(line.command.contains(#"\033[3J"#))
        #expect(!line.command.contains("\n"))
    }

    @Test("the script sh receives runs exactly the spec's argv")
    func scriptRoundTrip() throws {
        let tricky = TerminalLaunchSpec(
            executable: "/bin/echo",
            arguments: ["it's", "$HOME", "a b", "\"q\"", "`id`", ";", "\\"],
            title: "t"
        )
        let line = TerminalCommandLine(spec: tricky, nonce: "n0")
        // Run the generated command with a real POSIX sh, as libghostty's bash wrapper would.
        let output = try Self.run("/bin/sh", ["-c", line.command])
        #expect(output.status == 0)
        #expect(output.stdout.contains("it's $HOME a b \"q\" `id` ; \\\n"))
        #expect(output.stdout.contains("\u{1B}]2;aeroops-start-n0-"))
        #expect(output.stdout.hasSuffix("\u{1B}]2;aeroops-exit-n0-0\u{07}"))
    }

    @Test("the exit report carries the program's status")
    func exitStatus() throws {
        let failing = TerminalLaunchSpec(executable: "/bin/sh", arguments: ["-c", "exit 42"], title: "t")
        let line = TerminalCommandLine(spec: failing, nonce: "n1")
        let output = try Self.run("/bin/sh", ["-c", line.command])
        #expect(output.status == 42)
        #expect(output.stdout.hasSuffix("aeroops-exit-n1-42\u{07}"))
    }

    @Test("decodes only this session's reports")
    func decode() {
        let line = TerminalCommandLine(spec: spec, nonce: "feed")
        #expect(line.decode(title: "aeroops-start-feed-4242") == .started(pid: 4242))
        #expect(line.decode(title: "aeroops-exit-feed-255") == .exited(code: 255))
        #expect(line.decode(title: "aeroops-exit-feed-0") == .exited(code: 0))
        #expect(line.decode(title: "aeroops-exit-beef-0") == nil)
        #expect(line.decode(title: "aeroops-exit-feed-x") == nil)
        #expect(line.decode(title: "aeroops-exit-feed-") == nil)
        #expect(line.decode(title: "aeroops-exit-feed-256") == nil)
        #expect(line.decode(title: "aeroops-exit-feed--1") == nil)
        #expect(line.decode(title: "aeroops-exit-feed-\u{0661}") == nil)
        #expect(line.decode(title: "aeroops-start-feed-1") == nil)
        #expect(line.decode(title: "vim: main.swift") == nil)
        #expect(line.isReport("aeroops-exit-feed-x"))
        #expect(!line.isReport("aeroops-exit-beef-0"))
        #expect(!line.isReport("vim: main.swift"))
    }

    @Test("nonces are 32 hex characters and unique")
    func nonces() {
        let a = TerminalCommandLine.makeNonce()
        let b = TerminalCommandLine.makeNonce()
        #expect(a.count == 32)
        #expect(a.allSatisfy { $0.isHexDigit })
        #expect(a != b)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

@Suite("TerminalLaunchSpec validation")
struct TerminalLaunchSpecTests {
    @Test("accepts an ssh spec")
    func valid() throws {
        let spec = TerminalLaunchSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-F", "/tmp/c", "aero-1"],
            environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock"],
            title: "x"
        )
        try spec.validate()
    }

    @Test("rejects relative executables, control characters and bad env names")
    func invalid() {
        #expect(throws: TerminalLaunchError.relativeExecutable("ssh")) {
            try TerminalLaunchSpec(executable: "ssh", title: "x").validate()
        }
        #expect(throws: TerminalLaunchError.controlCharacter(field: "argument 0")) {
            try TerminalLaunchSpec(executable: "/bin/echo", arguments: ["a\nb"], title: "x").validate()
        }
        #expect(throws: TerminalLaunchError.invalidEnvironmentName("1X")) {
            try TerminalLaunchSpec(executable: "/bin/echo", environment: ["1X": "y"], title: "x").validate()
        }
        #expect(throws: TerminalLaunchError.controlCharacter(field: "environment A")) {
            try TerminalLaunchSpec(executable: "/bin/echo", environment: ["A": "x\u{0}"], title: "x").validate()
        }
    }
}
