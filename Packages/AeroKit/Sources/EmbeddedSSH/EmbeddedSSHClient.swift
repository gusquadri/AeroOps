import AeroCore
import Collectors
import Foundation
import KeyAgent
import NIOCore
import NIOPosix
import NIOSSH
import SSHKit

/// Runs remote commands with an in-process SSH client (swift-nio-ssh), for iOS, which has no
/// `/usr/bin/ssh`. A drop-in for ``SSHKit/SSHRunner`` wherever the collectors take a
/// ``Collectors/RemoteCommandRunning``, with the same semantics:
///
/// - Host keys are checked against SSHKit's ``SSHKit/HostKeyStore``: an unknown key fails with
///   ``SSHKit/SSHError/hostKeyUnknown``, a changed one blocks the host and fails with
///   ``SSHKit/SSHError/hostKeyChanged``, and a blocked host is refused before connecting.
/// - Keys come from KeyAgent's ``KeyAgent/KeyStore`` (authorized per key policy), passwords from
///   its ``KeyAgent/HostPasswordVault``, behind the same ``SSHKit/PasswordAttemptGate``.
/// - Errors are ``SSHKit/SSHError``s; a timeout returns a result with `timedOut`, a remote
///   command killed by a signal exits `128 + signo`.
///
/// Long-lived sessions run on the same connections: the `sftp` subsystem for ``SSHKit/SFTPClient``
/// (``openSubsystem(_:on:timeout:)``) and shells in a pseudo-terminal
/// (``openTerminal(on:term:size:command:timeout:)``).
///
/// Each host's connection stays open between commands (``ConnectionPool``). Call
/// ``disconnectAll()`` when the app goes to the background; that ends the sessions too.
///
/// Limits (swift-nio-ssh's): Ed25519 and ECDSA P-256 keys only (no RSA); servers must offer
/// curve25519 or ECDH key exchange, AES-GCM and an Ed25519 or ECDSA host key; password logins use
/// the `password` method (not `keyboard-interactive`).
public final class EmbeddedSSHClient: RemoteCommandRunning {
    public let hostKeys: HostKeyStore
    public let passwords: PasswordAttemptGate?
    private let pool: ConnectionPool

    public init(
        hostKeys: HostKeyStore,
        credentials: EmbeddedSSHCredentials,
        passwordGate: PasswordAttemptGate? = nil,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.hostKeys = hostKeys
        passwords = passwordGate
        pool = ConnectionPool { host in
            try await Self.connect(host, hostKeys: hostKeys, credentials: credentials, gate: passwordGate, group: group)
        }
    }

    // MARK: - Run to completion

    /// Runs `command` and collects its output. Throws the ``SSHKit/SSHError`` that kept it from
    /// running; a command that ran returns its exit status, whatever it is.
    ///
    /// - Parameters:
    ///   - stdin: written to the remote command's stdin, then EOF; `nil` sends EOF at once.
    ///   - timeout: stops the command when exceeded; the result has `timedOut`.
    ///   - outputLimit: bytes kept per stream; the rest is discarded and flagged as truncated.
    public func run(
        _ command: String,
        on host: RemoteHost,
        stdin: Data? = nil,
        timeout: Duration = SSHRunner.defaultTimeout,
        outputLimit: Int = SSHRunner.defaultOutputLimit
    ) async throws -> SSHResult {
        try Self.validate(command, host)
        try await refuseIfBlocked(host)
        let started = ContinuousClock.now
        let (events, continuation) = AsyncStream<ExecEvent>.makeStream()
        let control = ExecControl()
        open(command, on: host, stdin: stdin, events: continuation, control: control)
        let timer = Task {
            try await Task.sleep(for: timeout)
            continuation.yield(.timedOut)
            continuation.finish()
            control.stop()
        }
        defer { timer.cancel() }

        var outcome = Outcome()
        var stdout = OutputBuffer(limit: outputLimit)
        var stderr = OutputBuffer(limit: outputLimit)
        await withTaskCancellationHandler {
            for await event in events {
                switch event {
                case .stdout(let buffer): stdout.append(buffer)
                case .stderr(let buffer): stderr.append(buffer)
                default: outcome.record(event)
                }
                if outcome.timedOut { break }
            }
        } onCancel: {
            control.stop()
            continuation.finish()
        }
        try Task.checkCancellation()
        if outcome.timedOut {
            // An established connection that cannot even start a command is most likely dead
            // (no RST yet); close it so the next command connects afresh.
            if !outcome.started { control.connection?.close() }
            return SSHResult(
                exitCode: 255, stdout: stdout.data, stderr: stderr.data, stdoutTruncated: stdout.truncated,
                stderrTruncated: stderr.truncated, duration: .now - started, timedOut: true
            )
        }
        let exitCode = try outcome.exitCode()
        return SSHResult(
            exitCode: exitCode, stdout: stdout.data, stderr: stderr.data, stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated, duration: .now - started
        )
    }

