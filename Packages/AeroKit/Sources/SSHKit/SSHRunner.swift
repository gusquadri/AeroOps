import AeroCore
import Foundation

/// Runs non-interactive commands on hosts through the system ssh:
///
/// ```text
/// /usr/bin/ssh -F ~/.aeroops/ssh_config -o BatchMode=yes -- aero-<id> <command>
/// ```
///
/// - `BatchMode=yes`: ssh never prompts, so a missing key or an
///   unknown host key fails fast instead of hanging. Password hosts with an askpass route run
///   without it, because `BatchMode` turns password authentication off; ssh asks
///   `aeroops-askpass` instead of a terminal.
/// - `--` ends ssh's options, so a command starting with `-` can never be read as one.
/// - `SSH_AUTH_SOCK` is the in-app agent's socket (the config's `IdentityAgent` wins anyway).
/// - The command is one remote shell string. Quote every interpolated value with
///   `ShellQuote.quote`, or use ``run(arguments:on:stdin:timeout:outputLimit:)``.
///
/// With a ``HostKeyStore``, hosts whose key changed are refused before ssh starts, and a
/// changed key reported by ssh blocks the host. With a ``PasswordAttemptGate``, password hosts
/// without a saved password, or whose password was rejected, are refused before ssh starts, and
/// a rejection reported by ssh closes the gate.
public struct SSHRunner: Sendable {
    public let context: SSHContext
    public let hostKeys: HostKeyStore?
    public let passwords: PasswordAttemptGate?

    public static let defaultTimeout: Duration = .seconds(30)
    public static let defaultOutputLimit = 64 * 1024
    /// Longest line a stream delivers in one piece.
    public static let maxLineLength = 64 * 1024

    public init(context: SSHContext = .standard, hostKeys: HostKeyStore? = nil, passwords: PasswordAttemptGate? = nil) {
        self.context = context
        self.hostKeys = hostKeys
        self.passwords = passwords
    }

    /// The full invocation for `command` on `host` (useful for logging argv, never secrets).
    public func commandLine(_ command: String, on host: RemoteHost) -> SSHCommandLine {
        commandLine(command, target: target(for: host))
    }

    func commandLine(_ command: String, alias: String) -> SSHCommandLine {
        commandLine(command, target: Target(alias: alias, context: context))
    }

    func commandLine(_ command: String, target: Target) -> SSHCommandLine {
        SSHCommandLine(
            executable: context.sshExecutable,
            arguments: ["-F", context.configFile.filePath] + target.options + ["--", target.alias, command],
            environment: target.environment
        )
    }

    /// The alias, options and environment ssh gets for one host.
    struct Target: Sendable {
        var alias: String
        /// `-o BatchMode=yes`, except for password hosts that ssh can ask `aeroops-askpass` about.
        var batchMode = true
        var environment: [String: String]

        /// A key host: `BatchMode` and the context's environment. Tests address hosts this way.
        init(alias: String, context: SSHContext) {
            self.alias = alias
            environment = context.environmentOverrides
        }

        init(host: RemoteHost, context: SSHContext) {
            alias = host.sshAlias
            batchMode = !context.usesAskpass(host)
            environment = context.environment(for: host)
        }

        var options: [String] { batchMode ? ["-o", "BatchMode=yes"] : [] }
    }

    func target(for host: RemoteHost) -> Target {
        Target(host: host, context: context)
    }

    // MARK: - Run to completion

