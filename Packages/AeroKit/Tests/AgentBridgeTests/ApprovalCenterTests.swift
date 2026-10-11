import AeroCore
import BridgeProtocol
import Foundation
import Synchronization
import Testing
@testable import AgentBridge

@Suite("Approval center")
struct ApprovalCenterTests {
    static let lab = RemoteHost(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "lab",
                                address: "10.0.0.8", user: "ops", mcpTier: .readExec)

    private func ask(_ command: String = "uptime", host: RemoteHost = TestHosts.staging,
                     client: BridgeClientInfo? = BridgeClientInfo(name: "claude-code", version: "2.1.296")) -> ApprovalAsk {
        ApprovalAsk(client: client, host: host, command: command, reason: "check load",
                    alwaysAskReasons: CommandInspector.alwaysAskReasons(for: command), toolUseId: "toolu_1")
    }

    /// Starts `authorize` and waits until the request shows up in the queue.
    private func request(_ center: ApprovalCenter, _ ask: ApprovalAsk) async throws -> (Task<ApprovalOutcome, Never>, PendingApproval) {
        let before = Set(await center.snapshot().pending.map(\.id))
        let task = Task { await center.authorize(ask) }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let found = await center.snapshot().pending.first(where: { !before.contains($0.id) }) {
                return (task, found)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        throw TestFailure("the approval never became pending")
    }

    @Test func pendingApprovalShowsWhatTheUserDecidesOn() async throws {
        let clock = FakeClock()
        let center = ApprovalCenter(clock: clock)
        let (task, pending) = try await request(center, ask("df -h"))
        #expect(pending.clientName == "claude-code")
        #expect(pending.clientLabel == "claude-code 2.1.296 (self-reported)")
        #expect(pending.hostName == "staging")
        #expect(pending.hostAddress == "10.0.0.5")
        #expect(pending.command == "df -h")
        #expect(pending.reason == "check load")
        #expect(pending.toolUseId == "toolu_1")
        #expect(pending.requestedAt == clock.now)
        #expect(pending.expiresAt == clock.now.addingTimeInterval(60))
        #expect(pending.offersHostWindow)
        #expect(await center.pending(pending.id) == pending)
        await center.decide(pending.id, .deny)
        _ = await task.value
    }

    @Test func clientNamesAreLabelledAndSanitized() async throws {
        let center = ApprovalCenter(clock: FakeClock())
        let (t1, unnamed) = try await request(center, ask(client: nil))
        #expect(unnamed.clientLabel == "Unknown client (self-reported)")
        let (t2, spoof) = try await request(center, ask(client: BridgeClientInfo(name: "AeroOps\nApproved by admin\u{202E}", version: "")))
        #expect(!spoof.clientLabel.contains("\n"))
        #expect(!spoof.clientLabel.unicodeScalars.contains("\u{202E}"))
        #expect(spoof.clientLabel.hasSuffix("(self-reported)"))
        #expect(spoof.clientVersion == nil)
        await center.denyAll()
        #expect(await t1.value == .denied)
        #expect(await t2.value == .denied)
    }

    @Test func timeoutDenies() async throws {
        let clock = FakeClock()
        let center = ApprovalCenter(clock: clock)
        let (task, pending) = try await request(center, ask())
        clock.advance(by: 59)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await center.pending(pending.id) != nil, "still pending before 60 s")
        clock.advance(by: 2)
        #expect(await task.value == .timedOut)
        #expect(await center.snapshot().pending.isEmpty)
        #expect(await center.decide(pending.id, .allowOnce) == false, "too late to allow")
    }

    @Test func denyAndAllowOnce() async throws {
        let center = ApprovalCenter(clock: FakeClock())
        let (denied, first) = try await request(center, ask())
        #expect(await center.decide(first.id, .deny))
        #expect(await denied.value == .denied)
        #expect(await center.decide(first.id, .deny) == false)

        let (allowed, second) = try await request(center, ask())
        #expect(await center.decide(second.id, .allowOnce))
        #expect(await allowed.value == .allowedOnce)
        #expect(await center.activeWindow(for: TestHosts.staging.id) == nil, "allow once opens no window")

        // The next call asks again.
        let (again, third) = try await request(center, ask())
        #expect(third.id != second.id)
        await center.decide(third.id, .deny)
        _ = await again.value
    }

