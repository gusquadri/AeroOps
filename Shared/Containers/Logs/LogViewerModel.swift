import AeroCore
import Collectors
import Foundation
import Observation
import Synchronization

/// The Logs sheet's state for one container or pod: loads the last 500 lines, follows new ones
/// through the collectors' follow stream, and feeds ``LogTextController`` in batches.
///
/// Following runs in a detached reading task that only appends to a lock-protected inbox; a
/// main-actor flush every ``flushInterval`` moves whatever arrived into the text view in one
/// edit. Stopping cancels the reading *task*, which releases the stream and kills the local ssh
/// (the remote follow exits within a few seconds through the collectors' watchdog).
@MainActor
@Observable
final class LogViewerModel: Identifiable {
    enum Target: Hashable, Sendable {
        case container(name: String, running: Bool)
        case pod(namespace: String, name: String, containers: [PodContainerStatus])
    }

    enum Status: Hashable, Sendable {
        case idle
        case loading
        case following
        case paused
        case ended
        case failed
    }

    static let tail = LogRequest.defaultTail
    static let flushInterval = Duration.milliseconds(100)

    nonisolated let id = UUID()
    let host: RemoteHost
    let target: Target
    @ObservationIgnored let text = LogTextController()
    @ObservationIgnored private let service: ContainerService

    /// The pod container whose logs are shown; `nil` for Docker.
    private(set) var container: String?
    /// Showing the crashed previous instance (`--previous`); never followed.
    private(set) var previous: Bool
    /// Following new lines.
    private(set) var follow: Bool
    var showTimestamps = true {
        didSet { text.setShowTimestamps(showTimestamps) }
    }

    private(set) var status = Status.idle
    private(set) var issue: WorkloadIssue?
    /// A short note above the text, e.g. why previous logs are not available.
    private(set) var notice: String?
    private(set) var lineCount = 0
    private(set) var droppedLines = 0
    private(set) var matchCount = 0
    private(set) var currentMatch: Int?
    private(set) var hasSelection = false
    /// Statistics for the self-test and the footer.
    private(set) var stats = Stats()

    struct Stats: Hashable, Sendable, Codable {
        var linesReceived = 0
        var flushes = 0
        var maxFlushMilliseconds = 0.0
        var totalFlushMilliseconds = 0.0
        var maxBatch = 0
        var droppedBeforeDisplay = 0
    }

    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var inbox = LineInbox()

    init(host: RemoteHost, target: Target, service: ContainerService, container: String? = nil, previous: Bool = false) {
        self.host = host
        self.target = target
        self.service = service
        self.previous = previous
        switch target {
        case .container(_, let running):
            self.container = nil
            follow = running && !previous
        case .pod(_, _, let containers):
            let chosen = container ?? Self.defaultContainer(containers, previous: previous)
            self.container = chosen
            let state = containers.first { $0.name == chosen }
            follow = !previous && !(state?.isTerminated ?? false)
        }
        text.onSelectionChange = { [weak self] in self?.hasSelection = $0 }
        text.onMatchesChange = { [weak self] in
            guard let self else { return }
            matchCount = text.matches.count
            currentMatch = text.currentMatch
        }
    }

    var title: String {
        switch target {
        case .container(let name, _): name
        case .pod(let namespace, let name, _): "\(namespace)/\(name)"
        }
    }

    var podContainers: [PodContainerStatus] {
        if case .pod(_, _, let containers) = target { containers } else { [] }
    }

    /// `--previous` makes sense for the chosen container only after a restart.
    var canShowPrevious: Bool {
        podContainers.first { $0.name == container }?.hasPreviousInstance ?? false
    }

    var isPod: Bool { if case .pod = target { true } else { false } }

    /// Loads (and, if following, follows) from scratch. Called when the sheet appears.
    func start() {
        reload()
    }

