import CTerminalPTY
import Darwin
import Foundation
internal import GhosttyTerminal

/// The program behind a ``TerminalSession``: a child process on a pseudo-terminal the app owns,
/// plus the output history that rebuilds a surface.
///
/// Surfaces use libghostty's host-managed backend and reach the process through an
/// `InMemoryTerminalSession`: key input and resizes come in through its closures, output goes
/// out through `receive`. A surface can be freed and another attached at any time. The process
/// keeps running in between and its output keeps landing in the history, which the next
/// surface gets replayed.
///
/// Output passes a ``KittyGraphicsFilter`` first: the remote program may not make this Mac read
/// local files or shared memory as images.
///
/// Threads: output, exit and replays run on `readQueue`; spawning, input and resizes on
/// `ioQueue`. `lock` guards what both queues and the callers share.
final class TerminalProcess: @unchecked Sendable {
    enum Event: Sendable {
        /// The program started as `pid`, the leader of its own session on the terminal.
        case started(pid_t)
        /// The program could not be started.
        case failed(String)
        /// The program ended: its exit status, or 128+N for signal N; `nil` when unknown.
        case exited(code: Int32?)
        /// The shell reported a new working directory (OSC 7), a path on the remote host.
        case workingDirectory(String)
        /// The live output rang the bell, sent a notification, reported progress, ...
        /// Replays never produce these.
        case output(TerminalOutputEvent)
    }

    private struct Exit: Sendable {
        var code: Int32?
        var runtimeMilliseconds: UInt64
    }

    private struct PendingReplay {
        let io: InMemoryTerminalSession
        let token: Int
        /// The terminal's size when the surface was attached: the size the program drew for.
        let programSize: InMemoryTerminalViewport?
        let since: DispatchTime
        var lastSizeAt: DispatchTime
    }

    private static let readSize = 64 << 10
    /// Unparsed output at which reading pauses (the surface parses slower than ssh delivers).
    private static let backlogHighWater = 4 << 20
    private static let backlogLowWater = 1 << 20
    /// How long output may keep coming after the program exited: a background job can hold
    /// the terminal open, so its end of file is not waited for indefinitely.
    private static let outputDrainTimeout = DispatchTimeInterval.milliseconds(300)
    /// Extra time after a replay was parsed before input reaches the program again.
    private static let replaySettleTime = DispatchTimeInterval.milliseconds(50)
    /// Gap between the two sizes of a redraw nudge, so ssh sees both.
    private static let redrawNudgeGap = DispatchTimeInterval.milliseconds(150)
    /// How long the grid size must hold before the program starts: a new tab's first sizes come
    /// while the window is still laying it out, and a remote command that reads its size
    /// straight away (`stty size`) would see a stale one.
    private static let spawnSettleTime = DispatchTimeInterval.milliseconds(100)
    /// The program starts by then even if the size keeps changing.
    private static let spawnSettleLimit = DispatchTimeInterval.seconds(1)
    /// How long a rebuilt surface's grid size must hold before the history is replayed into
    /// it, unless it is the program's size already.
    private static let replaySizeSettleTime = DispatchTimeInterval.milliseconds(100)
    /// The replay starts by then even if the size keeps changing.
    private static let replaySizeSettleLimit = DispatchTimeInterval.seconds(1)
    /// Kitty keyboard flag "report all keys as escape codes".
    private static let reportAllKeysFlag = 8

    private let spec: TerminalLaunchSpec
    private let onEvent: @Sendable (Event) -> Void
    private let readQueue = DispatchQueue(label: "aeroops.terminal.output", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "aeroops.terminal.input", qos: .userInitiated)

    // readQueue only.
    private var history = TerminalHistory()
    private var graphicsFilter = KittyGraphicsFilter()
    private var reportedWorkingDirectory: String?
    private var readBuffer = [UInt8](repeating: 0, count: TerminalProcess.readSize)
    private var reachedEndOfOutput = false
    private var reaped = false
    private var exitCode: Int32?