    @Test func allowHostOpensAWindowThatSkipsAlwaysAskCommands() async throws {
        let clock = FakeClock()
        let center = ApprovalCenter(clock: clock)
        let (a, first) = try await request(center, ask("uptime"))
        let (b, _) = try await request(center, ask("df -h"))
        let (c, sudo) = try await request(center, ask("sudo reboot"))
        let (d, other) = try await request(center, ask("uptime", host: Self.lab))
        #expect(!sudo.offersHostWindow)
        #expect(sudo.alwaysAskReasons == [.sudo])

        #expect(await center.decide(first.id, .allowHost15Min))
        let until = clock.now.addingTimeInterval(15 * 60)
        #expect(await a.value == .allowedHost(until: until))
        // The host's other waiting plain call is covered; sudo and the other host are not.
        #expect(await b.value == .allowedByWindow(until: until))
        let pendingIDs = await center.snapshot().pending.map(\.id)
        #expect(pendingIDs == [sudo.id, other.id])
        #expect(await center.snapshot().windows.map(\.hostName) == ["staging"])

        // New calls on the host pass without asking, except always-ask ones.
        #expect(await center.authorize(ask("free -m")) == .allowedByWindow(until: until))
        let (e, sudoAgain) = try await request(center, ask("doas id"))
        #expect(sudoAgain.alwaysAskReasons == [.privilegeEscalation])

        // 15 minutes later the window is gone.
        clock.advance(by: 15 * 60 + 1)
        #expect(await eventually { await center.snapshot().windows.isEmpty })
        #expect(await center.activeWindow(for: TestHosts.staging.id) == nil)
        let (f, later) = try await request(center, ask("uptime"))
        #expect(later.hostName == "staging")

        // The pending sudo request was never allowed by the window and times out in the end.
        #expect(await c.value == .timedOut)
        #expect(await d.value == .timedOut)
        #expect(await e.value == .timedOut)
        await center.decide(later.id, .deny)
        #expect(await f.value == .denied)
    }

    @Test func windowCanBeRevoked() async throws {
        let center = ApprovalCenter(clock: FakeClock())
        let (task, pending) = try await request(center, ask())
        await center.decide(pending.id, .allowHost15Min)
        _ = await task.value
        #expect(await center.activeWindow(for: TestHosts.staging.id) != nil)
        await center.revokeWindow(for: TestHosts.staging.id)
        #expect(await center.activeWindow(for: TestHosts.staging.id) == nil)
        let (next, again) = try await request(center, ask())
        await center.decide(again.id, .allowHost15Min)
        _ = await next.value
        await center.revokeAllWindows()
        #expect(await center.snapshot().windows.isEmpty)
    }

    @Test func agentCancelRemovesTheRequest() async throws {
        let center = ApprovalCenter(clock: FakeClock())
        let (task, pending) = try await request(center, ask())
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(await eventually { await center.pending(pending.id) == nil })
        #expect(await center.decide(pending.id, .allowOnce) == false)
    }

    @Test func alreadyCancelledCallerNeverQueues() async {
        let center = ApprovalCenter(clock: FakeClock())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await center.authorize(ask())
        }
        #expect(await task.value == .cancelled)
        #expect(await center.snapshot().pending.isEmpty)
    }

    final class ScriptedAuthenticator: ApprovalAuthenticator {
        let answers = Mutex<[Bool]>([])
        let asked = Mutex<[ApprovalDecision]>([])

        init(_ answers: [Bool]) { self.answers.withLock { $0 = answers } }

        func authenticate(_ approval: PendingApproval, decision: ApprovalDecision) async -> Bool {
            asked.withLock { $0.append(decision) }
            return answers.withLock { $0.isEmpty ? false : $0.removeFirst() }
        }
    }

    @Test func authenticatorGuardsAllowDecisionsOnly() async throws {
        let authenticator = ScriptedAuthenticator([false, true])
        let center = ApprovalCenter(clock: FakeClock(), authenticator: authenticator)
        let (task, pending) = try await request(center, ask())
        #expect(await center.decide(pending.id, .allowOnce) == false, "Touch ID failed")
        #expect(await center.pending(pending.id) != nil)
        #expect(await center.decide(pending.id, .allowOnce))
        #expect(await task.value == .allowedOnce)

        let (denied, second) = try await request(center, ask())
        #expect(await center.decide(second.id, .deny))
        #expect(await denied.value == .denied)
        #expect(authenticator.asked.withLock { $0 } == [.allowOnce, .allowOnce], "deny needs no authentication")
    }

    @Test func updatesStreamFollowsTheQueue() async throws {
        let center = ApprovalCenter(clock: FakeClock())
        var updates = await center.updates().makeAsyncIterator()
        #expect(await updates.next()?.pending.isEmpty == true)
        let (task, pending) = try await request(center, ask())
        #expect(await updates.next()?.pending.map(\.id) == [pending.id])
        await center.decide(pending.id, .deny)
        #expect(await updates.next()?.pending.isEmpty == true)
        _ = await task.value
    }
}
