import Darwin
import Foundation

/// One process as the kernel reports it (`sysctl` `KERN_PROC`).
struct ProcessEntry: Sendable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let uid: uid_t
    /// Start time; together with `pid` it identifies a process, so a recycled PID is never
    /// mistaken for the original.
    let startSeconds: Int
    let startMicroseconds: Int32
    let isZombie: Bool

    func isSameProcess(as other: ProcessEntry) -> Bool {
        pid == other.pid && startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
    }
}

/// Read-only view of the process table.
enum ProcessTable {
    /// Every process on the system, or an empty list when `sysctl` fails.
    static func snapshot() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            // Room for processes started between the two calls.
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = buffer.count * stride
            if sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 {
                return buffer.prefix(size / stride).map(ProcessEntry.init)
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// The process with `pid`, or `nil` when it no longer exists.
    static func entry(for pid: pid_t) -> ProcessEntry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let entry = ProcessEntry(info)
        return entry.pid == pid ? entry : nil
    }

    /// `root` (when present) and all of its descendants in `table`, parents before children.
    static func tree(rootedAt root: pid_t, in table: [ProcessEntry]) -> [ProcessEntry] {
        let children = Dictionary(grouping: table, by: \.ppid)
        var result = table.filter { $0.pid == root }
        var queue = [root]
        var seen: Set<pid_t> = [root]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in children[parent] ?? [] where seen.insert(child.pid).inserted {
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    /// Whether `entry` is still running (same PID *and* start time, not a zombie).
    static func isAlive(_ entry: ProcessEntry) -> Bool {
        guard let current = Self.entry(for: entry.pid) else { return false }
        return current.isSameProcess(as: entry) && !current.isZombie
    }
}

extension ProcessEntry {
    init(_ info: kinfo_proc) {
        let start = info.kp_proc.p_un.__p_starttime
        self.init(
            pid: info.kp_proc.p_pid,
            ppid: info.kp_eproc.e_ppid,
            pgid: info.kp_eproc.e_pgid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            startSeconds: Int(start.tv_sec),
            startMicroseconds: Int32(start.tv_usec),
            isZombie: Int32(info.kp_proc.p_stat) == SZOMB
        )
    }
}

/// What ``ProcessReaper/reap(_:grace:)`` had to do.
package struct ReapReport: Sendable, Hashable {
    /// Processes that were still alive after the grace period and got SIGTERM.
    package var terminated: [pid_t] = []
    /// Processes that survived SIGTERM and got SIGKILL.
    package var killed: [pid_t] = []
    /// Processes still alive at the end (should always be empty).
    package var survivors: [pid_t] = []
}

/// Makes sure a set of processes is gone: waits `grace`, then SIGTERM, then SIGKILL.
///
/// Only processes owned by the current user are signalled (the root-owned `login` wrapper
/// exits by itself once its child is gone), and only if PID and start time still match.
enum ProcessReaper {
    static func reap(_ targets: [ProcessEntry], grace: Duration = .milliseconds(300)) -> ReapReport {
        let uid = getuid()
        var report = ReapReport()
        var pending = targets.filter { $0.uid == uid && $0.pid > 1 && $0.pid != getpid() }
        guard !pending.isEmpty else { return report }

        pending = waitForExit(pending, timeout: grace)
        guard !pending.isEmpty else { return report }

        report.terminated = pending.map(\.pid)
        signal(pending, SIGTERM)
        pending = waitForExit(pending, timeout: grace)
        guard !pending.isEmpty else { return report }

        report.killed = pending.map(\.pid)
        signal(pending, SIGKILL)
        pending = waitForExit(pending, timeout: grace)
        report.survivors = pending.map(\.pid)
        return report
    }

    private static func signal(_ entries: [ProcessEntry], _ signal: Int32) {
        for entry in entries where ProcessTable.isAlive(entry) {
            kill(entry.pid, signal)
        }
    }

    /// Polls every 10 ms until all `entries` exit or `timeout` passes; returns the survivors.
    private static func waitForExit(_ entries: [ProcessEntry], timeout: Duration) -> [ProcessEntry] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var alive = entries.filter(ProcessTable.isAlive)
        while !alive.isEmpty, clock.now < deadline {
            usleep(10_000)
            alive = alive.filter(ProcessTable.isAlive)
        }
        return alive
    }
}
