import AeroCore
import Foundation
import SSHKit

/// Streams the lines of a remote `docker logs -f` / `kubectl logs -f` and stops the remote
/// process when the consumer stops listening.
///
/// Cancelling the consuming task, or releasing the stream, kills the local ssh process. (Only
/// breaking out of a `for try await` loop while still holding the stream does not: the stream
/// ends when the consuming task is cancelled or the stream is released.)
///
/// Killing the local ssh does not by itself stop the remote command. With a ControlMaster the
/// master answers a dead mux client with `eow@openssh.com` plus `CLOSE`, and OpenSSH's sshd then
/// closes the command's stdout pipe but neither its stderr pipe nor the command. A command that
/// keeps writing to stdout dies of `SIGPIPE`; a quiet one (a container that logs nothing) would
/// block forever and leak. So the command runs under a small watchdog
/// (``watchdogScript(_:heartbeatSeconds:)``) that writes one ``heartbeat`` byte to stdout every
/// few seconds and kills the command as soon as that write fails. The client drops the byte.
enum LogFollowStream {
    /// Default seconds between watchdog heartbeats: the longest a quiet remote command outlives
    /// a cancelled follow.
    static let heartbeatSeconds = 3
    /// The watchdog's heartbeat on stdout: ACK (0x06), a C0 control that never shows in a log
    /// line. It carries no newline, so it joins the next output line and is removed there.
    static let heartbeat: Unicode.Scalar = "\u{06}"
    /// Lines kept to classify a failure when the command printed its error on stdout (`2>&1`).
    static let recentLineLimit = 20
    /// Lines buffered for a slow consumer before the oldest are dropped.
    static let bufferedLines = 10_000

    /// Wraps `command` (one simple command, already quoted) in a POSIX `sh` script that runs it
    /// in the background and kills it when the ssh channel's stdout closes.
    ///
    /// The heartbeat must go to stdout: under a ControlMaster sshd closes only that pipe when
    /// the client goes away (see the type's documentation). `sleep` gets `/dev/null` for every
    /// descriptor so it never holds the channel open. Exit status is the command's.
    static func watchdogScript(_ command: String, heartbeatSeconds: Int = heartbeatSeconds) -> String {
        let interval = max(1, heartbeatSeconds)
        return """
        \(command) &
        p=$!
        ( trap 'kill $p 2>/dev/null; exit 0' PIPE
          while sleep \(interval) </dev/null >/dev/null 2>&1; do
            printf '\\006' || { kill $p 2>/dev/null; exit 0; }
          done ) </dev/null 2>/dev/null &
        w=$!
        wait $p
        s=$?
        kill $w 2>/dev/null
        exit $s
        """
    }

    /// The full remote command for following `command`: `LC_ALL=C sh -c '<watchdog script>'`.
    static func remoteCommand(_ command: String, heartbeatSeconds: Int = heartbeatSeconds) -> String {
        RemoteShell.script(watchdogScript(command, heartbeatSeconds: heartbeatSeconds))
    }

    /// Starts following and returns ANSI-stripped lines.
    ///
    /// - Parameters:
    ///   - command: the follow command (a simple command, e.g. `LC_ALL=C docker logs -f ... 2>&1`).
    ///   - classify: turns the error text of a failed command (stderr, or the last lines of output
    ///     when stderr is empty) into a typed error such as ``AeroCore/DockerError``.
    /// - Returns: a stream that finishes when the remote command exits 0, throws the classified
    ///   error when it exits non-zero, and throws `SSHError` when ssh fails.
    static func start(
        _ command: String,
        on host: RemoteHost,
        runner: any RemoteCommandRunning,
        heartbeatSeconds: Int = heartbeatSeconds,
        classify: @escaping @Sendable (String) -> any Error
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let inner = try await runner.stream(
            remoteCommand(command, heartbeatSeconds: heartbeatSeconds),
            on: host,
            stdin: nil,
            timeout: nil,
            maxBufferedLines: bufferedLines
        )
        let (outer, continuation) = AsyncThrowingStream<String, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferedLines)
        )
        let pump = Task {
            var recent: [String] = []
            do {
                for try await line in inner {
                    for clean in cleanLines(line) {
                        recent.append(clean)
                        if recent.count > recentLineLimit { recent.removeFirst(recent.count - recentLineLimit) }
                        continuation.yield(clean)
                    }
                }
                continuation.finish()
            } catch SSHError.remoteCommandFailed(_, let stderr) {
                let text = stderr.allSatisfy(\.isWhitespace) ? recent.joined(separator: "\n") : stderr
                continuation.finish(throwing: classify(text))
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        return outer
    }

    /// One ssh output line, ANSI-stripped and without ``heartbeat`` bytes (`LogText.stripANSI`
    /// drops C0 controls). A line of heartbeats only (the unterminated tail left when the
    /// command exits) yields nothing. `stripANSI` turns a carriage return into a line break, so
    /// `a\rb` becomes two lines and a trailing `\r` disappears.
    static func cleanLines(_ line: String) -> [String] {
        if !line.isEmpty, line.unicodeScalars.allSatisfy({ $0 == heartbeat }) { return [] }
        var pieces = LogText.stripANSI(line).split(separator: "\n", omittingEmptySubsequences: false)
        if pieces.count > 1, pieces.last?.isEmpty == true { pieces.removeLast() }
        return pieces.map(String.init)
    }
}
