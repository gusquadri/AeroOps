import AeroCore
import Darwin
import Foundation
import Testing
@testable import SSHKit

/// ControlMaster against a fake ssh that answers `-O check` / `-O exit` like OpenSSH 10.3.
@Suite("ControlMaster")
struct ControlMasterTests {
    let scratch: ScratchDirectory

    init() throws {
        scratch = try ScratchDirectory()
    }

    private func master(answering body: String) throws -> ControlMaster {
        let log = ShellQuote.quote(scratch.file("ssh.log").filePath)
        let ssh = try scratch.script("ssh", "printf '%s\\n' \"$*\" >> \(log)\n" + body)
        return ControlMaster(context: SSHContext(paths: scratch.paths(), sshExecutable: ssh))
    }

    @Test("check and exit with a running master")
    func running() async throws {
        let control = try master(answering: """
        case "$*" in
          *"-O check"*) printf 'Master running (pid=62706)\\r\\n' >&2; exit 0 ;;
          *"-O exit"*) printf 'Exit request sent.\\r\\n' >&2; exit 0 ;;
        esac
        exit 1
        """)
        let host = RemoteHost.test()
        #expect(try await control.check(host) == .running(pid: 62706))
        #expect(try await control.exit(host))
        let config = scratch.paths().sshConfig.filePath
        #expect(scratch.read("ssh.log") == """
        -F \(config) -o BatchMode=yes -O check -- \(host.sshAlias)
        -F \(config) -o BatchMode=yes -O exit -- \(host.sshAlias)

        """)
    }

    @Test("no master: missing or stale socket")
    func notRunning() async throws {
        let control = try master(answering: """
        printf 'Control socket connect(/tmp/x/cm/abc): No such file or directory\\r\\n' >&2
        exit 255
        """)
        #expect(try await control.check(.test()) == .notRunning)
        #expect(try await !control.exit(.test()))

        let stale = try master(answering: """
        printf 'Control socket connect(/tmp/x/cm/abc): Connection refused\\r\\n' >&2
        exit 255
        """)
        #expect(try await stale.check(.test()) == .notRunning)
    }

    @Test("other failures throw")
    func failures() async throws {
        let control = try master(answering: "printf 'garbage\\n' >&2; exit 255")
        await #expect(throws: SSHError.other("garbage")) { try await control.check(.test()) }
    }

    @Test("closeAll asks every socket in cm/ to exit and removes stale ones")
    func closeAll() async throws {
        let paths = scratch.paths()
        try SSHConfigWriter(context: SSHContext(paths: paths)).prepareDirectories()
        let live = paths.controlMasterDirectory.appending(path: "live")
        let stale = paths.controlMasterDirectory.appending(path: "stale")
        let fdLive = try bindSocket(live)
        let fdStale = try bindSocket(stale)
        defer {
            close(fdLive)
            close(fdStale)
        }
        try scratch.write("not-a-socket", "x")
        try FileManager.default.copyItem(at: scratch.file("not-a-socket"), to: paths.controlMasterDirectory.appending(path: "file"))

        let control = try master(answering: """
        case "$*" in
          *ControlPath=*stale*) printf 'Control socket connect(stale): Connection refused\\r\\n' >&2; exit 255 ;;
          *"-O exit"*) printf 'Exit request sent.\\r\\n' >&2; exit 0 ;;
        esac
        exit 1
        """)
        #expect(await control.closeAll() == 1)
        #expect(FileManager.default.fileExists(atPath: live.filePath))
        #expect(!FileManager.default.fileExists(atPath: stale.filePath))
        let log = try #require(scratch.read("ssh.log"))
        #expect(log.contains("-F /dev/null -o ControlPath=\(live.filePath) -o BatchMode=yes -O exit -- aero-shutdown"))
        #expect(!log.contains("/file "))
    }

    @Test("parses the master pid")
    func pid() {
        #expect(ControlMaster.masterPID(in: "Master running (pid=4242)\r\n") == 4242)
        #expect(ControlMaster.masterPID(in: "Master running\r\n") == nil)
    }

    private func bindSocket(_ url: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.filePath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.map { UInt8(bitPattern: $0) }.prefix(raw.count - 1))
        }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return fd
    }
}
