import AeroCore
import BridgeProtocol
import Foundation
import SSHKit
import Synchronization

/// A piece of live command output.
public struct CommandOutputChunk: Sendable, Hashable {
    public enum Stream: String, Sendable, Hashable, Codable {
        case stdout, stderr
    }

    public var stream: Stream
    public var data: Data

    public init(stream: Stream, data: Data) {
        self.stream = stream
        self.data = data
    }
}

/// What a ``RemoteCommandRunner`` reports.
public struct RemoteCommandOutcome: Sendable, Hashable {
    /// The remote exit status (or `128 + signal` when ssh was killed).
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var duration: Duration
    /// The runner killed the command at its timeout.
    public var timedOut: Bool
    /// ssh itself failed (could not connect, authenticate, …): the command did not run.
    public var transportFailure: String?

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), stdoutTruncated: Bool = false,
                stderrTruncated: Bool = false, duration: Duration = .zero, timedOut: Bool = false,
                transportFailure: String? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.duration = duration
        self.timedOut = timedOut
        self.transportFailure = transportFailure
    }
}

/// Runs one remote shell string on a host. Production uses ``SSHCommandRunner``; tests use a fake.
///
/// Implementations must stop the command (and throw `CancellationError`) when the task is
/// cancelled, kill it at `timeout`, and keep at most `outputLimit` bytes per stream.
public protocol RemoteCommandRunner: Sendable {
    func run(
        _ remoteCommand: String,
        on host: RemoteHost,
        timeout: Duration,
        outputLimit: Int,
        output: @escaping @Sendable (CommandOutputChunk) -> Void
    ) async throws -> RemoteCommandOutcome
}

/// ``RemoteCommandRunner`` over SSHKit (system ssh, the generated ssh_config and the in-app agent).
///
/// Output is delivered live, piece by piece, as ssh reads it (up to `outputLimit` per stream).
public struct SSHCommandRunner: RemoteCommandRunner {
    public let runner: SSHRunner

    public init(runner: SSHRunner = SSHRunner()) {
        self.runner = runner
    }

    public func run(
        _ remoteCommand: String,
        on host: RemoteHost,
        timeout: Duration,
        outputLimit: Int,
        output: @escaping @Sendable (CommandOutputChunk) -> Void
    ) async throws -> RemoteCommandOutcome {
        let result: SSHResult
        do {
            result = try await runner.run(remoteCommand, on: host, stdin: nil, timeout: timeout, outputLimit: outputLimit) { stream, data in
                output(CommandOutputChunk(stream: stream == .stdout ? .stdout : .stderr, data: data))
            }
        } catch let error as SSHError {
            return RemoteCommandOutcome(exitCode: 255, transportFailure: error.errorDescription ?? "ssh failed")
        }
        return RemoteCommandOutcome(
            exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
            stdoutTruncated: result.stdoutTruncated, stderrTruncated: result.stderrTruncated,
            duration: result.duration, timedOut: result.timedOut,
            transportFailure: Self.transportFailure(result))
    }

    /// ssh failures that mean the command never ran. Exit status 255 with unrecognised stderr is
    /// reported as the command's own status: a remote `exit 255` looks exactly like that.
    static func transportFailure(_ result: SSHResult) -> String? {
        if result.timedOut { return nil }
        guard let error = result.transportError else { return nil }
        if case .other = error, result.signal == nil { return nil }
        return error.errorDescription ?? "ssh failed"
    }
}

/// The result of `run_command`. A non-zero exit code is a normal result.
public struct CommandResult: Sendable, Hashable, Codable {
    public var exitCode: Int32
    /// UTF-8 (invalid bytes replaced), terminal escapes stripped, at most 64 KB.
    public var stdout: String
    public var stderr: String
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var durationMs: Int