    // ioQueue only.
    private var writeFD: Int32 = -1
    private var viewport: InMemoryTerminalViewport?
    private var spawnAttempted = false
    /// When the first and the latest size came in, before the program started.
    private var firstSizeAt: DispatchTime?
    private var lastSizeAt = DispatchTime.now()
    /// The surface whose replay waits for its grid size.
    private var pendingReplay: PendingReplay?

    // Guarded by lock.
    private let lock = NSLock()
    private var nextToken = 0
    /// The attached surface's token: only it may write and resize.
    private var activeToken: Int?
    /// The attached surface's I/O, set once its replay is queued: output goes there.
    private var sink: InMemoryTerminalSession?
    /// Input is dropped while the terminal answers queries found in a replay.
    private var suppressesInput = false
    private var pid: pid_t = 0
    private var startedAt: UInt64 = 0
    private var readSource: (any DispatchSourceRead)?
    private var processSource: (any DispatchSourceProcess)?
    private var readPaused = false
    private var exit: Exit?
    private var terminated = false
    private var lineEditingKeys = true

    init(spec: TerminalLaunchSpec, onEvent: @escaping @Sendable (Event) -> Void) {
        self.spec = spec
        self.onEvent = onEvent
    }

    // MARK: - Surfaces

    /// A token for the next surface's I/O, passed back to every call it makes.
    func makeToken() -> Int {
        lock.withLock {
            nextToken += 1
            return nextToken
        }
    }

    /// Makes `io` the surface's I/O: replays the history into it (holding back the answers the
    /// terminal gives to queries in there), then streams live output.
    ///
    /// A replay is laid out at the grid size it is parsed at, and a rebuilt surface starts at a
    /// default size and gets its real one a moment later. Output the program placed on the
    /// screen (`top` on the main screen) lands elsewhere at another size and leaves bits
    /// behind. So the replay waits until the surface has the program's size, or until its size
    /// has held for `replaySizeSettleTime`.
    func attach(_ io: InMemoryTerminalSession, token: Int) {
        lock.withLock {
            activeToken = token
            sink = nil
            suppressesInput = true
        }
        io.setOutputBacklogHandler(highWater: Self.backlogHighWater, lowWater: Self.backlogLowWater) {
            [weak self] backlogged in
            self?.setReadPaused(backlogged, token: token)
        }
        ioQueue.async { [self] in
            // Before the program started there is nothing to replay.
            guard spawnAttempted else {
                pendingReplay = nil
                replay(into: io, token: token)
                return
            }
            let now = DispatchTime.now()
            pendingReplay = PendingReplay(io: io, token: token, programSize: viewport, since: now, lastSizeAt: now)
            ioQueue.asyncAfter(deadline: now + Self.replaySizeSettleTime) { [self] in
                replayIfSettled()
            }
        }
    }

    /// Replays into the waiting surface once its size held for `replaySizeSettleTime`. ioQueue.
    private func replayIfSettled() {
        guard let pending = pendingReplay else { return }
        let now = DispatchTime.now()
        guard now >= pending.lastSizeAt + Self.replaySizeSettleTime
            || now >= pending.since + Self.replaySizeSettleLimit else { return }
        pendingReplay = nil
        replay(into: pending.io, token: pending.token)
    }

    /// A new size for the waiting surface: replays at once if it is the program's size,
    /// else waits for it to hold. ioQueue.
    private func replaySizeChanged(_ viewport: InMemoryTerminalViewport, token: Int) {
        guard var pending = pendingReplay, pending.token == token else { return }
        if let programSize = pending.programSize,
           programSize.columns == viewport.columns, programSize.rows == viewport.rows {
            pendingReplay = nil
            replay(into: pending.io, token: token)
            return
        }
        let now = DispatchTime.now()
        pending.lastSizeAt = now
        pendingReplay = pending
        ioQueue.asyncAfter(deadline: now + Self.replaySizeSettleTime) { [self] in
            replayIfSettled()
        }
    }

