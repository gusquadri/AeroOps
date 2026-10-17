import AeroCore
import AeroTestSupport
import Foundation
import Testing
@testable import Collectors

@MainActor
@Suite("MonitorCoordinator")
struct HostMonitorCoordinatorTests {
    let clock = MonitorTestClock()
    let runner: MonitorTestRunner
    let created = MonitorCreationLog()

    init() throws {
        runner = MonitorTestRunner(clock: clock)
    }

    private func makeCoordinator(activity: MonitorActivity = .visible) -> (MonitorCoordinator, MonitorUpdateRecorder) {
        let runner = self.runner
        let clock = self.clock
        let created = self.created
        let coordinator = MonitorCoordinator(activity: activity) { host, activity in
            let monitor = HostMonitor(host: host, runner: runner, clock: clock, activity: activity)
            created.entries.append((host, activity, monitor))
            return monitor
        }
        return (coordinator, MonitorUpdateRecorder(coordinator.updates))
    }

    private func respondOnline(_ hosts: RemoteHost...) throws {
        let output = try Fixtures.string("metrics/devcontainer-1.txt")
        for host in hosts { runner.setFallback(.output(output), for: host) }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("Adds, keeps, restarts and removes monitors to match the host list")
    func reconciliation() async throws {
        let a = MonitorTestHosts.make(name: "a", address: "10.0.0.1")
        let b = MonitorTestHosts.make(name: "b", address: "10.0.0.2")
        let c = MonitorTestHosts.make(name: "c", address: "10.0.0.3")
        try respondOnline(a, b, c)
        let (coordinator, updates) = makeCoordinator()

        coordinator.setHosts([a, b])
        #expect(coordinator.monitoredHostIDs == [a.id, b.id])
        #expect(created.entries.count == 2)
        try await updates.waitForAny("a online") { $0.hostID == a.id && $0.status == .online }
        try await updates.waitForAny("b online") { $0.hostID == b.id && $0.status == .online }
        #expect(coordinator.latestUpdate(for: a.id)?.status == .online)
        let monitorA = try #require(coordinator.monitor(for: a.id))
        let monitorB = try #require(coordinator.monitor(for: b.id))

        // Renaming and retagging keep the monitor; a new port restarts it.
        var renamedA = a
        renamedA.name = "a2"
        renamedA.tags = ["prod"]
        var movedB = b
        movedB.port = 2222
        coordinator.setHosts([renamedA, movedB, c])
        #expect(coordinator.monitor(for: a.id) === monitorA)
        let newB = try #require(coordinator.monitor(for: b.id))
        #expect(newB !== monitorB)
        #expect(newB.host.port == 2222)
        #expect(created.entries.count == 4)
        #expect(coordinator.latestUpdate(for: b.id)?.status != .online)
        try await updates.next("c online") { $0.hostID == c.id && $0.status == .online }
        try await runner.waitForCalls(1, for: c)
        try await monitorEventually("new b's first poll") { runner.calls.contains { $0.host.port == 2222 } }

        // The replaced monitor polls no more: after 5 s only the new endpoint is polled.
        // (stop() is idempotent: this returns once the coordinator's stop has taken effect.)
        await monitorB.stop()
        try await monitorEventually("timers for a, b and c") { clock.pendingDeadlines.count == 3 }
        clock.advance(to: .seconds(5))
        try await runner.waitForCalls(3, for: b)
        #expect(runner.calls(for: b).map(\.host.port) == [22, 2222, 2222])

        // User, address, key and login method changes restart too.
        for change in [\RemoteHost.user, \RemoteHost.address] as [WritableKeyPath<RemoteHost, String>] {
            var changed = renamedA
            changed[keyPath: change] += "x"
            let before = try #require(coordinator.monitor(for: a.id))
            coordinator.setHosts([changed, movedB, c])
            #expect(coordinator.monitor(for: a.id) !== before)
        }
        var keyed = renamedA
        keyed.keyId = "key-2"
        let beforeKey = try #require(coordinator.monitor(for: a.id))
        coordinator.setHosts([keyed, movedB, c])
        #expect(coordinator.monitor(for: a.id) !== beforeKey)
        var password = keyed
        password.auth = .password
        let beforeAuth = try #require(coordinator.monitor(for: a.id))
        coordinator.setHosts([password, movedB, c])
        #expect(coordinator.monitor(for: a.id) !== beforeAuth)

        // Removing hosts stops their monitors.
        coordinator.setHosts([c])
        #expect(coordinator.monitoredHostIDs == [c.id])
        #expect(coordinator.latestUpdate(for: a.id) == nil)
        #expect(coordinator.latestUpdate(for: b.id) == nil)
        // Wait until every removed or replaced monitor has stopped (stop() is idempotent).
        for entry in created.entries where entry.host.id != c.id {
            await entry.monitor.stop()
        }
        let callsAB = runner.calls.filter { $0.hostID != c.id }.count
        clock.advance(to: .seconds(60))
        try await runner.waitForCalls(3, for: c)
        try await settle()
        #expect(runner.calls.filter { $0.hostID != c.id }.count == callsAB)
        await coordinator.shutdown()
    }

    @Test("Activity changes reach every monitor, including ones added later")
    func activityFanOut() async throws {
        let a = MonitorTestHosts.make(name: "a", address: "10.0.0.1")
        let b = MonitorTestHosts.make(name: "b", address: "10.0.0.2")
        try respondOnline(a, b)
        let (coordinator, updates) = makeCoordinator()
        coordinator.setHosts([a])
        try await updates.next("a online") { $0.hostID == a.id && $0.status == .online }

        coordinator.setActivity(.paused)
        #expect(coordinator.activity == .paused)
        try await updates.next("a paused") { $0.hostID == a.id && $0.activity == .paused }
        coordinator.setHosts([a, b])
        #expect(created.entries.last?.activity == .paused)
        try await updates.next("b loading") { $0.hostID == b.id && $0.status == .loading }
        clock.advance(to: .seconds(60))
        try await settle()
        #expect(runner.calls(for: a).count == 1)
        #expect(runner.calls(for: b).isEmpty)

        coordinator.setActivity(.background)
        try await runner.waitForCalls(2, for: a)
        try await runner.waitForCalls(1, for: b)
        try await updates.next("b background") { $0.hostID == b.id && $0.activity == .background }
        try await updates.next("b online") { $0.hostID == b.id && $0.status == .online }
        await coordinator.shutdown()
    }

    @Test("refresh polls one host; refreshAll polls every host")
    func refresh() async throws {
        let a = MonitorTestHosts.make(name: "a", address: "10.0.0.1")
        let b = MonitorTestHosts.make(name: "b", address: "10.0.0.2")
        try respondOnline(a, b)
        let (coordinator, updates) = makeCoordinator(activity: .paused)
        coordinator.setHosts([a, b])
        try await updates.next("b loading") { $0.hostID == b.id && $0.status == .loading }

        coordinator.refresh(a.id)
        try await runner.waitForCalls(1, for: a)
        try await settle()
        #expect(runner.calls(for: b).isEmpty)

        coordinator.refreshAll()
        try await runner.waitForCalls(2, for: a)
        try await runner.waitForCalls(1, for: b)
        await coordinator.shutdown()
    }

    @Test("shutdown stops every monitor and finishes the merged stream")
    func shutdown() async throws {
        let gate = MonitorTestGate()
        let a = MonitorTestHosts.make(name: "a", address: "10.0.0.1")
        let b = MonitorTestHosts.make(name: "b", address: "10.0.0.2")
        try respondOnline(a)
        runner.enqueue(.gated(gate, .connectionRefused), for: b)
        let (coordinator, updates) = makeCoordinator()
        coordinator.setHosts([a, b])
        try await runner.waitForCalls(1, for: b)
        try await updates.next("a online") { $0.hostID == a.id && $0.status == .online }

        await coordinator.shutdown()
        try await updates.waitUntilFinished()
        // The in-flight poll of b was cancelled, not answered.
        #expect(!updates.all.contains { $0.hostID == b.id && $0.status != .loading })
        #expect(coordinator.monitoredHostIDs.isEmpty)

        coordinator.setHosts([a, b])
        coordinator.setActivity(.background)
        #expect(coordinator.monitoredHostIDs.isEmpty)
        clock.advance(to: .seconds(60))
        try await settle()
        #expect(runner.calls.count == 2)
    }
}

/// Monitors made by a coordinator's factory, in creation order.
@MainActor
final class MonitorCreationLog {
    var entries: [(host: RemoteHost, activity: MonitorActivity, monitor: HostMonitor)] = []
}
