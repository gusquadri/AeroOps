#if DEBUG
import AeroCore
import AppKit
import Collectors
import Darwin
import Foundation
import KeyAgent
import SSHKit

/// `-AeroSelfTest phase3`: proves Phase 3's "Done when" in the built app, without clicking, against
/// the dev servers (`docker compose -f dev/compose.yml up -d`, the OrbStack VM from `dev/vm`).
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest phase3 \
///   -AeroSelfTestOutput /tmp/aeroops-phase3.json \
///   -AeroSelfTestAuthorizeScript dev/add-key.sh \   # authorizes the new .pub on every dev server
///   [-AeroSelfTestRevokeScript dev/remove-key.sh] \ # default: remove-key.sh next to the authorize script
///   [-AeroSelfTestKeepRoot YES]
/// ```
///
/// Runs under ``Phase2SelfTest``'s temporary root and Keychain service. Hosts: `dev@localhost:2222`,
/// `dev@localhost:2223` (BusyBox), `dev@aeroops-vm.orb.local:22`, and `127.0.0.1:1` (closed port,
/// with a made-up pinned key so the monitor really tries to connect).
///
/// Steps: generate an Ed25519 key (no Touch ID) → authorize it → bring the main window forward →
/// add the hosts → trust each first-contact key through ``MonitorService/requestHostKeyTrust(for:)``
/// (automatic only here) → wait for numbers, a CPU figure and the closed port going offline →
/// Refresh → a simulated sleep (no polls) and wake (immediate poll) → a simulated changed host key
/// (held, banner) and re-trust (polled again) → shutdown → delete the key, revoke it, remove the root.
///
/// Pass: each real host shows numbers within 10 s of process launch and a CPU figure by its second
/// sample; the closed port is offline within 30 s of being added. An authentication failure ends the
/// run at once (sshd's PerSourcePenalties would ban this Mac on repeated failures). Writes a JSON
/// report and exits 0 on success, 1 otherwise.
@MainActor
struct Phase3SelfTest {
    private static var defaults: UserDefaults { .standard }
    static var isRequested: Bool { defaults.string(forKey: "AeroSelfTest") == "phase3" }
    static var revokeScript: URL? {
        if let path = defaults.string(forKey: "AeroSelfTestRevokeScript") { return URL(filePath: path) }
        return Phase2SelfTest.authorizeScript?.deletingLastPathComponent().appending(path: "remove-key.sh")
    }

    static let numbersDeadline: TimeInterval = 10
    static let offlineDeadline: TimeInterval = 30
    static let waitLimit: TimeInterval = 40

    let model: AppModel

    // MARK: - Report

    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    struct HostResult: Codable {
        var name: String
        var endpoint: String
        var expectsNumbers: Bool
        /// Seconds from adding the host until the first update said the key is unknown.
        var hostKeyUnknownAfter: Double?
        /// Seconds from adding the host until its first-contact keys were pinned.
        var trustedAfter: Double?
        /// Seconds from adding the host until the card had numbers.
        var firstNumbersAfterAdd: Double?
        /// The same moment measured from process launch.
        var firstNumbersAfterLaunch: Double?
        var firstCPUAfterAdd: Double?
        var firstCPUAfterLaunch: Double?
        /// Which successful sample (1-based) first carried a CPU figure.
        var firstCPUSample: Int?
        var offlineAfterAdd: Double?
        var samples = 0
        var status = ""
        var message: String?
        var lastError: String?
        var kernel: String?
        var cpuPercent: Double?
        var memoryPercent: Double?
        var diskPercent: Double?
        var mounts = 0
        var swapTotalBytes: Int64?
    }

    struct Report: Codable {
        var ok = false
        var root = ""
        var launchedAt: Date?
        var servicesStartedAfterLaunch: Double?
        var hostsAddedAfterLaunch: Double?
        var activity = ""
        /// The activity the window rule chose before any override.
        var activityByWindowRule = ""
        var activityOverride = false
        var appActive = false
        var mainWindowVisible = false
        var mainWindows: [String] = []
        var hosts: [HostResult] = []
        var refreshAllSeconds: Double?
        var pausedPollsDuringSleep: Int?
        var wakeRefreshSeconds: Double?
        var changedKeyHeldSeconds: Double?
        var retrustedOnlineSeconds: Double?
        var authFailed = false
        var privateKeyMaterialFound: [String] = []
        var steps: [Step] = []
    }

