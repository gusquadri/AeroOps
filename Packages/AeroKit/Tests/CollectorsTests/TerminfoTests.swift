import AeroCore
import AeroTestSupport
import Foundation
import SSHKit
import Testing
@testable import Collectors

@Suite("Terminfo scripts")
struct TerminfoScriptTests {
    @Test("Embedded scripts are byte-identical to Scripts/remote/terminfo-*.sh")
    func byteIdentity() throws {
        let root = try Fixtures.repoRoot()
        for (name, embedded) in [("check", RemoteScripts.terminfoCheck), ("install", RemoteScripts.terminfoInstall)] {
            let onDisk = try Data(contentsOf: root.appending(path: "Scripts/remote/terminfo-\(name).sh"))
            #expect(Data(embedded.utf8) == onDisk, "Re-embed Scripts/remote/terminfo-\(name).sh in RemoteScripts+Terminfo.swift")
        }
    }

    @Test("Embedded scripts pass sh -n")
    func syntax() throws {
        for script in [RemoteScripts.terminfoCheck, RemoteScripts.terminfoInstall] {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-n", "-c", script]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }

    @Test("The install script carries Ghostty's entry and writes only to ~/.terminfo")
    func installContents() {
        let script = RemoteScripts.terminfoInstall
        #expect(script.contains("\nxterm-ghostty|ghostty|Ghostty,\n"))
        #expect(script.contains("tic -x -o \"$HOME/.terminfo\" \"$src\""))
        #expect(!script.contains("Reconstructed via infocmp"))
        let commands = script.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(!commands.contains { $0.contains("sudo") })
    }

    @Test("Check output parses into the two answers")
    func parse() {
        #expect(TerminfoSupport(checkOutput: "") == TerminfoSupport(hasGhosttyEntry: false, canInstall: false))
        #expect(TerminfoSupport(checkOutput: "tic\n") == TerminfoSupport(hasGhosttyEntry: false, canInstall: true))
        #expect(TerminfoSupport(checkOutput: "motd\r\nxterm-ghostty\r\ntic\r\n") == TerminfoSupport(hasGhosttyEntry: true, canInstall: true))
        #expect(TerminfoSupport(checkOutput: "xterm-ghostty-x\nTIC\n") == TerminfoSupport(hasGhosttyEntry: false, canInstall: false))
    }
}

@Suite("Terminfo commands")
struct TerminfoCommandsTests {
    @Test("check sends terminfo-check.sh on stdin with a short timeout")
    func check() async throws {
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok("xterm-ghostty\ntic\n"))
        let host = ProbeTestData.host()
        let support = try await TerminfoCommands(runner: runner).check(host)
        #expect(support == TerminfoSupport(hasGhosttyEntry: true, canInstall: true))
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.command == RemoteScripts.shellCommand)
        #expect(runner.calls.first?.stdin == Data(RemoteScripts.terminfoCheck.utf8))
        #expect(runner.calls.first?.timeout == .seconds(4))
        #expect(runner.calls.first?.hostID == host.id)
    }

    @Test("install runs the install script, then checks again")
    func install() async throws {
        let runner = ProbeScriptedRunner(run: { _ in ProbeTestData.ok("installed\nxterm-ghostty\ntic\n") })
        let support = try await TerminfoCommands(runner: runner).install(ProbeTestData.host())
        #expect(support.hasGhosttyEntry)
        #expect(runner.calls.map(\.stdin) == [Data(RemoteScripts.terminfoInstall.utf8), Data(RemoteScripts.terminfoCheck.utf8)])
    }

    @Test("A host without tic fails the install with the script's message")
    func installWithoutTic() async throws {
        let runner = ProbeScriptedRunner(result: ProbeTestData.failure(exitCode: 3, stderr: "tic is not installed\n"))
        await #expect(throws: SSHError.remoteCommandFailed(exitCode: 3, stderr: "tic is not installed")) {
            try await TerminfoCommands(runner: runner).install(ProbeTestData.host())
        }
        #expect(runner.calls.count == 1)
    }
}
