import AeroCore
import Foundation
import SSHKit
import Synchronization
import Testing
@testable import Collectors

// Test doubles for HostMonitor and MonitorCoordinator. Names start with `Monitor` so they do
// not collide with helpers of other collector tests in the same target.

/// Errors from the helpers' real-time safety nets (a test fails instead of hanging).
struct MonitorTestTimeout: Error, CustomStringConvertible {
    var description: String
}

/// Waits (in real time, briefly) until `condition` holds. Only bridges async hops between
/// actors and tasks; all schedule logic runs on ``MonitorTestClock``.
nonisolated(nonsending) func monitorEventually(
    _ what: @autoclosure () -> String,
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw MonitorTestTimeout(description: "Timed out waiting for \(what())") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

enum MonitorTestHosts {
    static func make(name: String = "host", address: String = "10.0.0.1", port: Int = 22, user: String = "dev", keyId: String? = nil) -> RemoteHost {
        RemoteHost(name: name, address: address, port: port, user: user, keyId: keyId)
    }
}

// MARK: - Clock

/// A manual ``MonitorClock``: time moves only through ``advance(by:)`` and ``advance(to:)``.
final class MonitorTestClock: MonitorClock {
    private struct Sleeper {
        var deadline: Duration
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var sleepers: [UUID: Sleeper] = [:]
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Duration { state.withLock { $0.now } }

    func date() -> Date {
        let now = now()
        let seconds = Double(now.components.seconds) + Double(now.components.attoseconds) / 1e18
        return Self.epoch.addingTimeInterval(seconds)
    }

    /// Deadlines of the pending sleeps, earliest first.
    var pendingDeadlines: [Duration] {
        state.withLock { $0.sleepers.values.map(\.deadline).sorted() }
    }

    func sleep(until deadline: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case resume, cancel, wait }
                let action: Action = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .cancel }
                    if deadline <= state.now { return .resume }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        advance(to: now() + duration)
    }

    func advance(to time: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = max(state.now, time)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits until a sleep is pending and returns the earliest deadline.
    func nextDeadline() async throws -> Duration {
        try await monitorEventually("a pending sleep") { !pendingDeadlines.isEmpty }
        return pendingDeadlines[0]
    }
}

// MARK: - Gate

/// A latch a scripted response waits on, so a test controls when a poll ends.
final class MonitorTestGate: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLock { state in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if isOpen { continuation.resume() }
        }
    }
}

// MARK: - Runner

/// A scripted ``HostCommandRunning``: answers each host's calls from a queue and records them.
final class MonitorTestRunner: HostCommandRunning {
    indirect enum Response: Sendable {
        /// The script ran and printed this (exit 0).
        case output(String)
        /// A full result, e.g. ssh's exit 255 with an error on stderr.
        case result(SSHResult)
        /// The runner throws (a blocked host, a launch failure).
        case thrown(SSHError)
        /// Waits on the clock until the timeout passes, then reports a timeout, like SSHRunner
        /// killing ssh at its deadline.
        case hangUntilTimeout
        /// Waits for the gate, then answers with the response.
        case gated(MonitorTestGate, Response)

        static func sshFailure(_ stderr: String) -> Response {
            .result(SSHResult(exitCode: 255, stderr: Data(stderr.utf8)))
        }

        static let connectionRefused = sshFailure("ssh: connect to host 10.0.0.1 port 22: Connection refused\r\n")
        static let authFailed = sshFailure("dev@10.0.0.1: Permission denied (publickey).\r\n")
        static let hostKeyUnknown = sshFailure("No ED25519 host key is known for [10.0.0.1]:22 and you have requested strict checking.\r\nHost key verification failed.\r\n")
        static let hostKeyChanged = sshFailure("@@@@@@@@\r\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\nHost key verification failed.\r\n")
    }

    struct Call: Sendable {
        var command: String
        var host: RemoteHost
        var hostID: RemoteHost.ID { host.id }
        var stdin: Data?
        var timeout: Duration
        var outputLimit: Int
        var startedAt: Duration
    }

    private struct State {
        var queues: [RemoteHost.ID: [Response]] = [:]
        var fallback: [RemoteHost.ID: Response] = [:]
        var calls: [Call] = []
        var active: [RemoteHost.ID: Int] = [:]
        var maxActive: [RemoteHost.ID: Int] = [:]
        var finished = 0
    }

    private let state = Mutex(State())
    private let clock: MonitorTestClock?

    /// - Parameter clock: needed for ``Response/hangUntilTimeout``.
    init(clock: MonitorTestClock? = nil) {
        self.clock = clock
    }

    /// Queues responses for the host's next calls, in order.
    func enqueue(_ responses: Response..., for host: RemoteHost) {
        state.withLock { $0.queues[host.id, default: []].append(contentsOf: responses) }
    }