    /// Stops reading. Called when the sheet closes; also used by the follow toggle.
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        stopFollowing()
    }

    func setFollow(_ on: Bool) {
        guard on != follow else { return }
        follow = on
        if on {
            previous = false
            reload()
        } else {
            stopFollowing()
            if status == .following || status == .loading { status = .paused }
        }
    }

    func setPrevious(_ on: Bool) {
        guard on != previous else { return }
        previous = on
        if on { follow = false }
        reload()
    }

    func setContainer(_ name: String) {
        guard name != container else { return }
        container = name
        if previous, !canShowPrevious { previous = false }
        reload()
    }

    /// Clears and loads again with the current settings.
    func reload() {
        stop()
        issue = nil
        notice = nil
        text.reset()
        syncCounts()
        if follow, !previous {
            startFollowing()
        } else {
            loadSnapshot()
        }
    }

    /// The search field's text. The sheet applies it, debounced, with ``search(_:)``.
    var searchText = ""

    /// Highlights `query` (and shows it in the search field). Re-applying the current query is
    /// a no-op: appended lines are highlighted as they arrive.
    func search(_ query: String) {
        searchText = query
        guard query != text.query else { return }
        text.setQuery(query)
    }

    func nextMatch() { text.moveMatch(forward: true) }
    func previousMatch() { text.moveMatch(forward: false) }
    func copyAll() { text.copyAll() }
    func copySelection() { text.copySelection() }

    /// The plain follow command for a terminal tab (quoted by the collectors' builders).
    var terminalCommand: String? {
        switch target {
        case .container(let name, _):
            return try? DockerCommands.terminalFollow(container: name, tail: Self.tail, sudo: host.dockerSudo)
        case .pod(let namespace, let name, _):
            return try? KubectlCommands(host: host).logs(
                pod: name, namespace: namespace, container: container, tail: Self.tail, follow: true
            )
        }
    }

    var terminalTitle: String { "logs \(title)" }

    private func request(follow: Bool) -> LogRequest {
        switch target {
        case .container(let name, _):
            LogRequest(hostId: host.id, kind: .container, name: name, tail: Self.tail, follow: follow)
        case .pod(let namespace, let name, _):
            LogRequest(
                hostId: host.id, kind: .pod, name: name, namespace: namespace, container: container,
                tail: Self.tail, previous: previous, follow: follow
            )
        }
    }

    private func loadSnapshot() {
        status = .loading
        let request = request(follow: false)
        let logs = service.logs
        let host = host
        loadTask = Task { [weak self] in
            do {
                let capped = try await logs.fetch(request, on: host)
                let lines = await Self.parse(capped.text)
                guard let self, !Task.isCancelled else { return }
                apply(snapshot: lines, truncated: capped.truncated)
            } catch {
                guard let self, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    private func apply(snapshot lines: [LogLine], truncated: Bool) {
        if lines.isEmpty {
            text.append([LogLine(info: previous ? "The previous instance wrote no log lines." : "No log lines yet.")])
        } else {
            text.append(lines)
        }
        if previous, !lines.isEmpty, lines.allSatisfy(\.isInfo) {
            notice = "kubectl could not read the previous instance's logs; the container is probably restarting. "
                + "Try again in a moment, or show the current logs."
        } else if truncated {
            notice = "Showing the last \(lines.count) lines; older output was cut."
        }
        stats.linesReceived += lines.count
        status = .paused
        syncCounts()
    }

    private func startFollowing() {
        status = .loading
        let inbox = LineInbox()
        self.inbox = inbox
        readTask = Self.read(request(follow: true), logs: service.logs, host: host, into: inbox)
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.flushInterval)
                guard !Task.isCancelled, let self else { return }
                if flush() { return }
            }
        }
    }

    private nonisolated static func read(
        _ request: LogRequest, logs: LogCollector, host: RemoteHost, into inbox: LineInbox
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            do {
                let stream = try await logs.follow(request, on: host)
                for try await line in stream {
                    inbox.append(LogLine(line))
                }
                inbox.finish(nil)
            } catch {
                inbox.finish(Task.isCancelled ? nil : error)
            }
        }
    }

    private func stopFollowing() {
        readTask?.cancel()
        readTask = nil
        flushTask?.cancel()
        flushTask = nil
        _ = flush(final: true)
    }

    /// Moves the inbox into the text view. Returns `true` once the stream has ended.
    @discardableResult
    private func flush(final: Bool = false) -> Bool {
        let drained = inbox.drain()
        if !drained.lines.isEmpty { show(drained.lines) }
        stats.droppedBeforeDisplay += drained.dropped
        if status == .loading, drained.lines.isEmpty, drained.end == nil, inbox.started {
            status = .following
        }
        syncCounts()
        guard !final, let end = drained.end else { return false }
        finishFollowing(end)
        return true
    }

    private func show(_ lines: [LogLine]) {
        let start = ContinuousClock.now
        text.append(lines)
        let elapsed = (ContinuousClock.now - start).milliseconds
        stats.flushes += 1
        stats.linesReceived += lines.count
        stats.maxBatch = max(stats.maxBatch, lines.count)
        stats.maxFlushMilliseconds = max(stats.maxFlushMilliseconds, elapsed)
        stats.totalFlushMilliseconds += elapsed
        if status == .loading { status = .following }
    }

    private func finishFollowing(_ end: LineInbox.End) {
        switch end {
        case .finished:
            text.append([LogLine(info: "The log stream ended (the container stopped or the connection closed).")])
            status = .ended
        case .failed(let error):
            fail(error)
        }
        follow = false
        syncCounts()
    }

    private func fail(_ error: any Error) {
        guard let issue = WorkloadIssue.from(error, host: host) else { return }
        if previous, case .noPreviousContainer? = error as? KubectlError {
            notice = issue.hint
            text.append([LogLine(info: issue.title)])
            status = .paused
        } else {
            self.issue = issue
            status = .failed
        }
        syncCounts()
    }

    private func syncCounts() {
        lineCount = text.lineCount
        droppedLines = text.droppedLines + stats.droppedBeforeDisplay
    }

    @concurrent
    private nonisolated static func parse(_ text: String) async -> [LogLine] {
        guard !text.isEmpty else { return [] }
        var body = Substring(text)
        if body.hasSuffix("\n") { body = body.dropLast() }
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { LogLine(String($0)) }
    }

    /// The most-restarted container for previous logs; else the crash-looping one, else the first.
    private static func defaultContainer(_ containers: [PodContainerStatus], previous: Bool) -> String? {
        if previous {
            return containers.max { $0.restartCount < $1.restartCount }?.name
        }
        return (containers.first { $0.waitingReason == "CrashLoopBackOff" } ?? containers.first)?.name
    }

    #if DEBUG
    /// Self-test only: pushes `count` synthetic lines through the same inbox and flush path as
    /// a real follow, from a background task, at about `perSecond` lines per second.
    func injectSyntheticLines(count: Int, perSecond: Int) async {
        let inbox = inbox
        let batch = max(1, perSecond / 100)
        await Task.detached(priority: .userInitiated) {
            var sent = 0
            while sent < count, !Task.isCancelled {
                for index in 0..<min(batch, count - sent) {
                    let stamp = "2026-10-11T12:00:00.000000000Z"
                    inbox.append(LogLine("\(stamp) synthetic line \(sent + index) level=INFO request_id=\(sent + index) msg=\"burst\""))
                }
                sent += batch
                try? await Task.sleep(for: .milliseconds(10))
            }
        }.value
    }
    #endif
}

