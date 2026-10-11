import Darwin
import Foundation

/// Local processes for tests that run the `run_command` wrapper or other tools on this Mac.
enum LocalProcess {
    /// A `/bin/sh -c <command>` started in its own session (like sshd starts every session), so
    /// the wrapper's `kill 0` can only reach that session, never the test runner.
    struct Session: Sendable {
        let pid: pid_t
        /// Read end of the child's stdout.
        let stdout: Int32
    }

    static func startSession(_ command: String) throws -> Session {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fds[1]) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ)
        guard status == 0 else {
            close(fds[0])
            throw POSIXError(.init(rawValue: status) ?? .EIO)
        }
        return Session(pid: pid, stdout: fds[0])
    }

    /// Runs `body` on its own thread, so blocking reads and waits never hold a Swift
    /// concurrency thread.
    static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: body()) }.start()
        }
    }

    /// Reads up to and including the first newline (or EOF).
    static func readLine(_ fd: Int32) async -> String {
        await onThread {
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while read(fd, &byte, 1) == 1 {
                if byte == 0x0A { break }
                bytes.append(byte)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Reads until EOF.
    static func readToEnd(_ fd: Int32) async -> Data {
        await onThread {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
            return data
        }
    }

    /// Waits for `pid` and returns its exit status, or `128 + signal`.
    static func wait(_ pid: pid_t) async -> Int32 {
        await onThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let signal = status & 0x7F
            return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
        }
    }

    /// `true` once no process `pid` exists (not even a zombie), polling up to `timeout`.
    static func isGone(_ pid: pid_t, within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    struct ToolResult: Sendable {
        var status: Int32
        var stdout: String
    }

    /// Runs a tool to completion; stdin is `/dev/null`, stderr is merged into stdout.
    static func run(_ executable: String, _ arguments: [String]) async throws -> ToolResult {
        try await onThread { () -> Result<ToolResult, any Error> in
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .failure(error)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .success(ToolResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self)))
        }.get()
    }
}