    // MARK: - Streaming

    /// Runs `command` and yields its stdout line by line (without line terminators), like
    /// ``SSHKit/SSHRunner/stream(_:on:stdin:timeout:maxBufferedLines:)``: the stream finishes on
    /// exit status 0 and throws ``SSHKit/SSHError`` otherwise. Cancelling the consuming task,
    /// breaking out of the loop or dropping the stream closes the command's channel. When the
    /// consumer falls behind, the oldest of `maxBufferedLines` are dropped.
    public func stream(
        _ command: String,
        on host: RemoteHost,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        maxBufferedLines: Int = 10_000
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try Self.validate(command, host)
        try await refuseIfBlocked(host)
        let (lines, output) = AsyncThrowingStream<String, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, maxBufferedLines))
        )
        let (events, continuation) = AsyncStream<ExecEvent>.makeStream()
        let control = ExecControl()
        open(command, on: host, stdin: stdin, events: continuation, control: control)
        let timer = timeout.map { timeout in
            Task {
                try await Task.sleep(for: timeout)
                continuation.yield(.timedOut)
                continuation.finish()
                control.stop()
            }
        }
        let pump = Task {
            var splitter = LineSplitter(maxLength: SSHRunner.maxLineLength)
            var stderr = OutputBuffer(limit: SSHRunner.defaultOutputLimit)
            var outcome = Outcome()
            for await event in events {
                switch event {
                case .stdout(let buffer):
                    buffer.withUnsafeReadableBytes { bytes in splitter.append(bytes) { output.yield($0) } }
                case .stderr(let buffer):
                    stderr.append(buffer)
                default:
                    outcome.record(event)
                }
                if outcome.timedOut { break }
            }
            timer?.cancel()
            if Task.isCancelled { return output.finish() }
            if outcome.timedOut { return output.finish(throwing: SSHError.timeout) }
            splitter.finish { output.yield($0) }
            do {
                let exitCode = try outcome.exitCode()
                guard exitCode == 0 else {
                    let message = SSHError.trimmed(String(decoding: stderr.data, as: UTF8.self))
                    return output.finish(throwing: SSHError.remoteCommandFailed(exitCode: exitCode, stderr: message))
                }
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }
        output.onTermination = { _ in
            pump.cancel()
            timer?.cancel()
            control.stop()
            continuation.finish()
        }
        return lines
    }

    // MARK: - Sessions

    /// Starts the subsystem `name` (for example `sftp`) on `host` and returns its channel once the
    /// server started it: the in-process counterpart of ``SSHKit/SSHRunner/openSubsystem(_:on:)``.
    /// The session lasts until ``EmbeddedSSHChannel/close()``, EOF or its connection closes.
    ///
    /// - Throws: ``SSHKit/SSHError``: what ``run(_:on:stdin:timeout:outputLimit:)`` throws before
    ///   a command starts, `other` when the server has no such subsystem, `timeout` when the
    ///   session has not started within `timeout`.
    public func openSubsystem(_ name: String, on host: RemoteHost, timeout: Duration = .seconds(30)) async throws -> EmbeddedSSHChannel {
        guard SSHRunner.isValidSubsystem(name) else { throw SSHError.invalidRequest("invalid subsystem “\(name)”") }
        return try await openSession(on: host, requests: [.subsystem(name)], mergesStandardError: false, timeout: timeout)
    }

    /// Starts a login shell, or `command`, on `host` in a pseudo-terminal of `size`, for a terminal
    /// view: ``EmbeddedSSHChannel/incoming`` is what it shows, ``EmbeddedSSHChannel/send(_:)``
    /// takes what the user types and ``EmbeddedSSHChannel/resize(_:)`` the view's new size. When
    /// the shell exits, ``EmbeddedSSHChannel/exitStatus`` says how.
    ///
    /// - Parameters:
    ///   - term: The remote side's `TERM` (`xterm-256color`, or `xterm-ghostty` on hosts with its
    ///     terminfo entry).
    ///   - command: Runs instead of the login shell, like `ssh -t <host> -- <command>`; already
    ///     shell-quoted by the caller.
    /// - Throws: what ``openSubsystem(_:on:timeout:)`` throws; `other` when the server refuses
    ///   the terminal or the shell.
    public func openTerminal(
        on host: RemoteHost,
        term: String,
        size: PseudoTerminalSize,
        command: String? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> EmbeddedSSHChannel {
        guard Self.isValidTerm(term) else { throw SSHError.invalidRequest("invalid terminal type “\(term)”") }
        if let command { try Self.validate(command, host) }
        let program: SessionRequest = command.map { .exec($0) } ?? .shell
        return try await openSession(
            on: host, requests: [.pseudoTerminal(term: term, size: size), program], mergesStandardError: true, timeout: timeout
        )
    }

    /// Opens a session channel with `requests` and waits until the server granted them all. Like
    /// ``run(_:on:stdin:timeout:outputLimit:)``, the caller only waits for the session's state, so
    /// the timeout and cancellation work while a login is still running.
    private func openSession(
        on host: RemoteHost,
        requests: [SessionRequest],
        mergesStandardError: Bool,
        timeout: Duration
    ) async throws -> EmbeddedSSHChannel {
        try Self.validate(host)
        try await refuseIfBlocked(host)
        let state = SessionState()
        let control = ExecControl()
        Task {
            do {
                _ = try await openChannel(on: host, control: control) {
                    SessionHandler(requests: requests, mergesStandardError: mergesStandardError, state: state)
                }
            } catch {
                state.fail(error)
            }
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            guard state.abandonStart(SSHError.timeout) else { return }
            control.stop()
            // As for a command that cannot start: the connection is most likely dead.
            control.connection?.close()
        }
        defer { timer.cancel() }
        do {
            let child = try await withTaskCancellationHandler {
                try await state.waitForStart()
            } onCancel: {
                if state.abandonStart(CancellationError()) { control.stop() }
            }
            return EmbeddedSSHChannel(child: child, state: state)
        } catch {
            control.stop()
            try Task.checkCancellation()
            throw error
        }
    }

    // MARK: - Connections

    /// Closes `id`'s connections (after its settings changed, or it was deleted).
    public func disconnect(_ id: RemoteHost.ID) async {
        await pool.disconnect(id)
    }

    /// Closes every connection, e.g. when the app moves to the background.
    public func disconnectAll() async {
        await pool.disconnectAll()
    }

    // MARK: - Internals

    /// Gets `host` a connection and starts `command` on it, in the background: the caller only
    /// waits for `events`, so its timeout and cancellation work while a login is still running.
    /// A command that cannot start on a reused connection is retried once on a new one.
    private func open(
        _ command: String,
        on host: RemoteHost,
        stdin: Data?,
        events: AsyncStream<ExecEvent>.Continuation,
        control: ExecControl
    ) {
        Task {
            do {
                _ = try await openChannel(on: host, control: control) {
                    ExecHandler(command: command, stdin: stdin, events: events)
                }
            } catch {
                events.yield(.failed(error))
                events.finish()
            }
        }
    }

    /// Opens a session channel on one of `host`'s connections, driven by the handler
    /// `makeHandler` makes. A channel that cannot open on a reused connection is retried once on
    /// a new one. Throws `CancellationError` once `control` was stopped.
    private func openChannel(
        on host: RemoteHost,
        control: ExecControl,
        makeHandler: @escaping @Sendable () -> any ChannelHandler
    ) async throws -> any Channel {
        var attempt = 0
        while true {
            let (connection, reused) = try await pool.reserve(for: host)
            control.connection = connection
            guard !control.isStopped else {
                connection.release()
                throw CancellationError()
            }
            do {
                return try await connection.openSession(control: control, makeHandler: makeHandler)
            } catch {
                connection.release()
                let refused = (error as? NIOSSHError)?.type == .channelSetupRejected
                guard reused, attempt == 0, !refused, !control.isStopped else { throw error }
                connection.close()
                attempt += 1
            }
        }
    }

    private func refuseIfBlocked(_ host: RemoteHost) async throws {
        try Task.checkCancellation()
        if await hostKeys.isBlocked(host) { throw SSHError.hostKeyChanged }
    }

    /// What ``SSHKit/SSHRunner`` and the generated ssh_config refuse too.
    static func validate(_ command: String, _ host: RemoteHost) throws(SSHError) {
        guard !command.isEmpty else { throw .invalidRequest("empty remote command") }
        guard !command.utf8.contains(0) else { throw .invalidRequest("remote command contains a NUL byte") }
        try validate(host)
    }

    static func validate(_ host: RemoteHost) throws(SSHError) {
        guard HostValidation.isValidAddress(host.address) else { throw .invalidRequest("invalid host address “\(host.address)”") }
        guard HostValidation.isValidUser(host.user) else { throw .invalidRequest("invalid user name “\(host.user)”") }
        guard (1...65535).contains(host.port) else { throw .invalidRequest("port \(host.port) is outside 1–65535") }
    }

    /// A terminal type name: 1 to 64 letters, digits, `.`, `_`, `+` and `-`, not starting with `-`.
    static func isValidTerm(_ term: String) -> Bool {
        guard let first = term.utf8.first, first != UInt8(ascii: "-"), term.utf8.count <= 64 else { return false }
        return term.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "+"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }

    /// One login to `host`, settled with the password gate like ``SSHKit/SSHRunner`` settles each
    /// ssh run: a rejection closes the gate, a login proves the password, anything else lets the
    /// next attempt try.
    private static func connect(
        _ host: RemoteHost,
        hostKeys: HostKeyStore,
        credentials: EmbeddedSSHCredentials,
        gate: PasswordAttemptGate?,
        group: any EventLoopGroup
    ) async throws -> SSHConnection {
        try await gate?.admit(host)
        do {
            let connection = try await SSHConnection.connect(address: host.address, port: host.port, group: group) {
                (
                    UserAuthDelegate(host: host, credentials: credentials),
                    HostKeyDelegate { key in try await checkHostKey(key, for: host, in: hostKeys) }
                )
            }
            if let gate, host.auth == .password { await gate.accept(host.id) }
            return connection
        } catch {
            let error = EmbeddedSSHErrors.classify(error)
            if let gate, host.auth == .password {
                if error as? SSHError == .authFailed { await gate.reject(host.id) } else { await gate.release(host.id) }
            }
            throw error
        }
    }
}

