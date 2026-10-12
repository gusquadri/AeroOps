import AeroCore
import Darwin
import Foundation
import Synchronization
import Testing
@testable import SSHKit

@Suite("SFTP wire format")
struct SFTPWireTests {
    @Test("frames packets split across and packed into chunks")
    func framer() throws {
        var first = SFTPWire.Writer(.status)
        first.u32(7)
        first.u32(SFTPStatusCode.ok.rawValue)
        first.string("fine")
        first.string("")
        var second = SFTPWire.Writer(.handle)
        second.u32(8)
        second.string(Data([1, 2, 3]))
        let stream = first.framed + second.framed

        var framer = SFTPWire.Framer()
        var bodies: [Data] = []
        for byte in stream {
            bodies += try framer.append(Data([byte]))
        }
        #expect(bodies == [first.body, second.body])

        var packed = SFTPWire.Framer()
        #expect(try packed.append(stream + stream.prefix(3)) == [first.body, second.body])
        #expect(try packed.append(stream.dropFirst(3)) == [first.body, second.body])
    }

    @Test("rejects absurd packet lengths")
    func lengthLimit() {
        var framer = SFTPWire.Framer()
        #expect(throws: SFTPError.self) { try framer.append(Data([0x7F, 0xFF, 0xFF, 0xFF, 1])) }
        var empty = SFTPWire.Framer()
        #expect(throws: SFTPError.self) { try empty.append(Data([0, 0, 0, 0])) }
    }

    @Test("parses replies")
    func replies() throws {
        var status = SFTPWire.Writer(.status)
        status.u32(1)
        status.u32(SFTPStatusCode.noSuchFile.rawValue)
        status.string("No such file")
        status.string("en")
        guard case .response(1, .status(.noSuchFile, let message)) = try SFTPWire.parse(status.body) else {
            Issue.record("not a status")
            return
        }
        #expect(message == "No such file")

        let attributes = SFTPAttributes(size: 1 << 40, uid: 501, gid: 20, permissions: 0o100644,
                                        accessTime: 10, modificationTime: 1_700_000_000)
        var name = SFTPWire.Writer(.name)
        name.u32(2)
        name.u32(2)
        for file in ["a.txt", "b"] {
            name.string(file)
            name.string("-rw-r--r-- 1 u g 0 Jan 1 00:00 \(file)")
            name.attributes(attributes)
        }
        guard case .response(2, .name(let entries)) = try SFTPWire.parse(name.body) else {
            Issue.record("not a name")
            return
        }
        #expect(entries.map(\.filename) == [Data("a.txt".utf8), Data("b".utf8)])
        #expect(entries.allSatisfy { $0.attributes == attributes })
        #expect(attributes.kind == .regular)
        #expect(attributes.mode == 0o644)

        var version = SFTPWire.Writer(.version)
        version.u32(3)
        version.string("posix-rename@openssh.com")
        version.string("1")
        guard case .version(3, let extensions) = try SFTPWire.parse(version.body) else {
            Issue.record("not a version")
            return
        }
        #expect(extensions.map(\.0) == ["posix-rename@openssh.com"])
    }

    @Test("rejects truncated and inflated packets")
    func malformed() {
        var name = SFTPWire.Writer(.name)
        name.u32(1)
        name.u32(1_000_000)
        #expect(throws: SFTPError.self) { try SFTPWire.parse(name.body) }

        var handle = SFTPWire.Writer(.handle)
        handle.u32(1)
        handle.u32(100) // string length with no bytes behind it
        #expect(throws: SFTPError.self) { try SFTPWire.parse(handle.body) }

        #expect(throws: SFTPError.self) { try SFTPWire.parse(Data([99, 0, 0, 0, 1])) }
    }