    /// Collects every coalesced batch the dashboard applies, with times.
    @MainActor
    private final class Tracker {
        struct Entry {
            let host: RemoteHost
            let expectsNumbers: Bool
            var addedAt = Date.distantFuture
            var unknownAt: Date?
            var trustedAt: Date?
            var trustStarted = false
            var offered: [HostKey] = []
            var firstNumbersAt: Date?
            var firstCPUAt: Date?
            var firstCPUSample: Int?
            var offlineAt: Date?
            var sampleTimes: Set<Date> = []
            var lastSampleAt: Date?
            var latest: HostMonitorUpdate?
        }

        var entries: [RemoteHost.ID: Entry] = [:]
        var authFailure: String?
        var onUnknownKey: ((RemoteHost) -> Void)?

        func receive(_ updates: [HostMonitorUpdate]) {
            let now = Date.now
            for update in updates {
                guard var entry = entries[update.hostID] else { continue }
                entry.latest = update
                if update.hostKeyIssue == .unknown, entry.unknownAt == nil {
                    entry.unknownAt = now
                }
                if let snapshot = update.snapshot {
                    if entry.firstNumbersAt == nil { entry.firstNumbersAt = now }
                    if entry.sampleTimes.insert(snapshot.sampledAt).inserted {
                        entry.lastSampleAt = now
                    }
                    if snapshot.cpuPercent != nil, entry.firstCPUAt == nil {
                        entry.firstCPUAt = now
                        entry.firstCPUSample = entry.sampleTimes.count
                    }
                }
                if update.status == .offline, update.hostKeyIssue == nil, entry.offlineAt == nil {
                    entry.offlineAt = now
                }
                if update.lastError == .authFailed, authFailure == nil {
                    authFailure = "\(entry.host.name): \(SSHError.authFailed.localizedDescription)"
                }
                let needsTrust = update.hostKeyIssue == .unknown && !entry.trustStarted
                if needsTrust { entry.trustStarted = true }
                entries[update.hostID] = entry
                if needsTrust { onUnknownKey?(entry.host) }
            }
        }

        func samples(_ id: RemoteHost.ID) -> Int { entries[id]?.sampleTimes.count ?? 0 }
    }

    private final class Recorder {
        var report = Report()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            report.steps.append(Step(name: name, ok: ok, detail: detail))
            print("[selftest] \(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }
    }

    // MARK: - Run

    func runAndQuit() async {
        let report = await run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(report) {
                try? data.write(to: url, options: .atomic)
            }
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED")")
        if report.ok {
            NSApp.terminate(nil)
        } else {
            // Services are already shut down; skip the quit path so the exit status reports failure.
            exit(1)
        }
    }