    /// Replays the history into `io`, then streams live output to it.
    private func replay(into io: InMemoryTerminalSession, token: Int) {
        readQueue.async { [self] in
            let replay = history.isEmpty ? Data() : history.replay()
            // A full-screen program whose first frames were dropped draws only changes from
            // here on: make it repaint.
            let redraw = history.replayNeedsRepaint
            let (attached, exit): (Bool, Exit?) = lock.withLock {
                guard activeToken == token, !terminated else { return (false, nil) }
                sink = io
                return (true, self.exit)
            }
            guard attached else { return }
            if !replay.isEmpty {
                io.receive(replay)
            }
            if let exit {
                io.finish(exitCode: UInt32(clamping: exit.code ?? 0), runtimeMilliseconds: exit.runtimeMilliseconds)
            }
            guard !replay.isEmpty else {
                endReplay(token: token, redraw: false)
                return
            }
            let repaint = redraw && exit == nil
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                _ = io.waitForPendingOutput()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.replaySettleTime) {
                    [weak self] in
                    self?.endReplay(token: token, redraw: repaint)
                }
            }
        }
    }

    /// The surface with `token` is gone; output only goes to the history until the next attach.
    func detach(token: Int) {
        lock.withLock {
            guard activeToken == token else { return }
            activeToken = nil
            sink = nil
            suppressesInput = false
            if readPaused, let readSource {
                readPaused = false
                readSource.resume()
            }
        }
    }

    private func endReplay(token: Int, redraw: Bool) {
        let current = lock.withLock {
            guard activeToken == token else { return false }
            suppressesInput = false
            return true
        }
        if current, redraw {
            nudgeSize()
        }
    }

    private func setReadPaused(_ paused: Bool, token: Int) {
        lock.withLock {
            guard activeToken == token, paused != readPaused, let readSource else { return }
            readPaused = paused
            if paused {
                readSource.suspend()
            } else {
                readSource.resume()
            }
        }
    }

    // MARK: - Input and size

    /// Whether the program wants the macOS line-editing keys as the bytes a shell reads
    /// (Ctrl-A, Ctrl-E, Ctrl-U, Meta-b, Meta-f) rather than encoded keys: it is on the main
    /// screen and did not ask for every key as an escape code (kitty flag 8). Any thread.
    var usesLineEditingKeys: Bool {
        lock.withLock { lineEditingKeys }
    }

    /// Input from the surface (keys, pastes, answers to queries).
    func write(_ data: Data, token: Int) {
        let allowed = lock.withLock { activeToken == token && !suppressesInput && !terminated }
        guard allowed, !data.isEmpty else { return }
        writeToProgram(data)
    }

    private func writeToProgram(_ data: Data) {
        ioQueue.async { [self] in
            guard writeFD >= 0 else { return }
            data.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = Darwin.write(writeFD, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    pointer += written
                    remaining -= written
                }
            }
        }
    }

    /// The surface's grid size. The program starts once the size has settled, at that size.
    func resize(_ viewport: InMemoryTerminalViewport, token: Int) {
        guard viewport.columns > 0, viewport.rows > 0,
              lock.withLock({ activeToken == token }) else { return }
        ioQueue.async { [self] in
            replaySizeChanged(viewport, token: token)
            self.viewport = viewport
            if spawnAttempted {
                if writeFD >= 0 {
                    Self.setSize(writeFD, viewport)
                }
                return
            }
            let now = DispatchTime.now()
            if firstSizeAt == nil {
                firstSizeAt = now
            }
            lastSizeAt = now
            ioQueue.asyncAfter(deadline: now + Self.spawnSettleTime) { [self] in
                spawnIfSettled()
            }
        }
    }

    /// Starts the program at the latest size once no new size came for `spawnSettleTime`.
    private func spawnIfSettled() {
        guard !spawnAttempted, let firstSizeAt, let viewport else { return }
        let now = DispatchTime.now()
        guard now >= lastSizeAt + Self.spawnSettleTime || now >= firstSizeAt + Self.spawnSettleLimit else { return }
        spawnAttempted = true
        spawn(viewport)
    }

    /// Resizes by a row and back, which makes full-screen programs repaint (a same-size
    /// TIOCSWINSZ sends no SIGWINCH, and ssh forwards only changes).
    private func nudgeSize() {
        ioQueue.async { [self] in
            guard writeFD >= 0, var smaller = viewport, smaller.rows > 1 else { return }
            smaller.rows -= 1
            Self.setSize(writeFD, smaller)
            ioQueue.asyncAfter(deadline: .now() + Self.redrawNudgeGap) { [self] in
                guard writeFD >= 0, let viewport else { return }
                Self.setSize(writeFD, viewport)
            }
        }
    }

    private static func setSize(_ fd: Int32, _ viewport: InMemoryTerminalViewport) {
        _ = aero_pty_set_size(
            fd, viewport.rows, viewport.columns,
            UInt16(clamping: viewport.widthPixels), UInt16(clamping: viewport.heightPixels)
        )
    }

    // MARK: - Spawn

    private func spawn(_ viewport: InMemoryTerminalViewport) {
        guard !lock.withLock({ terminated }) else { return }
        guard access(spec.executable, X_OK) == 0 else {
            return fail("cannot run \(spec.executable): \(String(cString: strerror(errno)))")
        }
        var master: Int32 = -1
        let arguments = [spec.executable] + spec.arguments
        let environment = Self.environment(adding: spec.environment)
        let pid = Self.withCStrings(arguments) { argv in
            Self.withCStrings(environment) { envp in
                Self.withOptionalCString(spec.workingDirectory) { cwd in
                    aero_pty_spawn(
                        spec.executable, argv, envp, cwd, viewport.rows, viewport.columns,
                        UInt16(clamping: viewport.widthPixels), UInt16(clamping: viewport.heightPixels),
                        &master
                    )
                }
            }
        }
        guard pid > 0 else {
            return fail("cannot start \(spec.executable): \(String(cString: strerror(errno)))")
        }
        writeFD = dup(master)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        readSource.setEventHandler { [self] in
            readAvailable(master)
        }
        readSource.setCancelHandler {
            close(master)
        }
        // Keeps self alive until the child is reaped, even after the session let go.
        let processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        processSource.setEventHandler { [self] in
            reapChild(pid)
        }

        let alreadyTerminated = lock.withLock {
            self.pid = pid
            startedAt = DispatchTime.now().uptimeNanoseconds
            self.readSource = readSource
            self.processSource = processSource
            return terminated
        }
        // Before the exit source can fire, so the session hears `started` first.
        onEvent(.started(pid))
        readSource.resume()
        processSource.resume()
        // The child may have exited before the source was watching.
        readQueue.async { [self] in
            reapChild(pid)
        }
        if alreadyTerminated {
            hangUp(pid: pid)
        }
    }

    private func fail(_ message: String) {
        readQueue.async { [self] in
            deliver(Data("\(message)\r\n".utf8))
            let sink = lock.withLock {
                exit = Exit(code: nil, runtimeMilliseconds: 1)
                return self.sink
            }
            sink?.finish(exitCode: 127, runtimeMilliseconds: 1)
            onEvent(.failed(message))
        }
    }

    /// The app's environment without the variables of whatever terminal launched it, plus
    /// the terminal type and the spec's variables.
    static func environment(adding variables: [String: String]) -> [String] {
        var environment = ProcessInfo.processInfo.environment.filter { name, _ in
            !(name.hasPrefix("GHOSTTY_") || name.hasPrefix("TERM_PROGRAM") || name.hasPrefix("ITERM_")
                || ["TERMINFO", "TERMINFO_DIRS", "COLUMNS", "LINES", "TMUX", "TMUX_PANE"].contains(name))
        }
        // ssh forwards LANG and LC_* (SendEnv). A bare charset such as Terminal.app's
        // LC_CTYPE=UTF-8 is a macOS-only value that breaks the locale on Linux.
        environment = environment.filter { name, value in
            !(name == "LANG" || name.hasPrefix("LC_")) || isPortableLocale(value)
        }
        environment["TERM"] = TerminalLaunchSpec.defaultTerm
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil, environment["LC_ALL"] == nil, environment["LC_CTYPE"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        environment.merge(variables) { $1 }
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// A locale name other systems know too: `C`, `POSIX` or `language_TERRITORY[.charset]`.
    static func isPortableLocale(_ value: String) -> Bool {
        value == "C" || value == "POSIX" || value.hasPrefix("C.") || value.contains("_")
    }

    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }

    // MARK: - Output and exit (readQueue)

    private func readAvailable(_ fd: Int32) {
        let count = readBuffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            deliver(Data(readBuffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // EIO: every process on the terminal closed it.
            endOfOutput()
        }
    }

    private func deliver(_ data: Data) {
        let filtered = graphicsFilter.filter(data)
        if !filtered.replies.isEmpty, !lock.withLock({ terminated }) {
            writeToProgram(filtered.replies)
        }
        let output = filtered.output
        guard !output.isEmpty else { return }
        history.append(output)
        let lineEditing = !history.isAlternateScreenActive && history.keyboardFlags & Self.reportAllKeysFlag == 0
        let sink = lock.withLock {
            lineEditingKeys = lineEditing
            return self.sink
        }
        sink?.receive(output)
        if let directory = history.workingDirectory, directory != reportedWorkingDirectory {
            reportedWorkingDirectory = directory
            onEvent(.workingDirectory(directory))
        }
        for event in history.takeEvents() {
            onEvent(.output(event))
        }
    }

    private func endOfOutput() {
        guard !reachedEndOfOutput else { return }
        reachedEndOfOutput = true
        lock.withLock {
            if readPaused {
                readPaused = false
                readSource?.resume()
            }
            readSource?.cancel()
            readSource = nil
        }
        if reaped {
            reportExit()
        }
    }

    private func reapChild(_ pid: pid_t) {
        guard !reaped else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result != 0 else { return }
        if result == -1, errno == EINTR { return }
        reaped = true
        exitCode = result == pid ? Self.shellStatus(status) : nil
        lock.withLock {
            processSource?.cancel()
            processSource = nil
        }
        if reachedEndOfOutput {
            reportExit()
        } else {
            readQueue.asyncAfter(deadline: .now() + Self.outputDrainTimeout) { [self] in
                reportExit()
            }
        }
    }

    private func reportExit() {
        let (sink, exit): (InMemoryTerminalSession?, Exit?) = lock.withLock {
            guard self.exit == nil else { return (nil, nil) }
            let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            // At least 1 ms: libghostty treats a 0 ms run as abnormal and reports nothing.
            let exit = Exit(code: exitCode, runtimeMilliseconds: max(1, elapsed))
            self.exit = exit
            return (self.sink, exit)
        }
        guard let exit else { return }
        sink?.finish(exitCode: UInt32(clamping: exit.code ?? 0), runtimeMilliseconds: exit.runtimeMilliseconds)
        onEvent(.exited(code: exit.code))
    }

    /// What the next surface would be replayed (for tests).
    func replayData() -> Data {
        readQueue.sync { history.isEmpty ? Data() : history.replay() }
    }

    /// `waitpid` status as a shell reports it: the exit status, or 128+N for signal N.
    static func shellStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    // MARK: - End

    /// Detaches every surface, hangs up the terminal (SIGHUP to the program's process group,
    /// then the terminal closes). The child is still reaped once it exits.
    func terminate() {
        let pid: pid_t? = lock.withLock {
            guard !terminated else { return nil }
            terminated = true
            activeToken = nil
            sink = nil
            return self.pid
        }
        guard let pid, pid > 0 else { return }
        hangUp(pid: pid)
    }

    private func hangUp(pid: pid_t) {
        readQueue.async { [self] in
            // Once reaped the pid may belong to someone else.
            if !reaped {
                kill(-pid, SIGHUP)
                kill(pid, SIGHUP)
            }
            lock.withLock {
                if readPaused {
                    readPaused = false
                    readSource?.resume()
                }
                readSource?.cancel()
                readSource = nil
            }
        }
        ioQueue.async { [self] in
            if writeFD >= 0 {
                close(writeFD)
                writeFD = -1
            }
        }
    }
}