    /// Runs `command` and collects its output.
    ///
    /// Failures of ssh itself are reported in ``SSHResult/transportError``, the remote status in
    /// ``SSHResult/exitCode``; use ``SSHResult/checked()`` to turn either into a thrown
    /// ``SSHError``. Throws only for requests that never reach ssh: a blocked host
    /// (``SSHError/hostKeyChanged``), an invalid command, a launch failure, or task cancellation
    /// (`CancellationError`, after the process group was killed).
    ///
    /// - Parameters:
    ///   - stdin: written to the remote command's stdin; `nil` means `/dev/null`.
    ///   - timeout: kills ssh (and its process group) when exceeded; the result has `timedOut`.
    ///   - outputLimit: bytes kept per stream; the rest is discarded and flagged as truncated.
    public func run(
        _ command: String,
        on host: RemoteHost,
        stdin: Data? = nil,
        timeout: Duration = SSHRunner.defaultTimeout,
        outputLimit: Int = SSHRunner.defaultOutputLimit
    ) async throws -> SSHResult {
        try await admit(host)
        let result: SSHResult
        do {
            result = try await run(command, target: target(for: host), stdin: stdin, timeout: timeout, outputLimit: outputLimit)
        } catch {
            await settle(host, nil)
            throw error
        }
        await settle(host, result.transportError, loggedIn: result.transportError == nil)
        return result
    }

    /// Like ``run(_:on:stdin:timeout:outputLimit:)``, and also hands each piece of stdout and
    /// stderr to `onOutput` as it arrives (on a private queue), up to `outputLimit` per stream.
    /// The result still carries the collected output.
    public func run(
        _ command: String,
        on host: RemoteHost,
        stdin: Data? = nil,
        timeout: Duration = SSHRunner.defaultTimeout,
        outputLimit: Int = SSHRunner.defaultOutputLimit,
        onOutput: @escaping @Sendable (SSHOutputStream, Data) -> Void
    ) async throws -> SSHResult {
        try await admit(host)
        let mode = ChildProcess.OutputMode.observe { isStdout, data in
            onOutput(isStdout ? .stdout : .stderr, data)
        }
        let result: SSHResult
        do {
            result = try await run(command, target: target(for: host), stdin: stdin, timeout: timeout, outputLimit: outputLimit, mode: mode)
        } catch {
            await settle(host, nil)
            throw error
        }
        await settle(host, result.transportError, loggedIn: result.transportError == nil)
        return result
    }

    /// Runs `arguments` as one remote command, each argument quoted with `ShellQuote.quote`.
    public func run(
        arguments: [String],
        on host: RemoteHost,
        stdin: Data? = nil,
        timeout: Duration = SSHRunner.defaultTimeout,
        outputLimit: Int = SSHRunner.defaultOutputLimit
    ) async throws -> SSHResult {
        try await run(ShellQuote.join(arguments), on: host, stdin: stdin, timeout: timeout, outputLimit: outputLimit)
    }

    func run(
        _ command: String,
        alias: String,
        stdin: Data? = nil,
        timeout: Duration = SSHRunner.defaultTimeout,
        outputLimit: Int = SSHRunner.defaultOutputLimit,
        mode: ChildProcess.OutputMode = .collect
    ) async throws -> SSHResult {
        try await run(command, target: Target(alias: alias, context: context), stdin: stdin, timeout: timeout, outputLimit: outputLimit, mode: mode)
    }

    func run(
        _ command: String,
        target: Target,
        stdin: Data? = nil,
        timeout: Duration = SSHRunner.defaultTimeout,
        outputLimit: Int = SSHRunner.defaultOutputLimit,
        mode: ChildProcess.OutputMode = .collect
    ) async throws -> SSHResult {
        let spec = try spec(command, target: target, stdin: stdin, timeout: timeout, outputLimit: outputLimit)
        do {
            return SSHResult(try await ChildProcess.run(spec, mode: mode))
        } catch let error as ChildLaunchError {
            throw SSHError.launchFailed(error.message)
        }
    }

    // MARK: - Streaming

