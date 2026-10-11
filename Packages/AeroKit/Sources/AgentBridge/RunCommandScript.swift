import AeroCore
import Foundation

/// `Scripts/remote/run-command.sh`, embedded so the app never reads it from disk at run time. A
/// test asserts the two are byte-identical.
///
/// Every `run_command` runs under this wrapper. Killing the local ssh (cancel, timeout) does not
/// stop a quiet remote command by itself: with a ControlMaster, sshd only closes the command's
/// stdout. The wrapper's watchdog writes one ``heartbeat`` byte to stdout every few seconds and
/// kills the command's whole process group (TERM, then KILL) when that write fails or the
/// deadline passes.
enum RunCommandScript {
    /// The watchdog's heartbeat on stdout: ACK (0x06). ``CommandExecutor`` removes it.
    static let heartbeat: UInt8 = 0x06
    /// Seconds between heartbeats: about the longest a quiet command outlives a cancelled call.
    static let defaultHeartbeatSeconds = 3

    static let source = #"""
    # AeroOps run_command wrapper (MCP exec tier). POSIX sh, BusyBox-compatible.
    # Usage: sh -c '<this script>' aeroops-run COMMAND DEADLINE_SECONDS HEARTBEAT_SECONDS
    #
    # Runs COMMAND with `sh -c` and exits with its status. A watchdog writes one ACK
    # byte (0x06) to stdout every HEARTBEAT_SECONDS; the client removes those bytes.
    # When that write fails (the ssh client is gone: sshd closes the channel's stdout,
    # also under a ControlMaster) or the command outlives DEADLINE_SECONDS, the
    # watchdog kills the whole process group with TERM, then KILL. sshd starts every
    # session with setsid, so that group is this command and everything it started
    # (unless something detached itself with setsid).
    # The wrapper changes no locale or environment: COMMAND runs as the user typed it.
    sh -c "$1" &
    p=$!
    ( stop() {
        trap '' TERM
        exec >/dev/null
        kill -s TERM 0 2>/dev/null
        sleep 2 </dev/null >/dev/null 2>&1
        kill -s KILL 0 2>/dev/null
        exit 0
      }
      trap stop PIPE
      t=0
      while sleep "$3" </dev/null >/dev/null 2>&1; do
        t=$((t + $3))
        printf '\006' || stop
        [ "$t" -lt "$2" ] || stop
      done ) </dev/null 2>/dev/null &
    w=$!
    wait "$p"
    s=$?
    kill "$w" 2>/dev/null
    exit "$s"

    """#

    /// The script without its comment lines, as sent to the host.
    static let body: String = source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.hasPrefix("#") }
        .joined(separator: "\n")

    /// `sh -c '<wrapper>' aeroops-run '<command>' <deadline> <heartbeat>`: the remote login shell
    /// only sees quoted words, and the command reaches `sh -c` as exactly one argument. The
    /// deadline is the timeout plus two heartbeats, a backstop for when the local side cannot
    /// kill ssh (the app crashed, the network went away).
    static func remoteCommand(_ command: String, timeoutSeconds: Int, heartbeatSeconds: Int = defaultHeartbeatSeconds) -> String {
        let heartbeat = max(1, heartbeatSeconds)
        let deadline = max(1, timeoutSeconds) + 2 * heartbeat
        return "sh -c " + ShellQuote.quote(body) + " aeroops-run " + ShellQuote.quote(command) + " \(deadline) \(heartbeat)"
    }

    /// `data` without heartbeat bytes.
    static func removingHeartbeats(_ data: Data) -> Data {
        guard data.contains(heartbeat) else { return data }
        return data.filter { $0 != heartbeat }
    }
}