    func run() async -> Report {
        let r = Recorder()
        let ssh = model.ssh
        let launchedAt = Self.processStartDate()
        r.report.root = Phase2SelfTest.root.path(percentEncoded: false)
        r.report.launchedAt = launchedAt
        r.report.servicesStartedAfterLaunch = launchedAt.map { Self.rounded(Date.now.timeIntervalSince($0)) }

        guard case .running = ssh.agentStatus, model.monitoring.isRunning else {
            r.step("services", false, "agent \(ssh.agentStatus), monitoring running \(model.monitoring.isRunning)")
            return await finish(r, key: nil)
        }
        r.step("services", true, "agent running, monitoring started")

        // 1. Key: Ed25519 in the self-test Keychain service, policy "always" (no Touch ID).
        let key: SSHKeyRecord
        do {
            key = try await ssh.generateKey(.ed25519, name: "AeroOps phase 3 self-test", policy: .always)
        } catch {
            r.step("generate key", false, error.localizedDescription)
            return await finish(r, key: nil)
        }
        r.step("generate key", true, "\(key.algorithm.displayName) \(key.fingerprint)")

        // 2. Authorize it on every dev server.
        let pub = ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
        if let script = Phase2SelfTest.authorizeScript {
            let (status, output) = await Phase2SelfTest.runProcess(script, arguments: [pub.path(percentEncoded: false)])
            r.step("authorize key", status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
            guard status == 0 else { return await finish(r, key: key) }
        } else {
            r.step("authorize key", true, "skipped: no -AeroSelfTestAuthorizeScript (key must already be authorized)")
        }

        // 3. Hosts. The closed port gets a made-up pinned key: otherwise its monitor would hold it
        //    for first contact (ssh-keyscan fails) and never try to connect.
        let keyID = key.id.uuidString
        let hosts: [(RemoteHost, Bool)] = [
            (RemoteHost(name: "Dev container", address: "localhost", port: 2222, user: "dev", keyId: keyID), true),
            (RemoteHost(name: "Alpine BusyBox", address: "localhost", port: 2223, user: "dev", keyId: keyID), true),
            (RemoteHost(name: "OrbStack VM", address: "aeroops-vm.orb.local", port: 22, user: "dev", keyId: keyID), true),
            (RemoteHost(name: "Closed port", address: "127.0.0.1", port: 1, user: "dev", keyId: keyID), false),
        ]
        let closed = hosts[3].0
        do {
            try await ssh.trust([SampleHostKeys.ed25519(seed: 31)], for: closed, replacingPinned: false)
        } catch {
            r.step("pin closed-port key", false, error.localizedDescription)
            return await finish(r, key: key)
        }

        // 4. Activity: the main window in front and the app active means 5 s polls.
        await bringMainWindowForward(r)

        // 5. Watch the dashboard's batches; trust first-contact keys as the sheet's Trust would.
        let tracker = Tracker()
        for (host, expectsNumbers) in hosts {
            tracker.entries[host.id] = Tracker.Entry(host: host, expectsNumbers: expectsNumbers)
        }
        let monitoring = model.monitoring
        tracker.onUnknownKey = { host in
            Task { @MainActor in
                await monitoring.requestHostKeyTrust(for: host)
                guard let request = monitoring.trustRequest, request.id == host.id else { return }
                tracker.entries[host.id]?.offered = request.offered
                do {
                    try await monitoring.trust(request)
                    tracker.entries[host.id]?.trustedAt = .now
                } catch {
                    print("[selftest] trust \(host.name) failed: \(error.localizedDescription)")
                }
            }
        }
        monitoring.didApplyUpdates = { tracker.receive($0) }
        defer { monitoring.didApplyUpdates = nil }

        let addedAt = Date.now
        do {
            for (host, _) in hosts {
                try model.addHost(host)
                tracker.entries[host.id]?.addedAt = .now
            }
            model.selection = nil
        } catch {
            r.step("add hosts", false, error.localizedDescription)
            return await finish(r, key: key)
        }
        r.report.hostsAddedAfterLaunch = launchedAt.map { Self.rounded(addedAt.timeIntervalSince($0)) }
        let rejected = hosts.compactMap { ssh.configRejections[$0.0.id].map { "\($0)" } }
        r.step("add hosts", rejected.isEmpty, rejected.isEmpty ? "\(hosts.count) hosts monitored" : "rejected: \(rejected)")

        // 6. Wait for numbers, CPU and offline (or an auth failure, which ends the run at once).
        let real = hosts.filter(\.1).map(\.0)
        await waitUntil(seconds: Self.waitLimit) {
            tracker.authFailure != nil
                || (real.allSatisfy { tracker.entries[$0.id]?.firstCPUAt != nil } && tracker.entries[closed.id]?.offlineAt != nil)
        }
        r.report.hosts = hosts.map { result(for: $0.0, tracker: tracker, launchedAt: launchedAt) }
        if let failure = tracker.authFailure {
            r.report.authFailed = true
            r.step("authentication", false, "\(failure); stopping now (sshd PerSourcePenalties)")
            return await finish(r, key: key)
        }
        checkTimings(r, tracker: tracker, real: real, closed: closed, launchedAt: launchedAt)
        checkDisplayStates(r, hosts: hosts.map(\.0))

        let online = real.filter { tracker.entries[$0.id]?.firstNumbersAt != nil }
        guard !online.isEmpty else { return await finish(r, key: key) }

        // 7. Refresh (⌘R): every online host samples again at once.
        try? await Task.sleep(for: .seconds(1))
        let refreshStart = (Date.now, online.map { tracker.samples($0.id) })
        model.refreshAll()
        let refreshed = await waitUntil(seconds: 4) {
            zip(online, refreshStart.1).allSatisfy { tracker.samples($0.id) > $1 }
        }
        r.report.refreshAllSeconds = Self.rounded(Date.now.timeIntervalSince(refreshStart.0))
        r.step("refresh all", refreshed, "new samples from \(online.count) hosts in \(r.report.refreshAllSeconds ?? 0) s")

        // 8. Sleep pauses polling; wake polls at once.
        await checkSleepAndWake(r, tracker: tracker, online: online)

        // 9. Changed host key: held without contacting the host, banner shown; re-trust resumes it.
        if let host = online.first, let offered = tracker.entries[host.id]?.offered, !offered.isEmpty {
            await checkChangedKey(r, host: host, realKeys: offered, tracker: tracker)
        } else {
            r.step("changed host key", false, "no trusted host to test with")
        }

        r.report.hosts = hosts.map { result(for: $0.0, tracker: tracker, launchedAt: launchedAt) }
        return await finish(r, key: key)
    }

    // MARK: - Checks

    private func bringMainWindowForward(_ r: Recorder) async {
        NSApp.activate()
        let windows = NSApp.windows.filter(MonitorService.isMainWindow)
        windows.first?.makeKeyAndOrderFront(nil)
        r.report.mainWindows = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") visible=\($0.isVisible)" }
        await waitUntil(seconds: 3) { model.monitoring.activity == .visible }
        r.report.appActive = NSApp.isActive
        r.report.mainWindowVisible = MonitorService.mainWindowIsVisible()
        r.report.activityByWindowRule = "\(model.monitoring.activity)"
        if model.monitoring.activity != .visible {
            // Launched from a shell, macOS may keep another app active. The schedule under test
            // is the visible one, so force it and say so in the report.
            model.monitoring.activityOverride = .visible
            r.report.activityOverride = true
        }
        r.report.activity = "\(model.monitoring.activity)"
        r.step(
            "activity", model.monitoring.activity == .visible,
            "\(model.monitoring.activity); app active \(NSApp.isActive), main window visible \(r.report.mainWindowVisible)"
                + (r.report.activityOverride ? "; window rule chose \(r.report.activityByWindowRule), forced visible" : "")
        )
    }