    public init(exitCode: Int32, stdout: String, stderr: String, stdoutTruncated: Bool, stderrTruncated: Bool, durationMs: Int) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.durationMs = durationMs
    }

    /// Bytes of output returned (after caps).
    public var outputBytes: Int { stdout.utf8.count + stderr.utf8.count }
}

/// Why a command did not produce a ``CommandResult``. Agent cancellation is a `CancellationError`.
public enum CommandExecutionError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The user stopped it in AeroOps.
    case cancelledByUser
    /// It ran longer than its timeout and was killed.
    case timedOut(seconds: Int)
    /// ssh failed before the command ran.
    case sshFailed(String)

    public var description: String {
        switch self {
        case .cancelledByUser: "The command was cancelled by the user in AeroOps."
        case .timedOut(let seconds): "The command did not finish within \(seconds) seconds and was killed."
        case .sshFailed(let message): "SSH failed: \(message)"
        }
    }
}

/// A command in flight, for the app's activity view.
public struct RunningCommand: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    public var hostName: String
    public var command: String
    public var startedAt: Date
}

/// Live events from ``CommandExecutor``.
public enum CommandActivity: Sendable, Hashable {
    case started(RunningCommand)
    case output(id: UUID, CommandOutputChunk)
    case finished(id: UUID, CommandResult)
    case failed(id: UUID, message: String)
    case cancelled(id: UUID, byUser: Bool)

    /// The command this event is about.
    public var commandID: UUID {
        switch self {
        case .started(let command): command.id
        case .output(let id, _), .finished(let id, _), .failed(let id, _), .cancelled(let id, _): id
        }
    }
}