    /// Runs `command` and yields its stdout line by line (without line terminators).
    ///
    /// The stream finishes normally on exit status 0 and throws ``SSHError`` otherwise
    /// (``SSHError/remoteCommandFailed(exitCode:stderr:)`` for a remote failure). Cancelling the
    /// consuming task, breaking out of the loop or dropping the stream terminates ssh and its
    /// process group. When the consumer falls behind, the oldest of `maxBufferedLines` are dropped.
    ///
    /// - Parameter timeout: `nil` (the default) for long-running commands such as `logs -f`.
    public func stream(
        _ command: String,
        on host: RemoteHost,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        maxBufferedLines: Int = 10_000
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try await admit(host)
        do {
            return try stream(command, target: target(for: host), stdin: stdin, timeout: timeout, maxBufferedLines: maxBufferedLines) { error in
                Task { await self.settle(host, error) }
            }
        } catch {
            await settle(host, nil)
            throw error
        }
    }

    func stream(
        _ command: String,
        alias: String,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        maxBufferedLines: Int = 10_000,
        onTransportError: @escaping @Sendable (SSHError) -> Void = { _ in }
    ) throws -> AsyncThrowingStream<String, any Error> {
        try stream(
            command, target: Target(alias: alias, context: context), stdin: stdin, timeout: timeout,
            maxBufferedLines: maxBufferedLines, onTransportError: onTransportError
        )
    }

    func stream(
        _ command: String,
        target: Target,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        maxBufferedLines: Int = 10_000,
        onTransportError: @escaping @Sendable (SSHError) -> Void = { _ in }
    ) throws -> AsyncThrowingStream<String, any Error> {
        try Task.checkCancellation()
        let spec = try spec(command, target: target, stdin: stdin, timeout: timeout, outputLimit: Self.defaultOutputLimit)
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, maxBufferedLines))
        )
        let mode = ChildProcess.OutputMode.lines(maxLength: Self.maxLineLength) { line in
            continuation.yield(line)
        }
        let child: ChildProcess
        do {
            child = try ChildProcess.launch(spec, mode: mode) { outcome in
                if outcome.cancelled {
                    continuation.finish()
                    return
                }
                let result = SSHResult(outcome)
                if let error = result.transportError {
                    onTransportError(error)
                    continuation.finish(throwing: error)
                } else if result.exitCode != 0 {
                    continuation.finish(throwing: SSHError.remoteCommandFailed(
                        exitCode: result.exitCode, stderr: SSHError.trimmed(result.stderrString)
                    ))
                } else {
                    continuation.finish()
                }
            }
        } catch {
            throw SSHError.launchFailed(error.message)
        }
        continuation.onTermination = { _ in child.terminate() }
        return stream
    }

    // MARK: - Helpers

    func refuseIfBlocked(_ host: RemoteHost) async throws {
        try Task.checkCancellation()
        if let hostKeys, await hostKeys.isBlocked(host) { throw SSHError.hostKeyChanged }
    }

    /// ``refuseIfBlocked(_:)``, then the password gate.
    func admit(_ host: RemoteHost) async throws {
        try await refuseIfBlocked(host)
        try await passwords?.admit(host)
    }

    /// Records what one ssh run means for `host`: a changed host key blocks it. For a password
    /// host whose ssh could ask `aeroops-askpass`, a rejection closes the password gate and a
    /// login proves the password; anything else just lets the next run try.
    ///
    /// - Parameters:
    ///   - error: ssh's transport error, `nil` if there was none or ssh never finished.
    ///   - loggedIn: ssh finished without a transport error, so it authenticated.
    func settle(_ host: RemoteHost, _ error: SSHError?, loggedIn: Bool = false) async {
        if error == .hostKeyChanged { await hostKeys?.block(host) }
        guard let passwords, host.auth == .password else { return }
        if error == .authFailed, context.usesAskpass(host) {
            await passwords.reject(host.id)
        } else if loggedIn, context.usesAskpass(host) {
            await passwords.accept(host.id)
        } else {
            await passwords.release(host.id)
        }
    }

    private func spec(
        _ command: String,
        target: Target,
        stdin: Data?,
        timeout: Duration?,
        outputLimit: Int
    ) throws(SSHError) -> ChildSpec {
        guard !command.isEmpty else { throw .invalidRequest("empty remote command") }
        guard !command.utf8.contains(0) else { throw .invalidRequest("remote command contains a NUL byte") }
        guard Self.isValidAlias(target.alias) else { throw .invalidRequest("invalid host alias “\(target.alias)”") }
        let line = commandLine(command, target: target)
        var environment = ProcessInfo.processInfo.environment
        environment.merge(line.environment) { _, override in override }
        return ChildSpec(
            executable: line.executable.filePath,
            arguments: line.arguments,
            environment: environment,
            stdin: stdin,
            timeout: timeout,
            outputLimit: outputLimit
        )
    }

    /// Lower-case letters, digits, `.`, `_`, `-`; not starting with `-`.
    static func isValidAlias(_ alias: String) -> Bool {
        guard let first = alias.utf8.first, first != UInt8(ascii: "-") else { return false }
        return alias.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}

