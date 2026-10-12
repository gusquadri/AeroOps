import AeroCore
import Foundation
import Synchronization

/// A long-lived ssh session whose stdin and stdout carry a binary protocol, such as the `sftp`
/// subsystem. Opened with ``SSHRunner/openSubsystem(_:on:)``.
///
/// Bytes from the remote side arrive on ``incoming`` in order; ``send(_:)`` queues bytes for
/// the remote side. The stream finishes when ssh exits, after which ``waitForExit()`` returns
/// how it ended (``SSHResult/transportError`` says why the connection failed).
public final class SSHChannel: Sendable {
    /// Everything the remote side wrote, in order. Unbounded: the consumer is expected to keep up.
    public let incoming: AsyncStream<Data>

    private let child: ChildProcess
    private let exit: ExitBox

    init(spec: ChildSpec, onTransportError: @escaping @Sendable (SSHError) -> Void) throws(SSHError) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let exit = ExitBox()
        do {
            child = try ChildProcess.launch(spec, mode: .stream { data in continuation.yield(data) }) { outcome in
                let result = SSHResult(outcome)
                if let error = result.transportError { onTransportError(error) }
                exit.finish(result)
                continuation.finish()
            }
        } catch {
            throw .launchFailed(error.message)
        }
        incoming = stream
        self.exit = exit
        let child = child
        continuation.onTermination = { _ in child.terminate() }
    }

    /// Queues `data` for the remote side. Dropped once the channel was closed.
    public func send(_ data: Data) {
        child.write(data)
    }

    /// Closes the remote side's stdin once everything queued was sent; the remote program sees
    /// EOF and normally exits.
    public func closeInput() {
        child.closeStdin()
    }

    /// Ends the session now: ssh and its process group are terminated.
    public func close() {
        child.terminate()
    }

    /// How ssh ended, or `nil` while it runs.
    public var result: SSHResult? {
        exit.result
    }

    /// Waits until ssh exited and returns how it ended.
    public func waitForExit() async -> SSHResult {
        await exit.wait()
    }
}

/// The exit result of a channel, awaitable from any task.
private final class ExitBox: Sendable {
    private struct State {
        var result: SSHResult?
        var waiters: [CheckedContinuation<SSHResult, Never>] = []
    }

    private let state = Mutex(State())

    var result: SSHResult? {
        state.withLock { $0.result }
    }

    func finish(_ result: SSHResult) {
        let waiters = state.withLock { state in
            state.result = result
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func wait() async -> SSHResult {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state in
                if state.result == nil { state.waiters.append(continuation) }
                return state.result
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}

extension SSHRunner {
    /// Starts the subsystem `name` (for example `sftp`) on `host` and returns the channel:
    ///
    /// ```text
    /// /usr/bin/ssh -F ~/.aeroops/ssh_config -o BatchMode=yes -T -s -- aero-<id> sftp
    /// ```
    ///
    /// There is no timeout; the session lasts until ``SSHChannel/close()``, EOF or a dead
    /// connection (the generated config's `ServerAliveInterval` notices those). A blocked host is
    /// refused before ssh starts, and a changed host key reported by ssh blocks the host; password
    /// hosts go through the ``PasswordAttemptGate`` like ``run(_:on:stdin:timeout:outputLimit:)``.
    public func openSubsystem(_ name: String, on host: RemoteHost) async throws -> SSHChannel {
        try await admit(host)
        do {
            return try openSubsystem(name, target: target(for: host)) { error in
                Task { await self.settle(host, error) }
            }
        } catch {
            await settle(host, nil)
            throw error
        }
    }

    func openSubsystem(
        _ name: String,
        alias: String,
        onTransportError: @escaping @Sendable (SSHError) -> Void = { _ in }
    ) throws -> SSHChannel {
        try openSubsystem(name, target: Target(alias: alias, context: context), onTransportError: onTransportError)
    }

    func openSubsystem(
        _ name: String,
        target: Target,
        onTransportError: @escaping @Sendable (SSHError) -> Void = { _ in }
    ) throws -> SSHChannel {
        try Task.checkCancellation()
        guard Self.isValidSubsystem(name) else { throw SSHError.invalidRequest("invalid subsystem “\(name)”") }
        guard Self.isValidAlias(target.alias) else { throw SSHError.invalidRequest("invalid host alias “\(target.alias)”") }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(target.environment) { _, override in override }
        let spec = ChildSpec(
            executable: context.sshExecutable.filePath,
            arguments: ["-F", context.configFile.filePath] + target.options + ["-T", "-s", "--", target.alias, name],
            environment: environment,
            stdin: nil,
            interactiveStdin: true,
            timeout: nil,
            outputLimit: Self.defaultOutputLimit
        )
        return try SSHChannel(spec: spec, onTransportError: onTransportError)
    }

    /// Letters, digits, `.`, `_`, `-` and `@` (as in `sftp` or `name@example.com`); not starting with `-`.
    static func isValidSubsystem(_ name: String) -> Bool {
        guard let first = name.utf8.first, first != UInt8(ascii: "-") else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "@"):
                true
            default:
                false
            }
        }
    }
}
