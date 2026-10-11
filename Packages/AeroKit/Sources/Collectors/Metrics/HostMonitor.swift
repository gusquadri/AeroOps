import AeroCore
import Foundation
import SSHKit

/// Polls one host's metrics on a schedule and publishes the result.
///
/// Each poll runs ``RemoteScripts/metrics`` as ``RemoteScripts/shellCommand`` through the
/// runner (over the host's ControlMaster) and parses it with `MetricsParser`, keeping the raw
/// sample for the next poll's CPU delta.
///
/// - **Schedule.** The first poll starts as soon as the monitor starts (unless paused). Then
///   every 5 s while ``MonitorActivity/visible`` and every 30 s in the ``MonitorActivity/background``,
///   counted from the start of the previous poll but never sooner than
///   ``HostMonitorConfiguration/minimumGap`` after it ended. ``MonitorActivity/paused`` stops
///   polling; switching back polls at once if a poll is overdue.
/// - **Failures.** A poll that times out (8 s) or fails makes the host ``HostStatus/stale``;
///   3 in a row make it ``HostStatus/offline``. While offline the interval doubles per failure,
///   up to 60 s. An authentication failure backs off from the first failure, because every
///   rejected login costs the Mac's address penalty time under sshd's `PerSourcePenalties`.
///   ``refresh()`` polls immediately.
/// - **Host keys.** With a `HostKeyStore`, a host with no pinned key or a blocked (changed) key
///   is not polled: the update carries a ``HostKeyIssue`` until ``refresh()`` after the user acts.
/// - **No overlap.** At most one poll per monitor runs at a time; a refresh during a poll
///   queues exactly one follow-up poll.
///
/// Control methods (``setActivity(_:)``, ``refresh()``) are synchronous and applied in call order.
/// Call ``start()`` once, and ``stop()`` when the host goes away.
public actor HostMonitor {
    /// The host being polled. A monitor never changes host: replace it when the address, port,
    /// user or key changes (``MonitorCoordinator`` does this).
    public nonisolated let host: RemoteHost
    public nonisolated let configuration: HostMonitorConfiguration
    /// Every state change, starting with ``HostStatus/loading`` on ``start()``. Single consumer;
    /// finishes after ``stop()``.
    public nonisolated let updates: AsyncStream<HostMonitorUpdate>

    private let runner: any HostCommandRunning
    private let hostKeys: HostKeyStore?
    private let clock: any MonitorClock
    private let updateContinuation: AsyncStream<HostMonitorUpdate>.Continuation
    private let commands: AsyncStream<Command>
    private let commandContinuation: AsyncStream<Command>.Continuation

    private enum Command: Sendable {
        case activity(MonitorActivity)
        case refresh
    }

    private enum PollOutcome {
        case success(MetricsSnapshot, MetricsSample)
        case unsupported(MetricsSample)
        case failure(SSHError)
        case hostKey(HostKeyIssue)
        case cancelled
    }

    private var state: HostMonitorUpdate
    private var started = false
    private var stopped = false
    private var commandTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var timerGeneration = 0
    private var pollTask: Task<Void, Never>?
    private var refreshQueued = false
    /// Whether known_hosts was found to pin a key for the host (checked again after refresh).
    private var pinsChecked = false
    private var lastPollStart: Duration?
    private var lastPollEnd: Duration?
    private var previousSample: MetricsSample?
    private var previousSampleTime: Duration = .zero

    private static let scriptInput = Data(RemoteScripts.metrics.utf8)
    private static let stderrLimit = 1024

    /// Creates a stopped monitor; call ``start()`` to begin polling.
    ///
    /// - Parameters:
    ///   - runner: `SSHRunner` in the app, sharing `hostKeys` so blocked hosts are refused.
    ///   - hostKeys: enables the host-key checks; without it only ssh's own errors are seen.
    ///   - activity: the polling mode to start in.
    public init(
        host: RemoteHost,
        runner: any HostCommandRunning,
        hostKeys: HostKeyStore? = nil,
        configuration: HostMonitorConfiguration = .standard,
        clock: any MonitorClock = SystemMonitorClock(),
        activity: MonitorActivity = .visible
    ) {
        self.host = host
        self.runner = runner
        self.hostKeys = hostKeys
        self.configuration = configuration
        self.clock = clock
        (updates, updateContinuation) = AsyncStream.makeStream(of: HostMonitorUpdate.self, bufferingPolicy: .bufferingNewest(64))
        (commands, commandContinuation) = AsyncStream.makeStream(of: Command.self)
        state = HostMonitorUpdate(hostID: host.id, activity: activity)
    }

    deinit {
        commandContinuation.finish()
        updateContinuation.finish()
        timerTask?.cancel()
        pollTask?.cancel()
        commandTask?.cancel()
    }

    // MARK: - Control

    /// The latest published state.
    public var currentUpdate: HostMonitorUpdate { state }

    /// Starts processing control calls and polls immediately unless paused. Idempotent; does
    /// nothing after ``stop()``.
    public func start() {
        guard !started, !stopped else { return }
        started = true
        let commands = self.commands
        commandTask = Task { [weak self] in
            for await command in commands {
                guard let self else { return }
                await self.handle(command)
            }
        }
        publish()
        if state.activity != .paused { beginPoll() }
    }

    /// Switches between 5 s (visible), 30 s (background) and no polling (paused). Takes effect
    /// on the pending schedule at once: becoming visible polls immediately if a poll is overdue.
    public nonisolated func setActivity(_ activity: MonitorActivity) {
        commandContinuation.yield(.activity(activity))
    }

    /// Polls now, even while paused, offline or held for a host-key issue (call it after the
    /// user trusted or replaced the key). During a running poll, one more poll follows it.
    public nonisolated func refresh() {
        commandContinuation.yield(.refresh)
    }

    /// Stops polling for good: cancels a running poll (killing its ssh), publishes nothing more
    /// and finishes ``updates``. Returns once the poll has ended.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        commandContinuation.finish()
        cancelTimer()
        let poll = pollTask
        let commandLoop = commandTask
        pollTask = nil
        commandTask = nil
        poll?.cancel()
        await poll?.value
        await commandLoop?.value
        updateContinuation.finish()
    }

    private func handle(_ command: Command) {
        guard !stopped else { return }
        switch command {
        case .activity(let activity):
            guard activity != state.activity else { return }
            state.activity = activity
            reschedule()
            publish()
        case .refresh:
            pinsChecked = false
            if pollTask != nil {
                refreshQueued = true
            } else {
                beginPoll()
            }
        }
    }

    // MARK: - Schedule

    /// Arms the timer for the next poll, or polls now if it is overdue. Does nothing while a
    /// poll runs (it reschedules when it ends), while paused, or while held for a host key.
    private func reschedule() {
        cancelTimer()
        guard !stopped, pollTask == nil, state.hostKeyIssue == nil, let delay = nextDelay() else { return }
        guard let start = lastPollStart, let end = lastPollEnd else {
            beginPoll()
            return
        }
        let due = max(start + delay, end + configuration.minimumGap)
        if due <= clock.now() {
            beginPoll()
        } else {
            armTimer(at: due)
        }
    }

    /// Start-to-start delay before the next poll, or `nil` while paused.
    private func nextDelay() -> Duration? {
        guard var interval = configuration.interval(for: state.activity) else { return nil }
        if state.status == .unsupported {
            interval = max(interval, configuration.backgroundInterval)
        }
        let failures = state.consecutiveFailures
        let exponent: Int
        if state.lastError == .authFailed {
            exponent = failures
        } else if failures >= configuration.offlineThreshold {
            exponent = failures - configuration.offlineThreshold + 1
        } else {
            return interval
        }
        let backoff = interval * (1 << min(max(exponent, 0), 16))
        return max(interval, min(backoff, configuration.maxBackoff))
    }

    private func armTimer(at deadline: Duration) {
        timerGeneration &+= 1
        let generation = timerGeneration
        let clock = self.clock
        timerTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            await self?.timerFired(generation)
        }
    }

    private func timerFired(_ generation: Int) {
        guard generation == timerGeneration, timerTask != nil else { return }
        timerTask = nil
        beginPoll()
    }

    private func cancelTimer() {
        timerGeneration &+= 1
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Polling

    private func beginPoll() {
        guard !stopped, pollTask == nil else { return }
        cancelTimer()
        refreshQueued = false
        lastPollStart = clock.now()
        pollTask = Task { [weak self] in
            await self?.performPoll()
        }
    }

    private func performPoll() async {
        let outcome = await fetch()
        guard !stopped, !Task.isCancelled else { return }
        let end = clock.now()
        lastPollEnd = end
        apply(outcome, at: end)
        pollTask = nil
        if refreshQueued {
            beginPoll()
        } else {
            reschedule()
        }
    }

    private func fetch() async -> PollOutcome {
        if let issue = await hostKeyIssue() { return .hostKey(issue) }
        let result: SSHResult
        do {
            result = try await runner.run(
                RemoteScripts.shellCommand,
                on: host,
                stdin: Self.scriptInput,
                timeout: configuration.timeout,
                outputLimit: configuration.outputLimit
            )
        } catch let error as SSHError {
            if error == .hostKeyChanged { return .hostKey(.changed(await recordChangedKey())) }
            return .failure(error)
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            return .failure(.other(String(describing: error)))
        }
        if Task.isCancelled { return .cancelled }

        if let transportError = result.transportError {
            switch transportError {
            case .hostKeyUnknown:
                return .hostKey(.unknown)
            case .hostKeyChanged:
                return .hostKey(.changed(await recordChangedKey()))
            default:
                return .failure(transportError)
            }
        }

        switch MetricsParser.parse(result.stdoutString, previous: usablePreviousSample(), sampledAt: clock.date()) {
        case .success(let snapshot, let sample):
            return .success(snapshot, sample)
        case .unsupportedOS(let sample):
            return .unsupported(sample)
        case .truncated:
            return .failure(incompleteOutputError(result))
        }
    }

    /// A blocked host, or (until a key is pinned) a host with no pinned key.
    private func hostKeyIssue() async -> HostKeyIssue? {
        guard let hostKeys else { return nil }
        if let block = await hostKeys.block(for: host) { return .changed(block) }
        guard !pinsChecked else { return nil }
        do {
            if try await hostKeys.pinnedKeys(for: host).isEmpty { return .unknown }
        } catch {
            // known_hosts unreadable: let ssh decide, and report what it says.
        }
        pinsChecked = true
        return nil
    }

    /// ssh reported a changed key: make sure the store blocks the host (``SSHRunner`` does this
    /// itself when it shares the store) and return the block for the banner.
    private func recordChangedKey() async -> HostKeyBlock? {
        guard let hostKeys else { return nil }
        if let block = await hostKeys.block(for: host) { return block }
        await hostKeys.block(host)
        return await hostKeys.block(for: host)
    }

    private func usablePreviousSample() -> MetricsSample? {
        guard let previousSample, clock.now() - previousSampleTime <= configuration.maxCPUSampleAge else { return nil }
        return previousSample
    }

    private func incompleteOutputError(_ result: SSHResult) -> SSHError {
        if result.exitCode != 0 {
            var stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.count > Self.stderrLimit { stderr = String(stderr.prefix(Self.stderrLimit)) + "…" }
            return .remoteCommandFailed(exitCode: result.exitCode, stderr: stderr)
        }
        if result.stdoutTruncated {
            return .other("The metrics output was larger than \(configuration.outputLimit) bytes.")
        }
        return .other("The metrics output was incomplete.")
    }

    private func apply(_ outcome: PollOutcome, at time: Duration) {
        switch outcome {
        case .success(let snapshot, let sample):
            previousSample = sample
            previousSampleTime = time
            state.status = .online
            state.snapshot = snapshot
            state.lastError = nil
            state.consecutiveFailures = 0
            state.lastSuccessAt = snapshot.sampledAt
            state.hostKeyIssue = nil
            state.unsupportedSystem = nil
        case .unsupported(let sample):
            previousSample = nil
            state.status = .unsupported
            state.snapshot = nil
            state.lastError = nil
            state.consecutiveFailures = 0
            state.lastSuccessAt = clock.date()
            state.hostKeyIssue = nil
            state.unsupportedSystem = sample.kernel
        case .failure(let error):
            state.consecutiveFailures += 1
            state.lastError = error
            state.status = state.consecutiveFailures >= configuration.offlineThreshold ? .offline : .stale
            state.hostKeyIssue = nil
        case .hostKey(let issue):
            state.hostKeyIssue = issue
            state.status = .offline
        case .cancelled:
            return
        }
        publish()
    }

    private func publish() {
        updateContinuation.yield(state)
    }
}
