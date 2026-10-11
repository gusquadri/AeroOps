import AeroCore
import Foundation

/// The remote command strings behind ``DockerCollector``.
///
/// Every builder validates names with `ShellQuote.isSafeName` and quotes them with
/// `ShellQuote.quote`. Commands start with `LC_ALL=C` so error messages are not localized;
/// with `sudo: true` the head is `sudo -n docker` (never prompts, fails fast instead).
public enum DockerCommands {
    /// The line ``list(includeStopped:sudo:)`` prints between the `ps` and `stats` output.
    public static let statsMarker = "@@aero-docker-stats"
    /// Printed instead of stats output when `docker stats` fails; the list is still returned.
    public static let statsFailedMarker = "@@aero-docker-stats-failed"

    /// `docker` or `sudo -n docker`.
    public static func head(sudo: Bool) -> String {
        sudo ? "sudo -n docker" : "docker"
    }

    /// `docker ps` and `docker stats` in one round trip:
    /// `LC_ALL=C sh -c '<docker> ps -a --no-trunc --format '{{json .}}' || exit $?; echo @@aero-docker-stats; ...'`.
    ///
    /// The script exits with `docker ps`'s status when that fails; a failing `docker stats` only
    /// prints ``statsFailedMarker``.
    public static func list(includeStopped: Bool = true, sudo: Bool) -> String {
        let docker = head(sudo: sudo)
        let format = ShellQuote.quote("{{json .}}")
        let all = includeStopped ? " -a" : ""
        let script = "\(docker) ps\(all) --no-trunc --format \(format) || exit $?; "
            + "echo \(statsMarker); "
            + "\(docker) stats --no-stream --format \(format) 2>/dev/null || echo \(statsFailedMarker)"
        return RemoteShell.script(script)
    }

    /// `LC_ALL=C <docker> logs [-f] --tail <n> --timestamps [--since <s>s] '<container>' 2>&1`.
    ///
    /// stderr is merged because `docker logs` writes the container's stderr to its own stderr.
    /// `tail` is clamped to `0...LogRequest.maxTail` (0 with `follow` means only new lines).
    public static func logs(
        container: String,
        tail: Int,
        sinceSeconds: Int? = nil,
        follow: Bool = false,
        sudo: Bool
    ) throws(CollectorInputError) -> String {
        try NameCheck.require(container, field: "container")
        try NameCheck.requireSince(sinceSeconds)
        let lines = min(max(tail, 0), LogRequest.maxTail)
        var words = [RemoteShell.localePrefix, head(sudo: sudo), "logs"]
        if follow { words.append("-f") }
        words += ["--tail", String(lines), "--timestamps"]
        if let sinceSeconds { words += ["--since", "\(sinceSeconds)s"] }
        words += [ShellQuote.quote(container), "2>&1"]
        return words.joined(separator: " ")
    }

    /// `LC_ALL=C <docker> inspect --type container '<container>'`.
    public static func inspect(container: String, sudo: Bool) throws(CollectorInputError) -> String {
        try NameCheck.require(container, field: "container")
        return "\(RemoteShell.localePrefix) \(head(sudo: sudo)) inspect --type container \(ShellQuote.quote(container))"
    }

    /// The plain follow command for "Open in terminal":
    /// `<docker> logs -f --tail 100 --timestamps '<container>'` (no locale override, no
    /// watchdog: the terminal tab owns the process and Ctrl-C stops it).
    public static func terminalFollow(container: String, tail: Int = 100, sudo: Bool) throws(CollectorInputError) -> String {
        try NameCheck.require(container, field: "container")
        let lines = min(max(tail, 0), LogRequest.maxTail)
        return "\(head(sudo: sudo)) logs -f --tail \(lines) --timestamps \(ShellQuote.quote(container))"
    }

    /// Splits ``list(includeStopped:sudo:)`` output into the `ps` and `stats` parts.
    /// `statsFailed` is `true` when `docker stats` failed (rows then have no CPU or memory).
    static func splitListOutput(_ output: String) -> (ps: String, stats: String, statsFailed: Bool) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let marker = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == statsMarker }) else {
            return (output, "", false)
        }
        let ps = lines[..<marker].joined(separator: "\n")
        let rest = lines[(marker + 1)...]
        let failed = rest.contains { $0.trimmingCharacters(in: .whitespaces) == statsFailedMarker }
        let stats = rest.filter { $0.trimmingCharacters(in: .whitespaces) != statsFailedMarker }.joined(separator: "\n")
        return (ps, stats, failed)
    }
}