    private func checkTimings(_ r: Recorder, tracker: Tracker, real: [RemoteHost], closed: RemoteHost, launchedAt: Date?) {
        for host in real {
            let result = r.report.hosts.first { $0.endpoint == Self.endpoint(host) }
            let fromLaunch = result?.firstNumbersAfterLaunch
            let fromAdd = result?.firstNumbersAfterAdd
            let numbersOK = (fromLaunch ?? fromAdd).map { $0 <= Self.numbersDeadline } ?? false
            r.step(
                "numbers \(host.name)", numbersOK,
                "after launch \(Self.text(fromLaunch)) s, after add \(Self.text(fromAdd)) s (limit \(Int(Self.numbersDeadline)) s)"
                    + (result?.lastError.map { "; last error: \($0)" } ?? "")
            )
            let cpuSample = result?.firstCPUSample
            r.step(
                "cpu \(host.name)", cpuSample.map { $0 <= 2 } ?? false,
                "first CPU on sample \(cpuSample.map(String.init) ?? "-"), after add \(Self.text(result?.firstCPUAfterAdd)) s"
            )
        }
        let offline = r.report.hosts.first { $0.endpoint == Self.endpoint(closed) }?.offlineAfterAdd
        r.step(
            "offline \(closed.name)", offline.map { $0 <= Self.offlineDeadline } ?? false,
            "offline after \(Self.text(offline)) s (limit \(Int(Self.offlineDeadline)) s)"
        )
    }

