import Darwin
import Dispatch
import Foundation
import Synchronization

/// What to run. `environment` is the complete environment of the child.
struct ChildSpec: Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    /// Written to the child's stdin, which is then closed. `nil` connects stdin to `/dev/null`.
    var stdin: Data?
    /// Keep stdin open after `stdin` was written, for ``ChildProcess/write(_:)``, until
    /// ``ChildProcess/closeStdin()`` or exit. Stdin is a pipe even when `stdin` is `nil`.
    var interactiveStdin = false
    /// Wall-clock limit; on expiry the whole process group gets SIGTERM, then SIGKILL.
    var timeout: Duration?
    /// Bytes kept per output stream; the rest is read and discarded.
    var outputLimit: Int = 64 * 1024
    /// Time between SIGTERM and SIGKILL.
    var killGrace: Duration = .milliseconds(500)
    /// After the child exits, how long to wait for EOF from descendants still holding its pipes.
    var drainGrace: Duration = .milliseconds(500)
}

/// How a child ended.
enum ChildTermination: Sendable, Hashable {
    case exited(Int32)
    case signaled(Int32)
}

/// Output kept up to `limit` bytes; anything beyond is counted and dropped.
struct CappedOutput: Sendable, Hashable {
    let limit: Int
    private(set) var data = Data()
    private(set) var totalBytes = 0

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var truncated: Bool { totalBytes > data.count }

    /// Returns how many leading bytes of `bytes` were kept.
    @discardableResult
    mutating func append(_ bytes: UnsafeRawBufferPointer) -> Int {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return 0 }
        totalBytes += bytes.count
        let room = min(limit - data.count, bytes.count)
        if room > 0 { data.append(base.assumingMemoryBound(to: UInt8.self), count: room) }
        return max(0, room)
    }
}

/// Splits a byte stream into lines (`\n`, with a trailing `\r` removed). Lines longer than
/// `maxLength` bytes are emitted in pieces so one runaway line cannot grow memory without bound.
package struct LineSplitter {
    package let maxLength: Int
    private var pending: [UInt8] = []

    package init(maxLength: Int) {
        self.maxLength = max(1, maxLength)
    }

    package mutating func append(_ bytes: UnsafeRawBufferPointer, emit: (String) -> Void) {
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                emitPending(emit)
            } else {
                pending.append(byte)
                if pending.count >= maxLength { emitPending(emit) }
            }
        }
    }

    /// Emits a final unterminated line, if any.
    package mutating func finish(emit: (String) -> Void) {
        if !pending.isEmpty { emitPending(emit) }
    }

    private mutating func emitPending(_ emit: (String) -> Void) {
        if pending.last == UInt8(ascii: "\r") { pending.removeLast() }
        emit(String(decoding: pending, as: UTF8.self))
        pending.removeAll(keepingCapacity: true)
    }
}

/// Everything known about a finished child.
struct ChildOutcome: Sendable {
    var pid: pid_t
    var termination: ChildTermination
    var stdout: CappedOutput
    var stderr: CappedOutput
    /// The ``ChildSpec/timeout`` expired and SSHKit killed the process group.
    var timedOut: Bool
    /// ``ChildProcess/terminate()`` was called before the child exited.
    var cancelled: Bool
    /// From spawn to exit (not including the drain grace).
    var duration: Duration
}

struct ChildLaunchError: Error, Sendable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// A child process with pipes, a timeout and reliable cleanup.
///
/// - Spawned with `posix_spawn` in its own session (`POSIX_SPAWN_SETSID`), so the child and
///   everything it forks share a process group that SSHKit can signal as a whole. ssh's own
///   ControlMaster daemon calls `setsid` itself and is not affected, which is what we want.
/// - Only stdin/stdout/stderr are inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`); signal mask and
///   dispositions are reset, so an app that ignores SIGPIPE does not pass that on to ssh.
/// - Always reaped (`waitpid`), so no zombies, and never signalled after it was reaped, so a
///   recycled pid can never be hit.
/// - All mutable state is confined to a private serial queue.
final class ChildProcess: @unchecked Sendable {
    typealias LineHandler = @Sendable (String) -> Void
    /// `isStdout`, then the bytes.
    typealias ChunkHandler = @Sendable (Bool, Data) -> Void
    typealias DataHandler = @Sendable (Data) -> Void