/// Runs `run_command` calls through a ``RemoteCommandRunner``.
///
/// The command reaches the host as one quoted argument of the `Scripts/remote/run-command.sh`
/// wrapper, so the remote login shell only ever sees quoted words. The timeout is clamped to
/// 1…300 s and each output stream to 64 KB. Cancelling the calling task (agent cancel) or
/// ``cancel(_:)`` (user) kills ssh, and the wrapper's watchdog then kills the remote command's
/// process group within a few seconds, even under a ControlMaster (see ``RunCommandScript``).
public actor CommandExecutor {
    private let runner: any RemoteCommandRunner
    private let clock: any BridgeClock
    private let outputLimit: Int
    private let heartbeatSeconds: Int
    private var tasks: [UUID: Task<RemoteCommandOutcome, any Error>] = [:]
    private var commands: [UUID: RunningCommand] = [:]
    private var cancelledByUser: Set<UUID> = []
    /// Keeps every event: a dropped start or end leaves the app's view of a command wrong, and a
    /// dropped piece of output leaves a silent gap. What a slow reader can pile up stays small,
    /// since each command's output is capped per stream.
    private nonisolated let broadcaster = Broadcaster<CommandActivity>(bufferSize: nil)

    /// - Parameter heartbeatSeconds: how often the remote watchdog checks that the client is still
    ///   there; tests shorten it.
    public init(runner: any RemoteCommandRunner, clock: any BridgeClock = SystemBridgeClock(),
                outputLimit: Int = BridgeLimits.maxCommandOutputBytes, heartbeatSeconds: Int = 3) {
        self.runner = runner
        self.clock = clock
        self.outputLimit = outputLimit
        self.heartbeatSeconds = max(1, heartbeatSeconds)
    }

    /// The remote shell string for `command`:
    /// `sh -c '<run-command.sh>' aeroops-run '<command>' <deadline> <heartbeat>`.
    public nonisolated static func remoteCommand(for command: String, timeoutSeconds: Int, heartbeatSeconds: Int = 3) -> String {
        RunCommandScript.remoteCommand(command, timeoutSeconds: timeoutSeconds, heartbeatSeconds: heartbeatSeconds)
    }

    /// Live activity: starts, output chunks, results.
    public nonisolated func activity() -> AsyncStream<CommandActivity> {
        broadcaster.subscribe()
    }

    /// Commands currently running.
    public func running() -> [RunningCommand] {
        commands.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Stops a running command on the user's behalf. Returns `false` when it is not running.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        guard let task = tasks[id] else { return false }
        cancelledByUser.insert(id)
        task.cancel()
        return true
    }

    /// Runs `command` on `host`. Throws ``CommandExecutionError`` or, when the calling task is
    /// cancelled, `CancellationError`.
    public func execute(_ command: String, on host: RemoteHost, timeoutSeconds: Int, id: UUID = UUID()) async throws -> CommandResult {
        let seconds = min(max(timeoutSeconds, BridgeLimits.timeoutRange.lowerBound), BridgeLimits.timeoutRange.upperBound)
        try Task.checkCancellation()
        let remote = Self.remoteCommand(for: command, timeoutSeconds: seconds, heartbeatSeconds: heartbeatSeconds)
        let runner = runner
        let limit = outputLimit
        // Room for the heartbeat bytes, which the runner counts as stdout.
        let runnerLimit = limit + seconds / heartbeatSeconds + 8
        let broadcaster = broadcaster
        let task = Task<RemoteCommandOutcome, any Error> {
            try await runner.run(remote, on: host, timeout: .seconds(seconds), outputLimit: runnerLimit) { chunk in
                var chunk = chunk
                if chunk.stream == .stdout { chunk.data = RunCommandScript.removingHeartbeats(chunk.data) }
                if !chunk.data.isEmpty { broadcaster.yield(.output(id: id, chunk)) }
            }
        }
        let info = RunningCommand(id: id, hostID: host.id, hostName: host.name, command: command, startedAt: clock.now)
        tasks[id] = task
        commands[id] = info
        broadcaster.yield(.started(info))
        defer {
            tasks[id] = nil
            commands[id] = nil
            cancelledByUser.remove(id)
        }

        let outcome: RemoteCommandOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if cancelledByUser.contains(id) {
                broadcaster.yield(.cancelled(id: id, byUser: true))
                throw CommandExecutionError.cancelledByUser
            }
            if error is CancellationError || Task.isCancelled {
                broadcaster.yield(.cancelled(id: id, byUser: false))
                throw CancellationError()
            }
            let message = "\(error)"
            broadcaster.yield(.failed(id: id, message: message))
            throw CommandExecutionError.sshFailed(message)
        }
        if cancelledByUser.contains(id) {
            broadcaster.yield(.cancelled(id: id, byUser: true))
            throw CommandExecutionError.cancelledByUser
        }
        if let failure = outcome.transportFailure {
            broadcaster.yield(.failed(id: id, message: failure))
            throw CommandExecutionError.sshFailed(failure)
        }
        if outcome.timedOut {
            let error = CommandExecutionError.timedOut(seconds: seconds)
            broadcaster.yield(.failed(id: id, message: error.description))
            throw error
        }
        let stdout = Self.capped(RunCommandScript.removingHeartbeats(outcome.stdout), limit: limit)
        let stderr = Self.capped(outcome.stderr, limit: limit)
        let result = CommandResult(
            exitCode: outcome.exitCode,
            stdout: LogText.stripANSI(stdout.text), stderr: LogText.stripANSI(stderr.text),
            stdoutTruncated: outcome.stdoutTruncated || stdout.truncated,
            stderrTruncated: outcome.stderrTruncated || stderr.truncated,
            durationMs: max(0, outcome.duration.milliseconds))
        broadcaster.yield(.finished(id: id, result))
        return result
    }

    /// At most `limit` bytes as UTF-8 text, never splitting a character.
    static func capped(_ data: Data, limit: Int) -> (text: String, truncated: Bool) {
        guard data.count > limit else { return (String(decoding: data, as: UTF8.self), false) }
        var end = limit
        while end > 0, data[data.startIndex + end] & 0xC0 == 0x80 { end -= 1 }
        return (String(decoding: data.prefix(end), as: UTF8.self), true)
    }
}