    @Test("paths keep raw bytes and split into components")
    func paths() {
        #expect(SFTPPath("/srv/www/").parent == SFTPPath("/srv"))
        #expect(SFTPPath("/srv").parent == .root)
        #expect(SFTPPath("/").parent == nil)
        #expect(SFTPPath("/srv/www/").name == "www")
        #expect(SFTPPath("/").name == "/")
        #expect(SFTPPath("/srv").appending(component: "a b") == SFTPPath("/srv/a b"))
        #expect(SFTPPath.root.appending(component: "etc") == SFTPPath("/etc"))

        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1, not valid UTF-8
        let path = SFTPPath("/data").appending(component: latin1)
        #expect(path.lastComponent == latin1)
        #expect(path.bytes == Data("/data/".utf8) + latin1)
        #expect(path.name == "caf\u{FFFD}")
    }

    @Test("refuses names that would escape a directory")
    func pathComponents() {
        for bad in ["", ".", "..", "a/b", "/", "../x", "a\u{0}b"] {
            #expect(!PathComponent.isSafe(bad), "\(bad)")
        }
        for good in ["a", ".hidden", "..x", "a b", "日本"] {
            #expect(PathComponent.isSafe(good), "\(good)")
        }
    }

    @Test("chunk sizes stay within the server's limits")
    func chunkSizes() {
        #expect(SFTPClient.chunkSize(limit: 0, packetLimit: 0) == SFTPClient.maxChunkSize)
        #expect(SFTPClient.chunkSize(limit: 261_120, packetLimit: 263_168) == 255 * 1024)
        #expect(SFTPClient.chunkSize(limit: 32_768, packetLimit: 34_000) == 32_768)
        #expect(SFTPClient.chunkSize(limit: 1_000_000, packetLimit: 34_000) == 34_000 - 1024)
    }
}

@Suite("Interactive child processes")
struct InteractiveChildTests {
    @Test("writes as it goes, keeps order through a full pipe, and closes on request")
    func interactiveStdin() async throws {
        let received = Mutex(Data())
        let spec = ChildSpec(
            executable: "/bin/cat",
            arguments: [],
            environment: [:],
            stdin: Data("head:".utf8),
            interactiveStdin: true,
            timeout: .seconds(30)
        )
        let (done, finished) = AsyncStream<ChildOutcome>.makeStream()
        let child = try ChildProcess.launch(spec, mode: .stream { data in received.withLock { $0.append(data) } }) { outcome in
            finished.yield(outcome)
            finished.finish()
        }
        // Several MiB at once fills the pipe, so the writer has to wait for `cat`.
        var expected = Data("head:".utf8)
        for index in 0..<40 {
            let piece = Data(repeating: UInt8(index), count: 100_000 + index)
            expected += piece
            child.write(piece)
        }
        child.closeStdin()
        child.write(Data("ignored after close".utf8))
        var iterator = done.makeAsyncIterator()
        let outcome = try #require(await iterator.next())
        #expect(outcome.termination == .exited(0))
        #expect(outcome.stdout.totalBytes == 0)
        #expect(received.withLock { $0 } == expected)
    }

    @Test("a non-interactive child still gets EOF right after its stdin")
    func batchStdinUnchanged() async throws {
        let spec = ChildSpec(executable: "/bin/cat", arguments: [], environment: [:], stdin: Data("x".utf8), timeout: .seconds(10))
        let outcome = try await ChildProcess.run(spec)
        #expect(String(decoding: outcome.stdout.data, as: UTF8.self) == "x")
    }
}

/// SFTP against the system's own `sftp-server`, started by a fake `ssh` script.
@Suite("SFTPClient")
struct SFTPClientTests {
    let scratch: ScratchDirectory
    /// The remote side's files (the server starts here).
    let remote: String
    /// The local side's files.
    let local: String
    let runner: SSHRunner

    init() throws {
        scratch = try ScratchDirectory()
        remote = scratch.path + "/remote"
        local = scratch.path + "/local"
        mkdir(remote, 0o755)
        mkdir(local, 0o755)
        let fake = try scratch.script("ssh", "exec /usr/libexec/sftp-server -d \(ShellQuote.quote(remote))")
        runner = SSHRunner(context: SSHContext(paths: scratch.paths(), sshExecutable: fake))
    }