    /// The per-host state the cards read agrees with what the monitors sent.
    private func checkDisplayStates(_ r: Recorder, hosts: [RemoteHost]) {
        var problems: [String] = []
        for host in hosts {
            let state = model.displayState(for: host.id)
            let result = r.report.hosts.first { $0.endpoint == Self.endpoint(host) }
            if result?.firstNumbersAfterAdd != nil, state.metrics == nil {
                problems.append("\(host.name): no metrics on the card")
            }
            if host.port == 1, state.status != .offline || state.message == nil {
                problems.append("\(host.name): card shows \(state.status), message \(state.message ?? "nil")")
            }
        }
        r.step("cards", problems.isEmpty, problems.isEmpty ? "display states match the monitors" : problems.joined(separator: "; "))
    }

    private func checkSleepAndWake(_ r: Recorder, tracker: Tracker, online: [RemoteHost]) async {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        let paused = await waitUntil(seconds: 2) { model.monitoring.activity == .paused }
        try? await Task.sleep(for: .seconds(1.5))  // let a poll already in flight land
        let before = online.map { tracker.samples($0.id) }
        try? await Task.sleep(for: .seconds(7))  // longer than the 5 s visible interval
        let during = zip(online, before).reduce(0) { $0 + tracker.samples($1.0.id) - $1.1 }
        r.report.pausedPollsDuringSleep = during
        r.step("sleep pauses", paused && during == 0, "activity \(model.monitoring.activity), new samples while asleep \(during)")

        let wakeStart = (Date.now, online.map { tracker.samples($0.id) })
        workspace.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        let woke = await waitUntil(seconds: 4) {
            zip(online, wakeStart.1).allSatisfy { tracker.samples($0.id) > $1 }
        }
        r.report.wakeRefreshSeconds = Self.rounded(Date.now.timeIntervalSince(wakeStart.0))
        r.step(
            "wake refreshes", woke && model.monitoring.activity == .visible,
            "activity \(model.monitoring.activity), new samples from \(online.count) hosts in \(r.report.wakeRefreshSeconds ?? 0) s"
        )
    }

    private func checkChangedKey(_ r: Recorder, host: RemoteHost, realKeys: [HostKey], tracker: Tracker) async {
        let ssh = model.ssh
        // A real mismatch can't be provoked while the ControlMaster is open (ssh only checks the
        // key on a new connection), so block the host the way SSHRunner does when ssh reports one.
        await ssh.hostKeys.block(host, offered: [SampleHostKeys.ed25519(seed: 32)])
        let start = Date.now
        model.refresh(host.id)
        let held = await waitUntil(seconds: 4) {
            if case .changed = tracker.entries[host.id]?.latest?.hostKeyIssue { model.hostKeyBlock(for: host.id) != nil } else { false }
        }
        r.report.changedKeyHeldSeconds = Self.rounded(Date.now.timeIntervalSince(start))
        let samplesWhileHeld = tracker.samples(host.id)
        try? await Task.sleep(for: .seconds(6))
        let polled = tracker.samples(host.id) - samplesWhileHeld
        r.step(
            "changed host key", held && polled == 0 && model.displayState(for: host.id).hostKeyIssue != nil,
            "held \(held) after \(r.report.changedKeyHeldSeconds ?? 0) s, banner block \(model.hostKeyBlock(for: host.id) != nil), samples while held \(polled)"
        )

        let before = tracker.samples(host.id)
        let retrust = Date.now
        do {
            try await ssh.trust(realKeys, for: host, replacingPinned: true)
        } catch {
            return r.step("re-trust", false, error.localizedDescription)
        }
        let resumed = await waitUntil(seconds: 6) {
            tracker.samples(host.id) > before && model.displayState(for: host.id).status == .online
        }
        r.report.retrustedOnlineSeconds = Self.rounded(Date.now.timeIntervalSince(retrust))
        r.step(
            "re-trust", resumed && model.hostKeyBlock(for: host.id) == nil && model.displayState(for: host.id).hostKeyIssue == nil,
            "online again after \(r.report.retrustedOnlineSeconds ?? 0) s, banner cleared \(model.hostKeyBlock(for: host.id) == nil)"
        )
    }

    // MARK: - Finish

