import AeroCore
import Darwin
import Foundation

/// Whether a ControlMaster connection is up.
public enum ControlMasterStatus: Sendable, Hashable {
    /// `Master running (pid=N)`.
    case running(pid: Int32?)
    case notRunning
}

/// Controls the shared connections ssh keeps in `~/.aeroops/cm/` (`ControlMaster auto`,
/// `ControlPersist 10m`). The first command to a host starts a master that ssh daemonizes;
/// later commands and terminal tabs multiplex over it without re-authenticating.
public struct ControlMaster: Sendable {
    public let context: SSHContext
    /// Deadline for each `ssh -O` call.
    public var timeout: Duration = .seconds(5)

    public init(context: SSHContext = .standard) {
        self.context = context
    }

    /// `ssh -O check`: is a master running for `host`?
    public func check(_ host: RemoteHost) async throws -> ControlMasterStatus {
        try await check(alias: host.sshAlias)
    }

    /// `ssh -O exit`: asks the master for `host` to close. Returns `false` if none was running.
    @discardableResult
    public func exit(_ host: RemoteHost) async throws -> Bool {
        try await exit(alias: host.sshAlias)
    }

    func check(alias: String) async throws -> ControlMasterStatus {
        let result = try await control("check", arguments: ["-F", context.configFile.filePath], alias: alias)
        if result.exitCode == 0 { return .running(pid: Self.masterPID(in: result.stderrString)) }
        if Self.isNoMaster(result) { return .notRunning }
        throw result.transportError ?? .other(SSHError.trimmed(result.stderrString))
    }

    func exit(alias: String) async throws -> Bool {
        let result = try await control("exit", arguments: ["-F", context.configFile.filePath], alias: alias)
        if result.exitCode == 0 { return true }
        if Self.isNoMaster(result) { return false }
        throw result.transportError ?? .other(SSHError.trimmed(result.stderrString))
    }

    /// Asks every master socket in `cm/` to exit (call on app quit) and removes stale sockets.
    /// Works from the socket files alone, so it also closes masters of hosts deleted since.
    /// Returns how many masters acknowledged.
    @discardableResult
    public func closeAll() async -> Int {
        let sockets = Self.sockets(in: context.controlMasterDirectory)
        return await withTaskGroup(of: Bool.self) { group in
            for socket in sockets {
                group.addTask { await closeSocket(socket) }
            }
            var closed = 0
            for await acknowledged in group where acknowledged { closed += 1 }
            return closed
        }
    }

    /// `ssh -F /dev/null -o ControlPath=<socket> -O exit -- aero-shutdown`: the alias is only a
    /// placeholder; with an explicit ControlPath ssh talks to the socket without resolving it.
    private func closeSocket(_ socket: URL) async -> Bool {
        guard let path = try? ConfigValue.path(socket) else { return false }
        guard let result = try? await control(
            "exit", arguments: ["-F", "/dev/null", "-o", "ControlPath=\(path)"], alias: "aero-shutdown"
        ) else { return false }
        if result.exitCode == 0 { return true }
        let masterIsGone = result.stderrString.contains("Connection refused")
        if masterIsGone { removeStaleSocket(socket) }
        return false
    }

    private func removeStaleSocket(_ socket: URL) {
        unlink(socket.filePath)
    }

    private func control(_ operation: String, arguments: [String], alias: String) async throws -> SSHResult {
        guard SSHRunner.isValidAlias(alias) else { throw SSHError.invalidRequest("invalid host alias “\(alias)”") }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(context.environmentOverrides) { _, override in override }
        let spec = ChildSpec(
            executable: context.sshExecutable.filePath,
            arguments: arguments + ["-o", "BatchMode=yes", "-O", operation, "--", alias],
            environment: environment,
            timeout: timeout,
            outputLimit: 16 * 1024
        )
        do {
            return SSHResult(try await ChildProcess.run(spec))
        } catch let error as ChildLaunchError {
            throw SSHError.launchFailed(error.message)
        }
    }

    /// `Control socket connect(<path>): No such file or directory` (no master) or
    /// `... Connection refused` (stale socket).
    static func isNoMaster(_ result: SSHResult) -> Bool {
        guard result.exitCode == 255, !result.timedOut else { return false }
        let text = result.stderrString
        return text.contains("Control socket connect")
            && (text.contains("No such file or directory") || text.contains("Connection refused"))
    }

    /// Parses `Master running (pid=62706)`.
    static func masterPID(in text: String) -> Int32? {
        guard let start = text.range(of: "(pid=") else { return nil }
        let digits = text[start.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int32(digits)
    }

    /// Unix sockets directly inside `directory` (not following symlinks).
    static func sockets(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.filePath)) ?? []
        return names.sorted().compactMap { name in
            let url = directory.appending(path: name)
            var info = stat()
            guard lstat(url.filePath, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
            return url
        }
    }
}