    func connect() async throws -> SFTPClient {
        try await SFTPClient.connect(channel: try runner.openSubsystem("sftp", alias: "aero-test"))
    }

    /// The canonical path, as the server reports it (`/tmp` is `/private/tmp`).
    func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer).map { String(cString: $0) } ?? path
    }

    func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    @Test("asks ssh for the subsystem with -T -s after --")
    func argv() async throws {
        let echo = try scratch.script("echo-ssh", #"printf '%s\n' "$@""#)
        let paths = scratch.paths()
        let runner = SSHRunner(context: SSHContext(paths: paths, sshExecutable: echo))
        let channel = try runner.openSubsystem("sftp", alias: "aero-test")
        var output = Data()
        for await chunk in channel.incoming { output += chunk }
        #expect(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init) == [
            "-F", paths.sshConfig.filePath, "-o", "BatchMode=yes", "-T", "-s", "--", "aero-test", "sftp",
        ])
        #expect(await channel.waitForExit().exitCode == 0)
        #expect(throws: SSHError.self) { try runner.openSubsystem("-oProxyCommand=x", alias: "aero-test") }
        #expect(throws: SSHError.self) { try runner.openSubsystem("sftp", alias: "-oProxyCommand=x") }
    }

    @Test("handshake, home directory, extensions")
    func handshake() async throws {
        let sftp = try await connect()
        defer { sftp.disconnect() }
        #expect(try await sftp.homeDirectory().string == canonical(remote))
        #expect(await sftp.extensions["posix-rename@openssh.com"] != nil)
        #expect(await sftp.readChunkSize >= SFTPClient.defaultChunkSize)
        #expect(await sftp.isConnected)
    }

    @Test("lists, creates, renames and removes")
    func fileOperations() async throws {
        let sftp = try await connect()
        defer { sftp.disconnect() }
        let home = try await sftp.homeDirectory()
        try Data("hello".utf8).write(to: URL(filePath: remote + "/hello.txt"))
        symlink("hello.txt", remote + "/link")

        try await sftp.createDirectory(home.appending(component: "dir"), permissions: 0o750)
        let entries = try await sftp.list(home).sorted { $0.displayName < $1.displayName }
        #expect(entries.map(\.displayName) == ["dir", "hello.txt", "link"])
        #expect(entries.map(\.attributes.kind) == [.directory, .regular, .symlink])
        #expect(entries[1].attributes.size == 5)
        #expect(entries[0].attributes.mode == 0o750)
        #expect(entries[1].path == home.appending(component: "hello.txt"))
        #expect(try await sftp.readLink(home.appending(component: "link")) == SFTPPath("hello.txt"))
        #expect(try await sftp.attributes(of: home.appending(component: "link")).kind == .regular)

        try await sftp.rename(home.appending(component: "hello.txt"), to: home.appending(component: "dir/moved.txt"))
        #expect(FileManager.default.fileExists(atPath: remote + "/dir/moved.txt"))
        // posix-rename replaces an existing file.
        try Data("other".utf8).write(to: URL(filePath: remote + "/other.txt"))
        try await sftp.rename(home.appending(component: "other.txt"), to: home.appending(component: "dir/moved.txt"))
        #expect(scratch.read("remote/dir/moved.txt") == "other")

        try await sftp.setPermissions(home.appending(component: "dir/moved.txt"), 0o600)
        #expect(try await sftp.attributes(of: home.appending(component: "dir/moved.txt")).mode == 0o600)

        await #expect(throws: SFTPError.self) { try await sftp.removeDirectory(home.appending(component: "dir")) }
        do {
            _ = try await sftp.attributes(of: home.appending(component: "missing"))
            Issue.record("stat of a missing file succeeded")
        } catch let error as SFTPError {
            #expect(error.isNoSuchFile)
        }

        try await sftp.removeRecursively(home.appending(component: "dir"))
        try await sftp.removeRecursively(home.appending(component: "link"))
        #expect(!FileManager.default.fileExists(atPath: remote + "/dir"))
        #expect(try await sftp.list(home).isEmpty)
    }

    @Test("downloads and uploads big files intact, keeping permission bits")
    func singleFiles() async throws {
        let sftp = try await connect()
        defer { sftp.disconnect() }
        let home = try await sftp.homeDirectory()
        let payload = randomData(3 * 1024 * 1024 + 4321)
        try payload.write(to: URL(filePath: remote + "/big.bin"))
        chmod(remote + "/big.bin", 0o751)

        let downloaded = Mutex<Int64>(0)
        try await sftp.download(home.appending(component: "big.bin"), to: local + "/big.bin") { count in
            downloaded.withLock { $0 += count }
        }
        #expect(try Data(contentsOf: URL(filePath: local + "/big.bin")) == payload)
        #expect(downloaded.withLock { $0 } == Int64(payload.count))
        #expect(try LocalFileInfo(path: local + "/big.bin", followingSymlinks: false).mode == 0o751)
        #expect(try FileManager.default.contentsOfDirectory(atPath: local) == ["big.bin"])

        try Data().write(to: URL(filePath: remote + "/empty"))
        try await sftp.download(home.appending(component: "empty"), to: local + "/empty")
        #expect(try Data(contentsOf: URL(filePath: local + "/empty")).isEmpty)

        let upload = randomData(2 * 1024 * 1024 + 17)
        try upload.write(to: URL(filePath: local + "/up.bin"))
        chmod(local + "/up.bin", 0o640)
        let uploaded = Mutex<Int64>(0)
        try await sftp.upload(local + "/up.bin", to: home.appending(component: "up.bin")) { count in
            uploaded.withLock { $0 += count }
        }
        #expect(try Data(contentsOf: URL(filePath: remote + "/up.bin")) == upload)
        #expect(uploaded.withLock { $0 } == Int64(upload.count))
        #expect(try LocalFileInfo(path: remote + "/up.bin", followingSymlinks: false).mode == 0o640)

        // Replacing a longer file truncates it.
        try Data("short".utf8).write(to: URL(filePath: local + "/up.bin"))
        try await sftp.upload(local + "/up.bin", to: home.appending(component: "up.bin"))
        #expect(scratch.read("remote/up.bin") == "short")
    }

    @Test("a failed download leaves no partial file; a failed upload removes the file it created")
    func failures() async throws {
        let sftp = try await connect()
        defer { sftp.disconnect() }
        let home = try await sftp.homeDirectory()
        await #expect(throws: SFTPError.self) {
            try await sftp.download(home.appending(component: "missing"), to: local + "/missing")
        }
        try Data("x".utf8).write(to: URL(filePath: remote + "/file"))
        await #expect(throws: SFTPError.self) {
            try await sftp.download(home.appending(component: "file"), to: local + "/no-such-dir/file")
        }
        await #expect(throws: SFTPError.self) {
            try await sftp.upload(local + "/missing", to: home.appending(component: "missing"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: local).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: remote) == ["file"])
    }

    @Test("plans and copies folder trees both ways")
    func trees() async throws {
        let sftp = try await connect()
        defer { sftp.disconnect() }
        let home = try await sftp.homeDirectory()
        let tree = remote + "/tree"
        let fm = FileManager.default
        try fm.createDirectory(atPath: tree + "/a/b", withIntermediateDirectories: true)
        try Data("one".utf8).write(to: URL(filePath: tree + "/one.txt"))
        try Data("deep".utf8).write(to: URL(filePath: tree + "/a/b/deep.txt"))
        try Data().write(to: URL(filePath: tree + "/a/empty"))
        symlink("one.txt", tree + "/link-to-file")
        symlink("a", tree + "/link-to-dir")
        symlink("nowhere", tree + "/dangling")
        mkfifo(tree + "/fifo", 0o644)

        let plan = try await sftp.planDownload([home.appending(component: "tree")], into: local)
        #expect(Set(plan.directories.map(\.destination)) == [local + "/tree", local + "/tree/a", local + "/tree/a/b"])
        #expect(plan.directories.first?.destination == local + "/tree")
        #expect(Set(plan.files.map(\.destination)) == [
            local + "/tree/one.txt", local + "/tree/a/b/deep.txt", local + "/tree/a/empty", local + "/tree/link-to-file",
        ])
        #expect(plan.totalBytes == 10)
        #expect(Set(plan.skipped.map { LocalPath.lastComponent($0.path) }) == ["link-to-dir", "dangling", "fifo"])

        let events = Mutex<[SFTPTransferEvent]>([])
        let failures = try await sftp.download(plan) { event in events.withLock { $0.append(event) } }
        #expect(failures.isEmpty)
        #expect(scratch.read("local/tree/a/b/deep.txt") == "deep")
        #expect(scratch.read("local/tree/link-to-file") == "one")
        #expect(events.withLock { $0.filter { if case .file = $0 { true } else { false } }.count } == 4)

        // And back up under another name.
        try fm.moveItem(atPath: local + "/tree", toPath: local + "/copy")
        let upPlan = try await sftp.planUpload([local + "/copy"], into: home)
        #expect(upPlan.files.count == 4)
        #expect(try await sftp.upload(upPlan).isEmpty)
        #expect(scratch.read("remote/copy/a/b/deep.txt") == "deep")
        #expect(try fm.contentsOfDirectory(atPath: remote + "/copy").sorted() == ["a", "link-to-file", "one.txt"])

        // Uploading again merges into the existing folders.
        #expect(try await sftp.upload(upPlan).isEmpty)
    }

    @Test("a folder that cannot be created fails with its files; the rest carry on")
    func partialFailure() async throws {
        let sftp = try await connect()
        defer { sftp.disconnect() }
        let home = try await sftp.homeDirectory()
        try FileManager.default.createDirectory(atPath: remote + "/src/sub", withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(filePath: remote + "/src/a.txt"))
        try Data("b".utf8).write(to: URL(filePath: remote + "/src/sub/b.txt"))
        let plan = try await sftp.planDownload([home.appending(component: "src")], into: local)
        // A file where the folder should go.
        try FileManager.default.createDirectory(atPath: local + "/src", withIntermediateDirectories: true)
        try Data().write(to: URL(filePath: local + "/src/sub"))
        let failures = try await sftp.download(plan)
        #expect(failures.map(\.path) == [local + "/src/sub"])
        #expect(scratch.read("local/src/a.txt") == "a")
    }

    @Test("a dead session fails requests with disconnected")
    func disconnects() async throws {
        let sftp = try await connect()
        sftp.disconnect()
        let gone = await eventually { await !sftp.isConnected }
        #expect(gone)
        await #expect(throws: SFTPError.self) { try await sftp.homeDirectory() }
    }

    @Test("an ssh failure surfaces as the classified SSHError")
    func connectFailure() async throws {
        let fake = try scratch.script("ssh-denied", "echo 'dev@localhost: Permission denied (publickey).' >&2; exit 255")
        let runner = SSHRunner(context: SSHContext(paths: scratch.paths(), sshExecutable: fake))
        do {
            _ = try await SFTPClient.connect(channel: try runner.openSubsystem("sftp", alias: "aero-test"))
            Issue.record("connected")
        } catch let error as SFTPError {
            #expect(error == .disconnected(.authFailed))
        }
    }

    @Test("a server that never answers times out")
    func handshakeTimeout() async throws {
        let fake = try scratch.script("ssh-silent", "exec sleep 30")
        let runner = SSHRunner(context: SSHContext(paths: scratch.paths(), sshExecutable: fake))
        do {
            _ = try await SFTPClient.connect(channel: try runner.openSubsystem("sftp", alias: "aero-test"), timeout: .milliseconds(300))
            Issue.record("connected")
        } catch let error as SFTPError {
            #expect(error == .disconnected(.timeout))
        }
    }
}
