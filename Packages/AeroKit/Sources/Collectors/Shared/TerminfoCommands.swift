import AeroCore
import Foundation
import SSHKit

/// What ``RemoteScripts/terminfoCheck`` found on a host.
public struct TerminfoSupport: Sendable, Hashable {
    /// The host knows `xterm-ghostty`, so terminal tabs can use it as `TERM`.
    public var hasGhosttyEntry: Bool
    /// `tic` is installed, so ``TerminfoCommands/install(_:)`` can add the entry.
    public var canInstall: Bool

    public init(hasGhosttyEntry: Bool, canInstall: Bool) {
        self.hasGhosttyEntry = hasGhosttyEntry
        self.canInstall = canInstall
    }

    /// Parses the check's output: one token per line. Unknown tokens and junk are ignored.
    public init(checkOutput: String) {
        let words = Set(checkOutput.split(whereSeparator: { $0.isWhitespace || $0.isNewline }))
        hasGhosttyEntry = words.contains("xterm-ghostty")
        canInstall = words.contains("tic")
    }
}

/// Checks for Ghostty's terminfo entry on a host and installs it for the login user.
///
/// ```swift
/// let terminfo = TerminfoCommands(runner: ssh.runner)
/// let support = try await terminfo.check(host)
/// if !support.hasGhosttyEntry, support.canInstall { _ = try await terminfo.install(host) }
/// ```
public struct TerminfoCommands: Sendable {
    /// `SSHRunner` in the app.
    public let runner: any HostCommandRunning

    public init(runner: any HostCommandRunning) {
        self.runner = runner
    }

    /// Runs ``RemoteScripts/terminfoCheck``.
    ///
    /// - Throws: `SSHError` when ssh fails, the script exits non-zero or `timeout` passes.
    public func check(_ host: RemoteHost, timeout: Duration = .seconds(4)) async throws -> TerminfoSupport {
        let result = try await runner.run(
            RemoteScripts.shellCommand, on: host, stdin: Data(RemoteScripts.terminfoCheck.utf8),
            timeout: timeout, outputLimit: 4 * 1024
        )
        try result.checked()
        return TerminfoSupport(checkOutput: result.stdoutString)
    }

    /// Runs ``RemoteScripts/terminfoInstall``, then checks again so the result reflects what
    /// the host's curses now finds.
    ///
    /// - Throws: `SSHError`; `.remoteCommandFailed(exitCode: 3, ...)` when `tic` is missing.
    public func install(_ host: RemoteHost, timeout: Duration = .seconds(20)) async throws -> TerminfoSupport {
        let result = try await runner.run(
            RemoteScripts.shellCommand, on: host, stdin: Data(RemoteScripts.terminfoInstall.utf8),
            timeout: timeout, outputLimit: 16 * 1024
        )
        try result.checked()
        return try await check(host)
    }
}
