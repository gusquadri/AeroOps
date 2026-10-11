import AeroCore
import AeroTestSupport
import Foundation
import SSHKit
import Testing
@testable import Collectors

/// Deterministic HostMonitor tests: a manual clock drives the schedule and a scripted runner
/// answers the polls, so no test waits for real intervals.
@Suite("HostMonitor")
struct HostMonitorTests {
    let clock = MonitorTestClock()
    let runner: MonitorTestRunner
    let host = MonitorTestHosts.make()

    init() {
        runner = MonitorTestRunner(clock: clock)
    }

    private func fixture(_ name: String) throws -> String {
        try Fixtures.string("metrics/\(name).txt")
    }

    private func makeMonitor(
        activity: MonitorActivity = .visible,
        hostKeys: HostKeyStore? = nil,
        configuration: HostMonitorConfiguration = .standard
    ) -> (HostMonitor, MonitorUpdateRecorder) {
        let monitor = HostMonitor(host: host, runner: runner, hostKeys: hostKeys, configuration: configuration, clock: clock, activity: activity)
        return (monitor, MonitorUpdateRecorder(monitor.updates))
    }

    /// Lets in-flight hops settle, then checks that nothing new was called.
    private func expectNoNewCalls(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.calls.count == count, sourceLocation: sourceLocation)
    }

    // MARK: - CPU

    @Test("The first poll has no CPU %; the second has the delta between both samples")
    func cpuDeltaAcrossPolls() async throws {
        let first = try fixture("devcontainer-1")
        let second = try fixture("devcontainer-2")
        runner.enqueue(.output(first), .output(second), for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()

        let loading = try await updates.next("loading")
        #expect(loading.status == .loading)
        let one = try await updates.next("first poll") { $0.status == .online }
        #expect(one.snapshot != nil)
        #expect(one.snapshot?.cpuPercent == nil)
        #expect(one.lastSuccessAt == MonitorTestClock.epoch)
        #expect(one.consecutiveFailures == 0)

        #expect(try await clock.nextDeadline() == .seconds(5))
        clock.advance(to: .seconds(5))
        let two = try await updates.next("second poll") { $0.status == .online }

        let firstSample = try #require(MetricsParser.parse(first).sample)
        let expected = try #require(MetricsParser.parse(second, previous: firstSample).snapshot?.cpuPercent)
        let cpu = try #require(two.snapshot?.cpuPercent)
        #expect(abs(cpu - expected) < 0.000_1)
        #expect(two.lastSuccessAt == MonitorTestClock.epoch.addingTimeInterval(5))
        #expect(runner.calls.map(\.startedAt) == [.zero, .seconds(5)])
        await monitor.stop()
    }

    @Test("A previous sample older than maxCPUSampleAge gives no CPU % instead of a long average")
    func oldSampleIsNotUsed() async throws {
        runner.enqueue(.output(try fixture("devcontainer-1")), .output(try fixture("devcontainer-2")), for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        try await updates.next("first poll") { $0.status == .online }

        monitor.setActivity(.paused)
        try await updates.next("paused") { $0.activity == .paused }
        clock.advance(by: .seconds(121))
        monitor.refresh()
        try await runner.waitForCalls(2)
        let second = try await updates.next("second poll") { $0.status == .online }
        #expect(second.snapshot?.cpuPercent == nil)
        await monitor.stop()
    }

    // MARK: - Failures

    @Test("A poll that hits the 8 s timeout makes the host stale and keeps the last snapshot")
    func staleAfterTimeout() async throws {
        runner.enqueue(.output(try fixture("devcontainer-1")), .hangUntilTimeout, for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        let online = try await updates.next("first poll") { $0.status == .online }

        clock.advance(to: .seconds(5))
        try await runner.waitForCalls(2)
        #expect(runner.calls[1].timeout == .seconds(8))
        // The only pending sleep is the runner's deadline: no poll timer while a poll runs.
        #expect(try await clock.nextDeadline() == .seconds(13))
        clock.advance(to: .seconds(13))

        let stale = try await updates.next("stale") { $0.status != .online }
        #expect(stale.status == .stale)
        #expect(stale.lastError == .timeout)
        #expect(stale.consecutiveFailures == 1)
        #expect(stale.snapshot == online.snapshot)
        #expect(stale.lastSuccessAt == online.lastSuccessAt)
        #expect(stale.message == SSHError.timeout.errorDescription)
        // 5 s after the timed-out poll started has passed: the next one keeps the 1 s minimum gap.
        #expect(try await clock.nextDeadline() == .seconds(14))
        await monitor.stop()
    }

    @Test("Three failures in a row make the host offline")
    func offlineAfterThreeFailures() async throws {
        runner.setFallback(.connectionRefused, for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()

        let first = try await updates.next("failure 1") { $0.consecutiveFailures == 1 }
        #expect(first.status == .stale)
        #expect(first.lastError == .connectionRefused)
        #expect(first.snapshot == nil)

        clock.advance(to: try await clock.nextDeadline())
        let second = try await updates.next("failure 2") { $0.consecutiveFailures == 2 }
        #expect(second.status == .stale)

        clock.advance(to: try await clock.nextDeadline())
        let third = try await updates.next("failure 3") { $0.consecutiveFailures == 3 }
        #expect(third.status == .offline)
        #expect(third.message == SSHError.connectionRefused.errorDescription)
        #expect(runner.calls.map(\.startedAt) == [.zero, .seconds(5), .seconds(10)])
        await monitor.stop()
    }

    @Test("Offline hosts back off exponentially up to 60 s; refresh retries at once")
    func backoffWhileOffline() async throws {
        runner.setFallback(.connectionRefused, for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()

        var starts: [Duration] = [.zero]
        for failures in 1...7 {
            try await updates.next("failure \(failures)") { $0.consecutiveFailures == failures }
            let due = try await clock.nextDeadline()
            if failures < 7 {
                starts.append(due)
                clock.advance(to: due)
            }
        }
        // 5 s while stale; then 10, 20, 40, 60, 60 s once offline.
        #expect(starts == [.zero, .seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(80), .seconds(140)])
        #expect(try await clock.nextDeadline() == .seconds(200))
        #expect(runner.calls.map(\.startedAt) == starts)

        // Refresh polls immediately, without waiting for the backoff.
        runner.enqueue(.output(try fixture("devcontainer-1")), for: host)
        monitor.refresh()
        let recovered = try await updates.next("recovery") { $0.status == .online }
        #expect(recovered.consecutiveFailures == 0)
        #expect(runner.calls.last?.startedAt == .seconds(140))
        // Back to the normal cadence.
        #expect(try await clock.nextDeadline() == .seconds(145))
        await monitor.stop()
    }

    @Test("A host recovers from offline: status online, failures and error cleared, CPU from the last sample")
    func recovery() async throws {
        runner.enqueue(
            .output(try fixture("devcontainer-1")),
            .connectionRefused, .connectionRefused, .connectionRefused,
            .output(try fixture("devcontainer-2")),
            for: host
        )
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        let online = try await updates.next("online") { $0.status == .online }
        for _ in 1...3 {
            clock.advance(to: try await clock.nextDeadline())
        }
        let offline = try await updates.next("offline") { $0.status == .offline }
        #expect(offline.snapshot == online.snapshot)
        #expect(offline.lastSuccessAt == online.lastSuccessAt)

        let due = try await clock.nextDeadline()
        #expect(due == .seconds(25))
        clock.advance(to: due)
        let recovered = try await updates.next("recovered") { $0.status == .online }
        #expect(recovered.consecutiveFailures == 0)
        #expect(recovered.lastError == nil)
        #expect(recovered.message == nil)
        #expect(recovered.snapshot?.cpuPercent != nil)
        #expect(recovered.lastSuccessAt == MonitorTestClock.epoch.addingTimeInterval(25))
        await monitor.stop()
    }

    @Test("Authentication failures back off from the first one (PerSourcePenalties)")
    func authFailureBacksOff() async throws {
        runner.setFallback(.authFailed, for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()

        var dues: [Duration] = []
        for failures in 1...3 {
            let update = try await updates.next("failure \(failures)") { $0.consecutiveFailures == failures }
            #expect(update.lastError == .authFailed)
            #expect(update.status == (failures < 3 ? .stale : .offline))
            let due = try await clock.nextDeadline()
            dues.append(due)
            if failures < 3 { clock.advance(to: due) }
        }
        #expect(dues == [.seconds(10), .seconds(30), .seconds(70)])
        await monitor.stop()
    }

    @Test("Truncated output and non-zero exits are failures with a readable error")
    func incompleteOutput() async throws {
        runner.enqueue(
            .output("@@kernel\nLinux 6.1\n"),
            .result(SSHResult(exitCode: 127, stderr: Data("sh: not found\n".utf8))),
            for: host
        )
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        let first = try await updates.next("failure 1") { $0.consecutiveFailures == 1 }
        #expect(first.status == .stale)
        if case .other = first.lastError {} else { Issue.record("Expected .other, got \(String(describing: first.lastError))") }

        clock.advance(to: try await clock.nextDeadline())
        let second = try await updates.next("failure 2") { $0.consecutiveFailures == 2 }
        #expect(second.lastError == .remoteCommandFailed(exitCode: 127, stderr: "sh: not found"))
        await monitor.stop()
    }

    // MARK: - Unsupported OS

    @Test("A host without /proc/stat is unsupported and polled at the background interval")
    func unsupportedOS() async throws {
        runner.enqueue(.output(try fixture("nonlinux-darwin")), for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        let update = try await updates.next("unsupported") { $0.status != .loading }
        #expect(update.status == .unsupported)
        #expect(update.snapshot == nil)
        #expect(update.lastError == nil)
        #expect(update.unsupportedSystem?.hasPrefix("Darwin") == true)
        #expect(update.message?.hasPrefix("Unsupported OS: Darwin") == true)
        #expect(update.lastSuccessAt == MonitorTestClock.epoch)
        #expect(try await clock.nextDeadline() == .seconds(30))
        await monitor.stop()
    }

    // MARK: - Overlap

    @Test("Polls never overlap: refreshes and timers during a poll queue one follow-up poll")
    func noOverlappingPolls() async throws {
        let gate = MonitorTestGate()
        runner.enqueue(.gated(gate, .output(try fixture("devcontainer-1"))), .output(try fixture("devcontainer-2")), for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        try await runner.waitForCalls(1)

        monitor.refresh()
        monitor.refresh()
        monitor.setActivity(.background)
        monitor.setActivity(.visible)
        monitor.refresh()
        clock.advance(by: .seconds(20))
        try await updates.next("activity change") { $0.activity == .background }
        try await updates.next("activity change back") { $0.activity == .visible }
        try await expectNoNewCalls(1)
        #expect(clock.pendingDeadlines.isEmpty)

        gate.open()
        try await updates.next("first poll") { $0.status == .online && $0.snapshot?.cpuPercent == nil }
        let second = try await updates.next("queued refresh") { $0.snapshot?.cpuPercent != nil }
        #expect(second.status == .online)
        #expect(runner.calls.map(\.startedAt) == [.zero, .seconds(20)])
        #expect(try await clock.nextDeadline() == .seconds(25))
        try await expectNoNewCalls(2)
        #expect(runner.maxConcurrent(for: host) == 1)
        await monitor.stop()
    }

    @Test("A poll that outlasts the interval is followed by the next one after the minimum gap")
    func slowPollKeepsMinimumGap() async throws {
        let gate = MonitorTestGate()
        runner.enqueue(.gated(gate, .output(try fixture("devcontainer-1"))), .output(try fixture("devcontainer-2")), for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        try await runner.waitForCalls(1)
        clock.advance(to: .seconds(7))
        gate.open()
        try await updates.next("first poll") { $0.status == .online }
        #expect(try await clock.nextDeadline() == .seconds(8))
        await monitor.stop()
    }

    // MARK: - Activity

    @Test("Pause stops polling; resuming polls at once when overdue; background polls every 30 s")
    func pauseAndResume() async throws {
        runner.setFallback(.output(try fixture("devcontainer-1")), for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        try await updates.next("first poll") { $0.status == .online }
        #expect(try await clock.nextDeadline() == .seconds(5))

        monitor.setActivity(.paused)
        let paused = try await updates.next("paused") { $0.activity == .paused }
        #expect(paused.status == .online)
        try await monitorEventually("the timer to be cancelled") { clock.pendingDeadlines.isEmpty }
        clock.advance(to: .seconds(60))
        try await expectNoNewCalls(1)

        monitor.setActivity(.visible)
        try await runner.waitForCalls(2)
        #expect(runner.calls[1].startedAt == .seconds(60))
        try await updates.next("second poll") { $0.status == .online && $0.activity == .visible }
        #expect(try await clock.nextDeadline() == .seconds(65))

        monitor.setActivity(.background)
        try await updates.next("background") { $0.activity == .background }
        try await monitorEventually("the background timer") { clock.pendingDeadlines == [.seconds(90)] }
        clock.advance(to: .seconds(89))
        try await expectNoNewCalls(2)
        clock.advance(to: .seconds(90))
        try await runner.waitForCalls(3)
        await monitor.stop()
    }

    @Test("A monitor started paused does not poll until resumed; refresh polls once while paused")
    func startPaused() async throws {
        runner.setFallback(.output(try fixture("devcontainer-1")), for: host)
        let (monitor, updates) = makeMonitor(activity: .paused)
        await monitor.start()
        let loading = try await updates.next("loading")
        #expect(loading.status == .loading)
        #expect(loading.activity == .paused)
        clock.advance(to: .seconds(100))
        try await expectNoNewCalls(0)

        monitor.refresh()
        try await updates.next("refreshed") { $0.status == .online }
        try await expectNoNewCalls(1)
        #expect(clock.pendingDeadlines.isEmpty)

        monitor.setActivity(.visible)
        try await monitorEventually("the visible timer") { clock.pendingDeadlines == [.seconds(105)] }
        await monitor.stop()
    }

    // MARK: - Host keys

    @Test("A host with no pinned key is held as unknown until the key is trusted")
    func hostKeyUnknown() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aero-hm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HostKeyStore(knownHostsFile: dir.appending(path: "known_hosts"))
        runner.setFallback(.output(try fixture("devcontainer-1")), for: host)
        let (monitor, updates) = makeMonitor(hostKeys: store)
        await monitor.start()

        let held = try await updates.next("held") { $0.hostKeyIssue != nil }
        #expect(held.hostKeyIssue == .unknown)
        #expect(held.status == .offline)
        #expect(held.message == HostKeyIssue.unknown.message)
        clock.advance(to: .seconds(60))
        try await expectNoNewCalls(0)
        #expect(clock.pendingDeadlines.isEmpty)

        try await store.trust(MonitorTestKeys.devKey(), for: host)
        monitor.refresh()
        let online = try await updates.next("online") { $0.status == .online }
        #expect(online.hostKeyIssue == nil)
        #expect(runner.calls.count == 1)
        #expect(try await clock.nextDeadline() == .seconds(65))
        await monitor.stop()
    }

    @Test("ssh reporting an unknown key holds the monitor too")
    func hostKeyUnknownFromSSH() async throws {
        runner.setFallback(.hostKeyUnknown, for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        let held = try await updates.next("held") { $0.hostKeyIssue != nil }
        #expect(held.hostKeyIssue == .unknown)
        #expect(held.consecutiveFailures == 0)
        clock.advance(to: .seconds(60))
        try await expectNoNewCalls(1)
        await monitor.stop()
    }

    @Test("A changed key blocks the host in the store and stops polling until unblocked")
    func hostKeyChanged() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aero-hm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HostKeyStore(knownHostsFile: dir.appending(path: "known_hosts"))
        try await store.trust(MonitorTestKeys.devKey(), for: host)
        runner.enqueue(.output(try fixture("devcontainer-1")), .hostKeyChanged, for: host)
        runner.setFallback(.output(try fixture("devcontainer-2")), for: host)
        let (monitor, updates) = makeMonitor(hostKeys: store)
        await monitor.start()
        let online = try await updates.next("online") { $0.status == .online }

        clock.advance(to: .seconds(5))
        let held = try await updates.next("held") { $0.hostKeyIssue != nil }
        guard case .changed(let block) = held.hostKeyIssue else {
            Issue.record("Expected a changed key, got \(String(describing: held.hostKeyIssue))")
            return
        }
        let pinned = try MonitorTestKeys.devKey()
        #expect(block?.pinned == [pinned])
        #expect(held.status == .offline)
        #expect(held.snapshot == online.snapshot)
        #expect(await store.isBlocked(host))
        clock.advance(to: .seconds(120))
        try await expectNoNewCalls(2)

        // Refreshing while still blocked re-reports the block without connecting.
        monitor.refresh()
        try await updates.next("still held") { $0.hostKeyIssue != nil }
        try await expectNoNewCalls(2)

        await store.unblock(host)
        monitor.refresh()
        let recovered = try await updates.next("recovered") { $0.status == .online }
        #expect(recovered.hostKeyIssue == nil)
        #expect(runner.calls.count == 3)
        await monitor.stop()
    }

    @Test("SSHRunner refusing a blocked host (thrown hostKeyChanged) holds the monitor")
    func thrownHostKeyChanged() async throws {
        runner.setFallback(.thrown(.hostKeyChanged), for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        let held = try await updates.next("held") { $0.hostKeyIssue != nil }
        #expect(held.hostKeyIssue == .changed(nil))
        await monitor.stop()
    }

    // MARK: - Lifecycle

    @Test("stop() cancels a running poll, finishes the stream and ignores later calls")
    func stopCancelsPoll() async throws {
        runner.enqueue(.gated(MonitorTestGate(), .output(try fixture("devcontainer-1"))), for: host)
        let (monitor, updates) = makeMonitor()
        await monitor.start()
        try await runner.waitForCalls(1)
        await monitor.stop()
        try await updates.waitUntilFinished()
        try await runner.waitForFinished(1)
        #expect(updates.all.map(\.status) == [.loading])

        monitor.refresh()
        monitor.setActivity(.background)
        await monitor.start()
        try await expectNoNewCalls(1)
        #expect(clock.pendingDeadlines.isEmpty)
    }
}

enum MonitorTestKeys {
    /// The dev containers' ed25519 host key (public).
    static func devKey() throws -> HostKey {
        try HostKey(type: "ssh-ed25519", base64: "AAAAC3NzaC1lZDI1NTE5AAAAIPfVoGPvXD/pnZyxb+hG6xVPXZ4tyYudnqH3H3ZcLQ1B")
    }
}