/// Which stream a piece of live output came from.
public enum SSHOutputStream: Sendable, Hashable {
    case stdout, stderr
}

/// The outcome of ``SSHRunner/run(_:on:stdin:timeout:outputLimit:)``.
public struct SSHResult: Sendable, Hashable {
    /// The exit status: the remote command's, or 255 for ssh errors; `128 + signal` if ssh was killed.
    public var exitCode: Int32
    /// The signal that killed the local ssh process, if any.
    public var signal: Int32?
    /// Up to `outputLimit` bytes of stdout.
    public var stdout: Data
    /// Up to `outputLimit` bytes of stderr.
    public var stderr: Data
    /// stdout produced more than `outputLimit` bytes.
    public var stdoutTruncated: Bool
    /// stderr produced more than `outputLimit` bytes.
    public var stderrTruncated: Bool
    /// From spawn to exit.
    public var duration: Duration
    /// SSHKit killed ssh because the timeout expired.
    public var timedOut: Bool

    public init(
        exitCode: Int32,
        signal: Int32? = nil,
        stdout: Data = Data(),
        stderr: Data = Data(),
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        duration: Duration = .zero,
        timedOut: Bool = false
    ) {
        self.exitCode = exitCode
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.duration = duration
        self.timedOut = timedOut
    }

    init(_ outcome: ChildOutcome) {
        switch outcome.termination {
        case .exited(let code):
            exitCode = code
            signal = nil
        case .signaled(let signal):
            exitCode = 128 + signal
            self.signal = signal
        }
        stdout = outcome.stdout.data
        stderr = outcome.stderr.data
        stdoutTruncated = outcome.stdout.truncated
        stderrTruncated = outcome.stderr.truncated
        duration = outcome.duration
        timedOut = outcome.timedOut
    }

    /// stdout as UTF-8 (invalid bytes replaced).
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    /// stderr as UTF-8 (invalid bytes replaced).
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }

    /// Why ssh itself failed, or `nil` if the remote command ran (whatever its exit status).
    ///
    /// Timeouts map to ``SSHError/timeout``; exit status 255 is classified from stderr.
    public var transportError: SSHError? {
        if timedOut { return .timeout }
        // `aeroops-askpass` terminates ssh when it has no password to give.
        if signal != nil, stderrString.contains(SSHError.askpassMarker) { return .authFailed }
        if let signal { return .other("ssh was terminated by signal \(signal)") }
        if exitCode == 255 { return SSHError.classify(stderr: stderrString) }
        return nil
    }

    /// The command ran and exited 0.
    public var succeeded: Bool { transportError == nil && exitCode == 0 }

    /// Returns `self` if the command succeeded, otherwise throws ``transportError`` or
    /// ``SSHError/remoteCommandFailed(exitCode:stderr:)``.
    @discardableResult
    public func checked() throws(SSHError) -> SSHResult {
        if let transportError { throw transportError }
        if exitCode != 0 { throw .remoteCommandFailed(exitCode: exitCode, stderr: SSHError.trimmed(stderrString)) }
        return self
    }
}