    /// The answer once the host's queue is empty (default: connection refused).
    func setFallback(_ response: Response, for host: RemoteHost) {
        state.withLock { $0.fallback[host.id] = response }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var finishedCount: Int { state.withLock { $0.finished } }

    func calls(for host: RemoteHost) -> [Call] {
        state.withLock { $0.calls.filter { $0.hostID == host.id } }
    }

    /// The most polls that ever ran at once for the host.
    func maxConcurrent(for host: RemoteHost) -> Int {
        state.withLock { $0.maxActive[host.id] ?? 0 }
    }

    func waitForCalls(_ count: Int, for host: RemoteHost? = nil) async throws {
        try await monitorEventually("\(count) runner calls") {
            if let host { return calls(for: host).count >= count }
            return calls.count >= count
        }
    }

    func waitForFinished(_ count: Int) async throws {
        try await monitorEventually("\(count) finished runner calls") { finishedCount >= count }
    }

    func run(_ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration, outputLimit: Int) async throws -> SSHResult {
        let startedAt = clock?.now() ?? .zero
        let response = state.withLock { state -> Response in
            state.calls.append(Call(command: command, host: host, stdin: stdin, timeout: timeout, outputLimit: outputLimit, startedAt: startedAt))
            let active = state.active[host.id, default: 0] + 1
            state.active[host.id] = active
            state.maxActive[host.id] = max(state.maxActive[host.id] ?? 0, active)
            if var queue = state.queues[host.id], !queue.isEmpty {
                let next = queue.removeFirst()
                state.queues[host.id] = queue
                return next
            }
            return state.fallback[host.id] ?? .connectionRefused
        }
        defer {
            state.withLock { state in
                state.active[host.id, default: 1] -= 1
                state.finished += 1
            }
        }
        return try await answer(response, timeout: timeout, startedAt: startedAt)
    }

    private func answer(_ response: Response, timeout: Duration, startedAt: Duration) async throws -> SSHResult {
        switch response {
        case .output(let text):
            return SSHResult(exitCode: 0, stdout: Data(text.utf8))
        case .result(let result):
            return result
        case .thrown(let error):
            throw error
        case .hangUntilTimeout:
            guard let clock else { throw SSHError.other("MonitorTestRunner needs a clock for hangUntilTimeout") }
            try await clock.sleep(until: startedAt + timeout)
            return SSHResult(exitCode: 143, signal: nil, duration: timeout, timedOut: true)
        case .gated(let gate, let response):
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                gate.open()
            }
            try Task.checkCancellation()
            return try await answer(response, timeout: timeout, startedAt: startedAt)
        }
    }
}

// MARK: - Update recorder

/// Collects a monitor's (or coordinator's) updates so tests can wait for specific ones.
final class MonitorUpdateRecorder: Sendable {
    private struct State {
        var updates: [HostMonitorUpdate] = []
        var consumed = 0
        var finished = false
    }

    private final class Storage: Sendable {
        let state = Mutex(State())
    }

    private let storage: Storage
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<HostMonitorUpdate>) {
        let storage = Storage()
        self.storage = storage
        task = Task {
            for await update in stream {
                storage.state.withLock { $0.updates.append(update) }
            }
            storage.state.withLock { $0.finished = true }
        }
    }

    deinit { task.cancel() }

    var all: [HostMonitorUpdate] { storage.state.withLock { $0.updates } }
    var latest: HostMonitorUpdate? { storage.state.withLock { $0.updates.last } }
    var isFinished: Bool { storage.state.withLock { $0.finished } }

    /// Updates not yet returned by ``next(_:where:)``.
    var unconsumed: [HostMonitorUpdate] {
        storage.state.withLock { Array($0.updates.dropFirst($0.consumed)) }
    }

    /// Returns the first update after those already returned that matches, and marks it and
    /// everything before it as returned.
    @discardableResult
    nonisolated(nonsending) func next(
        _ what: String = "an update",
        where predicate: (HostMonitorUpdate) -> Bool = { _ in true }
    ) async throws -> HostMonitorUpdate {
        var found: HostMonitorUpdate?
        try await monitorEventually(what) {
            found = storage.state.withLock { state in
                guard let index = state.updates.indices.dropFirst(state.consumed).first(where: { predicate(state.updates[$0]) }) else { return nil }
                state.consumed = index + 1
                return state.updates[index]
            }
            return found != nil
        }
        return try #require(found)
    }

    /// Waits until any update so far (returned or not) matches, without marking anything as
    /// returned. For updates whose order relative to other hosts' updates is not fixed.
    nonisolated(nonsending) func waitForAny(_ what: String, where predicate: (HostMonitorUpdate) -> Bool) async throws {
        try await monitorEventually(what) {
            storage.state.withLock { $0.updates.contains(where: predicate) }
        }
    }

    func waitUntilFinished() async throws {
        try await monitorEventually("the stream to finish") { isFinished }
    }
}