/// Lines received by the reading task, waiting for the next main-actor flush. Keeps at most
/// twice the text view's cap; anything older would be trimmed on display anyway.
final class LineInbox: Sendable {
    enum End: Sendable {
        case finished
        case failed(any Error)
    }

    private struct State {
        var lines: [LogLine] = []
        var dropped = 0
        var end: End?
        var started = false
    }

    private let state = Mutex(State())
    private static let limit = LogTextController.maxLines

    func append(_ line: LogLine) {
        state.withLock { state in
            state.started = true
            state.lines.append(line)
            if state.lines.count > 2 * Self.limit {
                let drop = state.lines.count - Self.limit
                state.lines.removeFirst(drop)
                state.dropped += drop
            }
        }
    }

    /// `nil` error means the stream finished normally (or was cancelled).
    func finish(_ error: (any Error)?) {
        state.withLock { state in
            state.started = true
            state.end = error.map { .failed($0) } ?? .finished
        }
    }

    var started: Bool { state.withLock { $0.started } }

    func drain() -> (lines: [LogLine], dropped: Int, end: End?) {
        state.withLock { state in
            let result = (state.lines, state.dropped, state.end)
            state.lines = []
            state.dropped = 0
            return result
        }
    }
}

extension Duration {
    /// The duration in milliseconds, as a `Double`.
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
