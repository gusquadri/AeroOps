import AeroCore
import BridgeProtocol
import Foundation
import SSHKit
import Testing
@testable import AgentBridge

@Suite("File tools over SFTP")
struct FileToolsTests {
    final class Fixture: Sendable {
        let dir: TempDirectory
        let handler = FakeToolHandler()
        let runner = FakeRunner(.outcome(RemoteCommandOutcome(exitCode: 0, stdout: Data(), duration: .zero)))
        let bridge: Bridge
        let remote: String
        let local: String

        init() throws {
            dir = try TempDirectory()
            remote = dir.path + "remote"
            local = dir.path + "local"
            try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: false)
            let ssh = dir.appending("ssh")
            try Data("#!/bin/sh\nexec /usr/libexec/sftp-server -d \(ShellQuote.quote(remote))\n".utf8).write(to: ssh)
            chmod(ssh.path(percentEncoded: false), 0o755)
            let context = SSHContext(paths: AeroPaths(dotDirectory: dir.appending("dot")), sshExecutable: ssh)
            bridge = Bridge(socketURL: dir.appending("bridge.sock"), handler: handler,
                            executor: CommandExecutor(runner: runner), peerValidator: AcceptAllPeers(),
                            files: .ssh(SSHRunner(context: context)))
        }

        deinit { dir.remove() }

        func call(_ tool: String, _ arguments: [String: JSONValue]) async throws -> BridgeReply {
            let request = BridgeRequest(id: 1, tool: tool, arguments: arguments,
                                        client: BridgeClientInfo(name: "claude-code", version: "2.1.296"), toolUseId: nil)
            return try #require(await bridge.process(request, peer: testPeer) { _ in })
        }

        func names(_ path: String = ".") async throws -> [String] {
            let reply = try await call("list_files", ["host": "staging", "path": .string(path)])
            return reply.structuredContent?["entries"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        }
    }

    @Test func uploadListAndDownloadRoundTrip() async throws {
        let fixture = try Fixture()
        let source = fixture.local + "/report.txt"
        try Data("disk 91%\n".utf8).write(to: URL(filePath: source))
        #expect(try await fixture.names().isEmpty)

        let upload = try await fixture.call("upload_file", ["host": "staging", "localPath": .string(source), "remotePath": "report.txt"])
        #expect(upload.ok)
        #expect(upload.structuredContent?["bytes"]?.intValue == 9)
        #expect(try await fixture.names() == ["report.txt"])

        let target = fixture.local + "/copy.txt"
        let download = try await fixture.call("download_file", ["host": "staging", "remotePath": "report.txt", "localPath": .string(target)])
        #expect(download.ok)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "disk 91%\n")
    }

    @Test func existingFilesNeedOverwrite() async throws {
        let fixture = try Fixture()
        let source = fixture.local + "/a.txt"
        try Data("new".utf8).write(to: URL(filePath: source))
        try Data("old".utf8).write(to: URL(filePath: fixture.remote + "/a.txt"))
        let upload: [String: JSONValue] = ["host": "staging", "localPath": .string(source), "remotePath": "a.txt"]

        #expect(try await fixture.call("upload_file", upload).error?.code == .fileExists)
        #expect(try String(contentsOfFile: fixture.remote + "/a.txt", encoding: .utf8) == "old")
        #expect(try await fixture.call("upload_file", upload.merging(["overwrite": true]) { $1 }).ok)
        #expect(try String(contentsOfFile: fixture.remote + "/a.txt", encoding: .utf8) == "new")

        let download: [String: JSONValue] = ["host": "staging", "remotePath": "a.txt", "localPath": .string(source)]
        #expect(try await fixture.call("download_file", download).error?.code == .fileExists)
    }

    @Test func refusesDirectoriesAndRelativeLocalPaths() async throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(atPath: fixture.remote + "/logs", withIntermediateDirectories: false)
        let directory = try await fixture.call("download_file", ["host": "staging", "remotePath": "logs", "localPath": .string(fixture.local + "/x")])
        #expect(directory.error?.code == .sftpFailed)
        let relative = try await fixture.call("upload_file", ["host": "staging", "localPath": "a.txt", "remotePath": "a.txt"])
        #expect(relative.error?.code == .invalidArguments)
        #expect(try await fixture.names("logs").isEmpty)
    }

    @Test func fileToolsNeedTheExecTier() async throws {
        let fixture = try Fixture()
        let prod = try await fixture.call("list_files", ["host": "prod"])
        #expect(prod.error?.code == .execNotAllowed)
        #expect(prod.error?.message.contains("list_files needs the Read + Exec tier") == true)
        let vault = try await fixture.call("download_file", ["host": "vault", "remotePath": "a", "localPath": .string(fixture.local + "/a")])
        #expect(vault.error?.code == .hostNotShared)
        #expect(!FileManager.default.fileExists(atPath: fixture.local + "/a"))
    }
}