/// How a command ended, from its ``ExecEvent``s.
private struct Outcome {
    var started = false
    var exitStatus: Int32?
    var refused = false
    var failure: (any Error)?
    var timedOut = false

    mutating func record(_ event: ExecEvent) {
        switch event {
        case .started: started = true
        case .exitStatus(let status): exitStatus = Int32(truncatingIfNeeded: status)
        case .exitSignal(let name): exitStatus = EmbeddedSSHErrors.exitCode(forSignal: name)
        case .refused: refused = true
        case .failed(let error): failure = failure ?? EmbeddedSSHErrors.classify(error)
        case .timedOut: timedOut = true
        case .stdout, .stderr: break
        }
    }

    /// The exit status, or the error that kept the command from reporting one.
    func exitCode() throws -> Int32 {
        if let exitStatus { return exitStatus }
        if let failure { throw failure }
        if refused { throw SSHError.other("The server refused to run the command.") }
        throw SSHError.connectionClosed
    }
}

/// Up to `limit` bytes of one output stream.
private struct OutputBuffer {
    let limit: Int
    var data = Data()
    var truncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    mutating func append(_ buffer: ByteBuffer) {
        let room = limit - data.count
        if buffer.readableBytes > room { truncated = true }
        guard room > 0 else { return }
        buffer.withUnsafeReadableBytes { bytes in
            data.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes.prefix(room)))
        }
    }
}