    private func finish(_ r: Recorder, key: SSHKeyRecord?) async -> Report {
        let ssh = model.ssh
        let paths = ssh.paths
        if let key {
            let secret = try? KeychainSecretStore(service: Phase2SelfTest.keychainService).load(for: key.id)
            let roots = [Phase2SelfTest.root, AeroPaths.standard.dotDirectory]
            let found = roots.flatMap { Phase2SelfTest.filesContainingKeyMaterial(under: $0, secret: secret) }
            r.report.privateKeyMaterialFound = found
            r.step("no private key on disk", found.isEmpty, found.isEmpty ? "checked \(roots.map { $0.path(percentEncoded: false) })" : "found: \(found)")
        }

        let closed = await model.shutdownServices()
        let socketGone = !FileManager.default.fileExists(atPath: paths.agentSocket.path(percentEncoded: false))
        r.step("shutdown", socketGone && !model.monitoring.isRunning, "monitoring stopped, masters closed \(closed), agent socket removed \(socketGone)")

        if let key {
            let pub = paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
            // Revoke before deleting: the script reads the .pub.
            if let script = Self.revokeScript, Phase2SelfTest.authorizeScript != nil {
                let (status, output) = await Phase2SelfTest.runProcess(script, arguments: [pub.path(percentEncoded: false)])
                r.step("revoke key", status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do {
                try await ssh.deleteKey(key.id)
                let remaining = try KeychainSecretStore(service: Phase2SelfTest.keychainService).load(for: key.id)
                r.step("delete key", remaining == nil, "Keychain item removed \(remaining == nil)")
            } catch {
                r.step("delete key", false, error.localizedDescription)
            }
        }
        if !Phase2SelfTest.keepsRoot {
            try? FileManager.default.removeItem(at: Phase2SelfTest.root)
        }
        r.report.ok = !r.report.steps.isEmpty && r.report.steps.allSatisfy(\.ok)
        return r.report
    }

    // MARK: - Helpers

    private func result(for host: RemoteHost, tracker: Tracker, launchedAt: Date?) -> HostResult {
        let entry = tracker.entries[host.id]
        let added = entry?.addedAt ?? .now
        func since(_ start: Date?, _ date: Date?) -> Double? {
            guard let start, let date else { return nil }
            return Self.rounded(date.timeIntervalSince(start))
        }
        let latest = entry?.latest
        let snapshot = latest?.snapshot
        return HostResult(
            name: host.name,
            endpoint: Self.endpoint(host),
            expectsNumbers: entry?.expectsNumbers ?? false,
            hostKeyUnknownAfter: since(added, entry?.unknownAt),
            trustedAfter: since(added, entry?.trustedAt),
            firstNumbersAfterAdd: since(added, entry?.firstNumbersAt),
            firstNumbersAfterLaunch: since(launchedAt, entry?.firstNumbersAt),
            firstCPUAfterAdd: since(added, entry?.firstCPUAt),
            firstCPUAfterLaunch: since(launchedAt, entry?.firstCPUAt),
            firstCPUSample: entry?.firstCPUSample,
            offlineAfterAdd: since(added, entry?.offlineAt),
            samples: entry?.sampleTimes.count ?? 0,
            status: latest.map { "\($0.status)" } ?? "none",
            message: latest?.message,
            lastError: latest?.lastError?.localizedDescription,
            kernel: snapshot?.kernel,
            cpuPercent: snapshot?.cpuPercent.map { Self.rounded($0) },
            memoryPercent: snapshot?.memUsedFraction.map { Self.rounded($0 * 100) },
            diskPercent: snapshot?.disk()?.usedFraction.map { Self.rounded($0 * 100) },
            mounts: snapshot?.disks.count ?? 0,
            swapTotalBytes: snapshot?.swapTotalBytes
        )
    }

    /// Waits until `condition` holds, checking every 50 ms. Returns whether it held in time.
    @discardableResult
    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            guard Date.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private static func endpoint(_ host: RemoteHost) -> String { "\(host.user)@\(host.address):\(host.port)" }

    /// Rounds to three decimals (milliseconds) for the report.
    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    private static func text(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }

    /// When this process started (the kernel's record, so it includes dyld and app launch).
    static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
#endif