    enum OutputMode: Sendable {
        /// Keep stdout and stderr, each capped at ``ChildSpec/outputLimit``.
        case collect
        /// Deliver stdout line by line (on the child's queue); stderr is still collected.
        case lines(maxLength: Int, handler: LineHandler)
        /// Like ``collect``, and also hand every kept piece of either stream to `handler` as it
        /// arrives (on the child's queue). Bytes beyond the cap are neither kept nor delivered.
        case observe(handler: ChunkHandler)
        /// Hand every byte of stdout to `handler` as it arrives (on the child's queue), uncapped
        /// and not kept; stderr is still collected. For binary protocols such as SFTP.
        case stream(handler: DataHandler)
    }

    let pid: pid_t
    private let spec: ChildSpec
    private let queue: DispatchQueue
    private let completion: @Sendable (ChildOutcome) -> Void
    private let lineHandler: LineHandler?
    private let chunkHandler: ChunkHandler?
    private let dataHandler: DataHandler?
    private let startedAt: ContinuousClock.Instant
    /// `false` only in tests that report the exit themselves (``reportExitForTesting()``).
    private let watchesExit: Bool
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)

    private var stdout: CappedOutput
    private var stderr: CappedOutput
    private var splitter: LineSplitter?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdinSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var timeoutTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?
    private var stdoutOpen = true
    private var stderrOpen = true
    private var pendingStdin: Data
    private var stdinOffset = 0
    /// The parent's end of the stdin pipe, or -1 once closed (or never opened).
    private var stdinFD: Int32 = -1
    /// Close stdin as soon as everything pending was written.
    private var stdinClosing = false
    /// The write source is only armed while the pipe is full; between bursts it is suspended.
    private var stdinSourceSuspended = false
    private var termination: ChildTermination?
    private var exitedAt: ContinuousClock.Instant?
    private var terminating = false
    private var timedOut = false
    private var cancelled = false
    private var completed = false

    private init(pid: pid_t, spec: ChildSpec, mode: OutputMode, startedAt: ContinuousClock.Instant,
                 watchesExit: Bool, completion: @escaping @Sendable (ChildOutcome) -> Void) {
        self.pid = pid
        self.spec = spec
        self.queue = DispatchQueue(label: "aeroops.sshkit.child.\(pid)")
        self.completion = completion
        self.startedAt = startedAt
        self.watchesExit = watchesExit
        self.stdout = CappedOutput(limit: spec.outputLimit)
        self.stderr = CappedOutput(limit: spec.outputLimit)
        self.pendingStdin = spec.stdin ?? Data()
        var lineHandler: LineHandler?
        var chunkHandler: ChunkHandler?
        var dataHandler: DataHandler?
        switch mode {
        case .collect:
            break
        case .lines(let maxLength, let handler):
            lineHandler = handler
            splitter = LineSplitter(maxLength: maxLength)
        case .observe(let handler):
            chunkHandler = handler
        case .stream(let handler):
            dataHandler = handler
        }
        self.lineHandler = lineHandler
        self.chunkHandler = chunkHandler
        self.dataHandler = dataHandler
    }

    deinit {
        readBuffer.deallocate()
    }

    /// Starts the child. `completion` runs exactly once, on a private queue, after the child was
    /// reaped and both output pipes reached EOF (or the drain grace expired).
    ///
    /// - Parameter watchesExit: tests only; `false` leaves the exit unwatched so the test can
    ///   report it with ``reportExitForTesting()`` at a moment of its choosing.
    static func launch(
        _ spec: ChildSpec,
        mode: OutputMode = .collect,
        watchesExit: Bool = true,
        completion: @escaping @Sendable (ChildOutcome) -> Void
    ) throws(ChildLaunchError) -> ChildProcess {
        var opened: [Int32] = []
        func closeAll() { for fd in opened { close(fd) } }

        func makePipe() throws(ChildLaunchError) -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw ChildLaunchError(message: "pipe: \(Self.errorString(errno))") }
            opened += fds
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        let stdinPipe: (read: Int32, write: Int32)?
        let stdoutPipe: (read: Int32, write: Int32)
        let stderrPipe: (read: Int32, write: Int32)
        do {
            stdinPipe = spec.stdin == nil && !spec.interactiveStdin ? nil : try makePipe()
            stdoutPipe = try makePipe()
            stderrPipe = try makePipe()
        } catch {
            closeAll()
            throw error
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdinPipe {
            posix_spawn_file_actions_adddup2(&actions, stdinPipe.read, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let startedAt = ContinuousClock.now
        let status = posix_spawn(&pid, spec.executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            closeAll()
            throw ChildLaunchError(message: "\(spec.executable): \(errorString(status))")
        }

        if let stdinPipe { close(stdinPipe.read) }
        close(stdoutPipe.write)
        close(stderrPipe.write)
        for fd in [stdoutPipe.read, stderrPipe.read] + (stdinPipe.map { [$0.write] } ?? []) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        if let stdinPipe { _ = fcntl(stdinPipe.write, F_SETNOSIGPIPE, 1) }

        let child = ChildProcess(pid: pid, spec: spec, mode: mode, startedAt: startedAt, watchesExit: watchesExit,
                                 completion: completion)
        child.queue.async {
            child.start(stdin: stdinPipe?.write, stdout: stdoutPipe.read, stderr: stderrPipe.read)
        }
        return child
    }

    /// Stops the child: SIGTERM to its process group, SIGKILL after the grace period.
    /// Idempotent and safe from any thread; does nothing once the child was reaped.
    func terminate() {
        queue.async { [self] in
            guard !completed else { return }
            if termination == nil {
                cancelled = true
                beginTermination()
            } else {
                stdoutSource?.cancel()
                stderrSource?.cancel()
            }
        }
    }

    /// Queues `data` for the child's stdin (``ChildSpec/interactiveStdin``) and writes it as the
    /// pipe accepts it, in order. Dropped once stdin was closed or the child stopped reading.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard stdinFD >= 0, !stdinClosing else { return }
            if stdinOffset >= 1 << 20 {
                pendingStdin = pendingStdin.subdata(in: (pendingStdin.startIndex + stdinOffset)..<pendingStdin.endIndex)
                stdinOffset = 0
            }
            pendingStdin.append(data)
            flushStdin()
        }
    }

    /// Closes the child's stdin once everything queued was written, so it reads EOF.
    func closeStdin() {
        queue.async { [self] in
            guard stdinFD >= 0 else { return }
            stdinClosing = true
            flushStdin()
        }
    }

    /// Tests only: delivers the process source's exit report now, the way the kernel may deliver
    /// it before the exiting child is waitable.
    func reportExitForTesting() {
        queue.async { [self] in reapIfExited(exitReported: true) }
    }

    private func start(stdin: Int32?, stdout: Int32, stderr: Int32) {
        stdoutSource = makeReader(fd: stdout, isStdout: true)
        stderrSource = makeReader(fd: stderr, isStdout: false)
        if let stdin { startWriter(fd: stdin) }

        if watchesExit {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [self] in reapIfExited(exitReported: true) }
            processSource = source
            source.activate()
        }

        if let timeout = spec.timeout {
            timeoutTimer = makeTimer(after: timeout) { [self] in
                guard termination == nil else { return }
                timedOut = true
                beginTermination()
            }
        }
        reapIfExited(exitReported: false)
    }

    private func makeReader(fd: Int32, isStdout: Bool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in readAvailable(fd: fd, isStdout: isStdout) }
        source.setCancelHandler { [self] in
            close(fd)
            if isStdout {
                if let handler = lineHandler { splitter?.finish(emit: handler) }
                stdoutOpen = false
            } else {
                stderrOpen = false
            }
            finishIfDone()
        }
        source.activate()
        return source
    }

    private func readAvailable(fd: Int32, isStdout: Bool) {
        for _ in 0..<16 {
            let count = read(fd, readBuffer.baseAddress, readBuffer.count)
            if count > 0 {
                consume(UnsafeRawBufferPointer(rebasing: readBuffer[0..<count]), isStdout: isStdout)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && errno == EAGAIN {
                return
            } else {
                (isStdout ? stdoutSource : stderrSource)?.cancel()
                return
            }
        }
    }

    private func consume(_ bytes: UnsafeRawBufferPointer, isStdout: Bool) {
        let kept: Int
        if isStdout {
            if let handler = lineHandler {
                splitter?.append(bytes, emit: handler)
                return
            }
            if let dataHandler {
                dataHandler(Data(bytes))
                return
            }
            kept = stdout.append(bytes)
        } else {
            kept = stderr.append(bytes)
        }
        if let chunkHandler, kept > 0 {
            chunkHandler(isStdout, Data(UnsafeRawBufferPointer(rebasing: bytes[0..<kept])))
        }
    }

    private func startWriter(fd: Int32) {
        stdinFD = fd
        stdinClosing = !spec.interactiveStdin
        flushStdin()
    }

    /// Writes as much pending stdin as the pipe takes; arms the write source when it is full.
    private func flushStdin() {
        guard stdinFD >= 0 else { return }
        while stdinOffset < pendingStdin.count {
            let offset = stdinOffset
            let count = pendingStdin.withUnsafeBytes { raw in Darwin.write(stdinFD, raw.baseAddress! + offset, raw.count - offset) }
            if count > 0 {
                stdinOffset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && errno == EAGAIN {
                armWriter()
                return
            } else {
                pendingStdin = Data()
                stdinOffset = 0
                closeStdinFD()
                return
            }
        }
        pendingStdin = Data()
        stdinOffset = 0
        if stdinClosing {
            closeStdinFD()
        } else if let stdinSource, !stdinSourceSuspended {
            stdinSource.suspend()
            stdinSourceSuspended = true
        }
    }

    private func armWriter() {
        if let stdinSource {
            if stdinSourceSuspended {
                stdinSourceSuspended = false
                stdinSource.resume()
            }
            return
        }
        let fd = stdinFD
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in flushStdin() }
        source.setCancelHandler { close(fd) }
        stdinSource = source
        source.activate()
    }

    /// Closes stdin. With a write source the fd is closed by its cancel handler, never before.
    private func closeStdinFD() {
        guard stdinFD >= 0 else { return }
        let fd = stdinFD
        stdinFD = -1
        guard let stdinSource else {
            close(fd)
            return
        }
        if stdinSourceSuspended {
            stdinSourceSuspended = false
            stdinSource.resume()
        }
        stdinSource.cancel()
    }

    /// Reaps the child if it exited.
    ///
    /// - Parameter exitReported: the process source reported the exit (`NOTE_EXIT`, or the
    ///   synthetic one libdispatch delivers when the pid is already a zombie). The kernel posts
    ///   `NOTE_EXIT` while the child is still being torn down, *before* it becomes a waitable
    ///   zombie, and never posts it again. A `WNOHANG` check in that window sees a running child,
    ///   so the child was never reaped and the completion never ran (a hang seen under load).
    ///   After the report this therefore blocks until the child is waitable, which is
    ///   imminent. Without the report it only checks (`WNOHANG`).
    private func reapIfExited(exitReported: Bool) {
        guard termination == nil, hasExited(exitReported: exitReported) else { return }
        if terminating { killLingeringDescendants() }
        let result = reap()
        exitedAt = .now
        termination = result
        settleAfterExit()
    }

    private func hasExited(exitReported: Bool) -> Bool {
        var info = siginfo_t()
        let options = WEXITED | WNOWAIT | (exitReported ? 0 : WNOHANG)
        var peek: Int32
        repeat { peek = waitid(P_PID, id_t(pid), &info, options) } while peek != 0 && errno == EINTR
        let reapedByOther = peek != 0
        return reapedByOther || info.si_pid == pid
    }

    private func killLingeringDescendants() {
        kill(-pid, SIGKILL)
    }

    private static let statusLostToOtherReaper = ChildTermination.exited(-1)

    private func reap() -> ChildTermination {
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        guard reaped == pid else { return Self.statusLostToOtherReaper }
        let signal = status & 0x7F
        return signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
    }

    private func settleAfterExit() {
        processSource?.cancel()
        timeoutTimer?.cancel()
        killTimer?.cancel()
        closeStdinFD()
        if stdoutOpen || stderrOpen {
            let grace = cancelled ? .zero : spec.drainGrace
            drainTimer = makeTimer(after: grace) { [self] in
                stdoutSource?.cancel()
                stderrSource?.cancel()
            }
        }
        finishIfDone()
    }

    private func beginTermination() {
        guard termination == nil, !terminating else { return }
        terminating = true
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        killTimer = makeTimer(after: spec.killGrace) { [self] in
            guard termination == nil else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private func finishIfDone() {
        guard !completed, let termination, !stdoutOpen, !stderrOpen else { return }
        completed = true
        let outcome = ChildOutcome(
            pid: pid,
            termination: termination,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            cancelled: cancelled,
            duration: (exitedAt ?? .now) - startedAt
        )
        closeStdinFD()
        for source in [stdoutSource, stderrSource, stdinSource, processSource, timeoutTimer, killTimer, drainTimer] as [(any DispatchSourceProtocol)?] {
            source?.cancel()
        }
        stdoutSource = nil
        stderrSource = nil
        stdinSource = nil
        processSource = nil
        timeoutTimer = nil
        killTimer = nil
        drainTimer = nil
        completion(outcome)
    }

    private func makeTimer(after delay: Duration, handler: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay.dispatchInterval)
        timer.setEventHandler(handler: handler)
        timer.activate()
        return timer
    }

    private static func errorString(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

extension ChildProcess {
    /// Runs `spec` to completion. Cancelling the task terminates the child (process group) and
    /// throws `CancellationError` once it was reaped.
    static func run(_ spec: ChildSpec, mode: OutputMode = .collect) async throws -> ChildOutcome {
        try Task.checkCancellation()
        let box = CancellationBox()
        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChildOutcome, any Error>) in
                do {
                    let child = try launch(spec, mode: mode) { outcome in
                        continuation.resume(returning: outcome)
                    }
                    box.attach(child)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.cancel()
        }
        if outcome.cancelled { throw CancellationError() }
        return outcome
    }
}

/// Connects task cancellation to a child that may not exist yet.
private final class CancellationBox: Sendable {
    private struct State {
        var cancelled = false
        var child: ChildProcess?
    }

    private let state = Mutex(State())

    func attach(_ child: ChildProcess) {
        let cancelled = state.withLock { state in
            state.child = child
            return state.cancelled
        }
        if cancelled { child.terminate() }
    }

    func cancel() {
        let child = state.withLock { state in
            state.cancelled = true
            return state.child
        }
        child?.terminate()
    }
}

extension Duration {
    /// Clamped to what `DispatchTimeInterval` can hold.
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        if seconds < 0 { return .nanoseconds(0) }
        if seconds >= 9_000_000_000 { return .never }
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
