#if DEBUG
import AeroCore
import AppKit
import Collectors
import Darwin
import Foundation
import KeyAgent
import SSHKit

/// `-AeroSelfTest perf`: measures what 20 polled hosts cost the Mac (Phase 9's performance pass),
/// against the dev servers (`docker compose -f dev/compose.yml up -d`, the OrbStack VM from `dev/vm`).
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest perf \
///   -AeroSelfTestOutput /tmp/aeroops-perf.json \
///   -AeroSelfTestAuthorizeScript dev/add-key.sh \      # authorizes the new .pub on every dev server
///   [-AeroSelfTestPerfScenarios visible,containers,hidden] \
///   [-AeroSelfTestPerfWarmup 30] [-AeroSelfTestPerfDuration 120] [-AeroSelfTestPerfHosts 20] \
///   [-AeroSelfTestRevokeScript dev/remove-key.sh] [-AeroSelfTestKeepRoot YES]
/// ```
///
/// Runs under ``Phase2SelfTest``'s temporary root and Keychain service. The hosts are spread over
/// the dev servers under every name each one answers to (localhost, 127.0.0.1, ::1, the OrbStack
/// domains and their IPv4 and IPv6 addresses, and both VM users), so each host has its own alias
/// and, because `ControlPath %C` hashes address, port and user, its own ControlMaster, as distinct
/// real hosts would. Each physical server is scanned once; its keys are pinned for every name, so
/// sshd sees no extra unauthenticated connections.
///
/// Scenarios, each after a warm-up, sampled once a second:
/// - `visible`: the main window on screen (floating, 1440×900) showing the Dashboard, 5 s polls.
/// - `containers`: the same window on the Containers tab of the VM's `dev` host (Docker and k3s).
/// - `hidden`: the window minimised, 30 s polls.
///
/// Per second: the app's CPU (`getrusage(RUSAGE_SELF)`, cross-checked with `proc_pid_rusage`),
/// the per-poll ssh clients' CPU (`getrusage(RUSAGE_CHILDREN)`: the app reaps them), the
/// ControlMasters' CPU (`proc_pid_rusage` of every ssh process whose arguments name the temporary
/// root; they daemonise, so they are not the app's children), the physical footprint and the
/// number of ssh processes. CPU is a percentage of one core. The sampler's own CPU is reported too.
///
/// `[perf] sampling <scenario> ... pid <pid>` on stdout marks the start of each sampling window,
/// for attaching `xctrace`. An authentication failure ends the run at once (sshd's
/// PerSourcePenalties). Passes when every scenario was measured and the run cleaned up after
/// itself (key revoked and deleted, root removed, no ssh process left, no Touch ID request);
/// the 3 % target is reported, not enforced.
@MainActor
struct PerfSelfTest {
    private static var defaults: UserDefaults { .standard }

    static var warmupSeconds: Int { positive("AeroSelfTestPerfWarmup") ?? 30 }
    static var durationSeconds: Int { positive("AeroSelfTestPerfDuration") ?? 120 }
    static var hostCount: Int { positive("AeroSelfTestPerfHosts") ?? 20 }
    static var scenarios: [Scenario] {
        guard let list = defaults.string(forKey: "AeroSelfTestPerfScenarios") else { return Scenario.allCases }
        return list.split(separator: ",").compactMap { Scenario(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Phase 9: under 3 % of one core with 20 hosts, the window visible on the Dashboard.
    nonisolated static let cpuTarget = 3.0
    static let windowSize = CGSize(width: 1440, height: 900)
    static let onlineDeadline: TimeInterval = 60

    private static func positive(_ key: String) -> Int? {
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : nil
    }

    enum Scenario: String, CaseIterable, Codable {
        case visible
        case containers
        case hidden
    }

    /// One physical dev server and the names it answers to.
    struct Server {
        let name: String
        let users: [String]
        /// The port published on the Mac's loopback, if any.
        let forwardedPort: Int?
        /// OrbStack domains, reached directly on ``port``.
        let domains: [String]
        let port: Int
        let kubectlPrefix: String?
    }

    static let servers = [
        Server(name: "ssh", users: ["dev"], forwardedPort: 2222,
               domains: ["aeroops-ssh.orb.local", "ssh.aeroops-dev.orb.local"], port: 2222, kubectlPrefix: nil),
        Server(name: "alpine", users: ["dev"], forwardedPort: 2223,
               domains: ["aeroops-alpine.orb.local", "alpine.aeroops-dev.orb.local"], port: 22, kubectlPrefix: nil),
        Server(name: "vm", users: ["dev", "nodocker"], forwardedPort: nil,
               domains: ["aeroops-vm.orb.local"], port: 22, kubectlPrefix: Phase5SelfTest.k3sPrefix),
    ]

    let model: AppModel

    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    struct Stats: Codable {
        var average = 0.0
        var p50 = 0.0
        var p95 = 0.0
        var max = 0.0
    }

    struct HostResult: Codable {
        var name: String
        var endpoint: String
        var server: String
        var status = ""
        var polls = 0
        var lastError: String?
    }

    struct ScenarioResult: Codable {
        var scenario: String
        var tab = ""
        var activity = ""
        /// The window rule did not choose the scenario's activity, so the self-test forced it.
        var activityForced = false
        var appActive = false
        var windowFrame = ""
        var windowOnScreen = false
        var loadAverage: [Double] = []
        var warmupSeconds = 0
        var sampledSeconds = 0.0
        /// The app process, % of one core (`getrusage(RUSAGE_SELF)`), sampler included.
        var appCPU = Stats()
        /// The same from `proc_pid_rusage` (cross-check).
        var appCPUProcRusage = 0.0
        /// What the once-a-second sampler itself cost (part of ``appCPU``).
        var samplerCPU = 0.0
        /// Per-poll ssh clients (`getrusage(RUSAGE_CHILDREN)`).
        var sshClientsCPU = Stats()
        /// The ControlMasters.
        var sshMastersCPU = Stats()
        var sshTotalCPU = 0.0
        var footprintMB = Stats()
        var mastersMin = 0
        var mastersMax = 0
        var clientsAverage = 0.0
        var clientsMax = 0
        var polls = 0
        var pollsPerHostMin = 0
        var pollsPerHostMax = 0
        var batches = 0
        var containerRefreshes: Int?
        var containerIssues: [String] = []
        var appCPUPerSecond: [Double] = []
    }

    struct Report: Codable {
        var ok = false
        var root = ""
        var machine = ""
        var hardwareModel = ""
        var cores = 0
        var system = ""
        /// `false` for a `-Onone` build.
        var optimized = false
        var screenMaxFPS = 0
        var hostCount = 0
        var distinctEndpoints = 0
        var hosts: [HostResult] = []
        var targetPercent = PerfSelfTest.cpuTarget
        var visibleMeetsTarget: Bool?
        var scenarios: [ScenarioResult] = []
        var authFailed = false
        var privateKeyMaterialFound: [String] = []
        var leftoverProcesses: [String] = []
        var touchIDRequests: [String] = []
        var steps: [Step] = []
    }

    /// Counts the polls each host answers, from the dashboard's coalesced batches.
    @MainActor
    private final class Tracker {
        var hosts: [RemoteHost.ID: RemoteHost] = [:]
        var polls: [RemoteHost.ID: Int] = [:]
        var lastSampledAt: [RemoteHost.ID: Date] = [:]
        var latest: [RemoteHost.ID: HostMonitorUpdate] = [:]
        var batches = 0
        var authFailure: String?

        func receive(_ updates: [HostMonitorUpdate]) {
            batches += 1
            for update in updates {
                guard let host = hosts[update.hostID] else { continue }
                latest[update.hostID] = update
                if let sampledAt = update.snapshot?.sampledAt, lastSampledAt[update.hostID] != sampledAt {
                    lastSampledAt[update.hostID] = sampledAt
                    polls[update.hostID, default: 0] += 1
                }
                if update.lastError == .authFailed, authFailure == nil {
                    authFailure = "\(host.name): \(SSHError.authFailed.localizedDescription)"
                }
            }
        }

        var totalPolls: Int { polls.values.reduce(0, +) }
    }

    private final class Recorder {
        var report = Report()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            report.steps.append(Step(name: name, ok: ok, detail: detail))
            PerfSelfTest.log("\(ok ? "PASS" : "FAIL") \(name): \(detail)", prefix: "selftest")
        }
    }

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
        Self.log(report.ok ? "OK" : "FAILED", prefix: "selftest")
        if report.ok {
            NSApp.terminate(nil)
        } else {
            exit(1)
        }
    }

    func run() async -> Report {
        let r = Recorder()
        let ssh = model.ssh
        r.report.root = Phase2SelfTest.root.path(percentEncoded: false)
        r.report.machine = Self.sysctlString("machdep.cpu.brand_string")
        r.report.hardwareModel = Self.sysctlString("hw.model")
        r.report.cores = ProcessInfo.processInfo.processorCount
        r.report.system = ProcessInfo.processInfo.operatingSystemVersionString
        r.report.optimized = !_isDebugAssertConfiguration()
        r.report.screenMaxFPS = NSScreen.main?.maximumFramesPerSecond ?? 0

        guard case .running = ssh.agentStatus, model.monitoring.isRunning else {
            r.step("services", false, "agent \(ssh.agentStatus), monitoring running \(model.monitoring.isRunning)")
            return await finish(r, key: nil)
        }
        r.step("services", true, "agent running, monitoring started; \(r.report.optimized ? "optimized" : "-Onone") build")

        guard let key = await Phase2SelfTest.generateKey(name: "AeroOps perf self-test", ssh: ssh, step: r.step) else {
            return await finish(r, key: nil)
        }

        if await Phase2SelfTest.authorize(key, ssh: ssh, step: r.step) {
            await measureHosts(key, r)
        }
        return await finish(r, key: key)
    }

    private func measureHosts(_ key: SSHKeyRecord, _ r: Recorder) async {
        let keyID = key.id.uuidString
        let (hosts, serverOf, distinct) = await makeHosts(keyID: keyID)
        r.report.hostCount = hosts.count
        r.report.distinctEndpoints = distinct
        r.step("endpoints", hosts.count == Self.hostCount, "\(hosts.count) hosts over \(distinct) distinct (address, port, user)")
        guard !hosts.isEmpty else { return }

        guard await pinHostKeys(r, hosts: hosts, serverOf: serverOf) else { return }

        let tracker = Tracker()
        for host in hosts { tracker.hosts[host.id] = host }
        let monitoring = model.monitoring
        monitoring.didApplyUpdates = { tracker.receive($0) }
        defer { monitoring.didApplyUpdates = nil }

        guard await addHosts(hosts, r),
              await waitUntilOnline(hosts, serverOf: serverOf, tracker: tracker, r)
        else { return }
        await runScenarios(hosts, serverOf: serverOf, tracker: tracker, r)
        restoreActivity()
    }

    private func addHosts(_ hosts: [RemoteHost], _ r: Recorder) async -> Bool {
        model.selectedTab = .dashboard
        model.selection = nil
        _ = await showMainWindow()
        do {
            for host in hosts { try model.addHost(host) }
            model.selection = nil
        } catch {
            r.step("add hosts", false, error.localizedDescription)
            return false
        }
        let rejected = hosts.compactMap { model.ssh.configRejections[$0.id].map { "\($0)" } }
        r.step("add hosts", rejected.isEmpty, rejected.isEmpty ? "\(hosts.count) hosts monitored" : "rejected: \(rejected)")
        return true
    }

    private func waitUntilOnline(_ hosts: [RemoteHost], serverOf: [RemoteHost.ID: Int], tracker: Tracker, _ r: Recorder) async -> Bool {
        let started = Date.now
        let allOnline = await waitUntil(seconds: Self.onlineDeadline) {
            tracker.authFailure != nil || hosts.allSatisfy { (tracker.polls[$0.id] ?? 0) >= 2 }
        }
        r.report.hosts = hostResults(hosts, serverOf: serverOf, tracker: tracker)
        if let failure = tracker.authFailure {
            r.report.authFailed = true
            r.step("authentication", false, "\(failure); stopping now (sshd PerSourcePenalties)")
            return false
        }
        let offline = r.report.hosts.filter { $0.polls < 2 }.map { "\($0.name) (\($0.lastError ?? $0.status))" }
        r.step(
            "hosts online", allOnline && offline.isEmpty,
            offline.isEmpty
                ? "\(hosts.count) hosts polled twice within \(Self.text(Date.now.timeIntervalSince(started))) s"
                : "not polled: \(offline.joined(separator: ", "))"
        )
        return true
    }

    private func runScenarios(_ hosts: [RemoteHost], serverOf: [RemoteHost.ID: Int], tracker: Tracker, _ r: Recorder) async {
        let containersHost = hosts.first { $0.kubectlPrefix != nil }
        for scenario in Self.scenarios {
            guard let result = await measure(scenario, r: r, tracker: tracker, hosts: hosts, containersHost: containersHost) else {
                break
            }
            r.report.scenarios.append(result)
            if scenario == .visible {
                r.report.visibleMeetsTarget = result.appCPU.average < Self.cpuTarget
            }
        }
        if let failure = tracker.authFailure {
            r.report.authFailed = true
            r.step("authentication", false, "\(failure); stopped (sshd PerSourcePenalties)")
        }
        r.report.hosts = hostResults(hosts, serverOf: serverOf, tracker: tracker)
    }

    private func restoreActivity() {
        if let window = mainWindow() {
            window.level = .normal
            if window.isMiniaturized { window.deminiaturize(nil) }
        }
        model.monitoring.activityOverride = nil
    }

    private func makeHosts(keyID: String) async -> ([RemoteHost], [RemoteHost.ID: Int], Int) {
        struct Endpoint: Hashable {
            let server: Int
            let address: String
            let port: Int
            let user: String
        }
        var perServer: [[Endpoint]] = []
        for (index, server) in Self.servers.enumerated() {
            var addresses: [(String, Int)] = []
            if let port = server.forwardedPort {
                addresses += [("localhost", port), ("127.0.0.1", port), ("::1", port)]
            }
            addresses += server.domains.map { ($0, server.port) }
            if let domain = server.domains.first {
                addresses += await Self.resolve(domain).map { ($0, server.port) }
            }
            perServer.append(addresses.flatMap { address in
                server.users.map { Endpoint(server: index, address: address.0, port: address.1, user: $0) }
            })
        }
        var order: [Endpoint] = []
        let longest = perServer.map(\.count).max() ?? 0
        for position in 0..<longest {
            for endpoints in perServer where position < endpoints.count { order.append(endpoints[position]) }
        }
        guard !order.isEmpty else { return ([], [:], 0) }

        var hosts: [RemoteHost] = []
        var serverOf: [RemoteHost.ID: Int] = [:]
        let containers = order.first { Self.servers[$0.server].kubectlPrefix != nil && $0.user == "dev" }
        for number in 0..<Self.hostCount {
            let endpoint = order[number % order.count]
            let server = Self.servers[endpoint.server]
            let host = RemoteHost(
                name: String(format: "Perf %02d %@", number + 1, "\(endpoint.user)@\(endpoint.address)"),
                address: endpoint.address, port: endpoint.port, user: endpoint.user, keyId: keyID,
                kubectlPrefix: endpoint == containers && number < order.count ? server.kubectlPrefix : nil
            )
            hosts.append(host)
            serverOf[host.id] = endpoint.server
        }
        return (hosts, serverOf, Set(order.prefix(Self.hostCount)).count)
    }

    /// Scans each server once through its first name and pins the keys for all of its hosts.
    private func pinHostKeys(_ r: Recorder, hosts: [RemoteHost], serverOf: [RemoteHost.ID: Int]) async -> Bool {
        let ssh = model.ssh
        var details: [String] = []
        for index in Self.servers.indices {
            let group = hosts.filter { serverOf[$0.id] == index }
            guard let first = group.first else { continue }
            let offered: [HostKey]
            do {
                switch try await ssh.hostKeys.verify(first) {
                case .unknown(let keys): offered = keys
                case .trusted(let key): offered = [key]
                case .changed:
                    r.step("pin host keys", false, "\(first.address):\(first.port) offers a key other than the pinned one")
                    return false
                }
            } catch {
                r.step("pin host keys", false, "\(first.address):\(first.port): \(error.localizedDescription)")
                return false
            }
            var pinnedNames = Set<String>()
            for host in group where pinnedNames.insert("\(host.address.lowercased()):\(host.port)").inserted {
                do {
                    try await ssh.trust(offered, for: host, replacingPinned: false)
                } catch {
                    r.step("pin host keys", false, "\(host.address):\(host.port): \(error.localizedDescription)")
                    return false
                }
            }
            details.append("\(Self.servers[index].name): \(offered.count) keys for \(pinnedNames.count) names")
        }
        r.step("pin host keys", true, details.joined(separator: "; "))
        return true
    }

    private func hostResults(_ hosts: [RemoteHost], serverOf: [RemoteHost.ID: Int], tracker: Tracker) -> [HostResult] {
        hosts.map { host in
            let latest = tracker.latest[host.id]
            return HostResult(
                name: host.name,
                endpoint: "\(host.user)@\(host.address):\(host.port)",
                server: serverOf[host.id].map { Self.servers[$0].name } ?? "-",
                status: latest.map { "\($0.status)" } ?? "none",
                polls: tracker.polls[host.id] ?? 0,
                lastError: latest?.lastError?.localizedDescription
            )
        }
    }

    private func measure(
        _ scenario: Scenario, r: Recorder, tracker: Tracker, hosts: [RemoteHost], containersHost: RemoteHost?
    ) async -> ScenarioResult? {
        var result = ScenarioResult(scenario: scenario.rawValue)
        let monitoring = model.monitoring
        var containers: HostContainersModel?

        switch scenario {
        case .visible:
            model.selectedTab = .dashboard
            model.selection = nil
            result.activityForced = await showMainWindow()
        case .containers:
            guard let host = containersHost else {
                r.step("scenario containers", false, "no host with a kubectl prefix")
                return nil
            }
            model.selection = host.id
            model.selectedTab = .containers
            result.activityForced = await showMainWindow()
            let tab = model.containers(for: host.id)
            containers = tab
            let loaded = await waitUntil(seconds: 20) {
                tracker.authFailure != nil || tab.connectionIssue != nil || (tab.dockerLoaded && tab.podsLoaded)
            }
            if !loaded || tab.connectionIssue != nil {
                r.step("scenario containers", false, "containers not loaded: \(tab.connectionIssue.map { "\($0)" } ?? "timeout")")
                return nil
            }
        case .hidden:
            model.selectedTab = .dashboard
            model.selection = nil
            monitoring.activityOverride = nil
            if let window = mainWindow() {
                window.level = .normal
                window.miniaturize(nil)
            }
            await waitUntil(seconds: 5) { monitoring.activity == .background }
            if monitoring.activity != .background {
                monitoring.activityOverride = .background
                result.activityForced = true
            }
        }
        let expected: MonitorActivity = scenario == .hidden ? .background : .visible
        let window = mainWindow()
        result.tab = "\(model.selectedTab)"
        result.activity = "\(monitoring.activity)"
        result.appActive = NSApp.isActive
        result.windowFrame = window.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) miniaturized=\($0.isMiniaturized)" } ?? "none"
        result.windowOnScreen = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        result.warmupSeconds = Self.warmupSeconds

        Self.log("warm-up \(scenario.rawValue) for \(Self.warmupSeconds) s")
        guard await sleep(seconds: Double(Self.warmupSeconds), unless: { tracker.authFailure != nil }) else { return nil }

        result.loadAverage = Self.loadAverage()
        let pollsBefore = tracker.polls
        let batchesBefore = tracker.batches
        let refreshesBefore = containers?.refreshCount
        Self.log("sampling \(scenario.rawValue) for \(Self.durationSeconds) s, pid \(getpid()), load \(result.loadAverage)")

        let needle = Phase2SelfTest.root.lastPathComponent
        let duration = Self.durationSeconds
        let sampler = Task.detached(priority: .userInitiated) {
            await PerfSampler.run(seconds: duration, needle: needle)
        }
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if tracker.authFailure != nil { return sampler.cancel() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let seconds = await sampler.value
        watcher.cancel()
        guard tracker.authFailure == nil else { return nil }

        let polls = hosts.map { (tracker.polls[$0.id] ?? 0) - (pollsBefore[$0.id] ?? 0) }
        result.polls = polls.reduce(0, +)
        result.pollsPerHostMin = polls.min() ?? 0
        result.pollsPerHostMax = polls.max() ?? 0
        result.batches = tracker.batches - batchesBefore
        if let containers, let refreshesBefore {
            result.containerRefreshes = containers.refreshCount - refreshesBefore
            result.containerIssues = [containers.dockerIssue, containers.podsIssue, containers.connectionIssue]
                .compactMap { $0.map { "\($0)" } }
        }
        Self.summarize(seconds, into: &result)

        r.step(
            "scenario \(scenario.rawValue)",
            monitoring.activity == expected && result.sampledSeconds >= Double(duration) - 2 && result.containerIssues.isEmpty,
            String(
                format: "app %.2f%% avg, %.2f%% p95 (sampler %.2f%%); ssh clients %.2f%%, masters %.2f%%; %.0f MB; %d–%d masters; %d polls; activity %@%@",
                result.appCPU.average, result.appCPU.p95, result.samplerCPU, result.sshClientsCPU.average,
                result.sshMastersCPU.average, result.footprintMB.average, result.mastersMin, result.mastersMax, result.polls,
                result.activity, result.activityForced ? " (forced)" : ""
            )
        )
        return result
    }

    private static func summarize(_ seconds: [PerfSampler.Second], into result: inout ScenarioResult) {
        guard !seconds.isEmpty else { return }
        let wall = seconds.reduce(0) { $0 + $1.wallNs }
        func average(_ value: (PerfSampler.Second) -> Double) -> Double {
            rounded(seconds.reduce(0) { $0 + value($1) * $1.wallNs } / wall)
        }
        func stats(_ value: (PerfSampler.Second) -> Double) -> Stats {
            let sorted = seconds.map(value).sorted()
            func percentile(_ p: Double) -> Double {
                rounded(sorted[min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)])
            }
            return Stats(average: average(value), p50: percentile(0.5), p95: percentile(0.95), max: rounded(sorted.last ?? 0))
        }
        result.sampledSeconds = rounded(wall / 1e9)
        result.appCPU = stats(\.appCPU)
        result.appCPUProcRusage = average(\.appCPUProcRusage)
        result.samplerCPU = average(\.samplerCPU)
        result.sshClientsCPU = stats(\.clientsCPU)
        result.sshMastersCPU = stats(\.mastersCPU)
        result.sshTotalCPU = rounded(result.sshClientsCPU.average + result.sshMastersCPU.average)
        result.footprintMB = stats(\.footprintMB)
        result.mastersMin = seconds.map(\.masters).min() ?? 0
        result.mastersMax = seconds.map(\.masters).max() ?? 0
        result.clientsAverage = rounded(Double(seconds.reduce(0) { $0 + $1.clients }) / Double(seconds.count))
        result.clientsMax = seconds.map(\.clients).max() ?? 0
        result.appCPUPerSecond = seconds.map { rounded($0.appCPU) }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first(where: MonitorService.isMainWindow)
    }

    /// Puts the main window on screen at ``windowSize``, floating so other apps can't cover it,
    /// and waits for the visible activity. Returns whether the activity had to be forced
    /// (launched from a shell, macOS may keep another app active).
    private func showMainWindow() async -> Bool {
        let monitoring = model.monitoring
        guard let window = mainWindow() else {
            monitoring.activityOverride = .visible
            return true
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
            await waitUntil(seconds: 3) { !window.isMiniaturized }
        }
        window.level = .floating
        if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
            let size = CGSize(width: min(Self.windowSize.width, area.width), height: min(Self.windowSize.height, area.height))
            window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        monitoring.activityOverride = nil
        await waitUntil(seconds: 3) { monitoring.activity == .visible }
        guard monitoring.activity != .visible else { return false }
        monitoring.activityOverride = .visible
        return true
    }

    private func finish(_ r: Recorder, key: SSHKeyRecord?) async -> Report {
        let ssh = model.ssh
        let paths = ssh.paths
        if let key {
            r.report.privateKeyMaterialFound = Phase2SelfTest.checkNoKeyMaterial(key, step: r.step)
        }

        let closed = await model.shutdownServices()
        let socketGone = !FileManager.default.fileExists(atPath: paths.agentSocket.path(percentEncoded: false))
        r.step("shutdown", socketGone && !model.monitoring.isRunning, "monitoring stopped, masters closed \(closed), agent socket removed \(socketGone)")

        if let key {
            await Phase2SelfTest.revokeKey(key, ssh: ssh, step: r.step)
            await Phase2SelfTest.deleteKey(key, ssh: ssh, step: r.step)
        }
        await checkNothingLeftBehind(r)
        if !Phase2SelfTest.keepsRoot {
            try? FileManager.default.removeItem(at: Phase2SelfTest.root)
        }
        r.report.ok = !r.report.steps.isEmpty && r.report.steps.allSatisfy(\.ok)
        return r.report
    }

    private func checkNothingLeftBehind(_ r: Recorder) async {
        let needle = Phase2SelfTest.root.lastPathComponent
        var leftovers: [String] = []
        await waitUntil(seconds: 5) {
            leftovers = PerfSampler.processes(matching: needle)
            return leftovers.isEmpty
        }
        r.report.leftoverProcesses = leftovers
        r.step("no ssh processes left", leftovers.isEmpty, leftovers.isEmpty ? "none name \(needle)" : leftovers.joined(separator: "; "))

        r.report.touchIDRequests = Phase2SelfTest.presenceVerifier.requests
        r.step(
            "no Touch ID requests", r.report.touchIDRequests.isEmpty,
            r.report.touchIDRequests.isEmpty ? "none" : "\(r.report.touchIDRequests.count), denied: \(r.report.touchIDRequests)"
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

    /// Sleeps `seconds`, waking every 500 ms to check `abort`. Returns `false` if it aborted.
    private func sleep(seconds: Double, unless abort: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if abort() { return false }
            try? await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(500))), clock: .continuous)
        }
        return !abort()
    }

    /// The first IPv4 and the first IPv6 address of `name` (no link-local or scoped ones).
    ///
    /// Asks `dscacheutil`: the app itself may not resolve `.local` names (Local Network privacy),
    /// while the system's ssh does.
    static func resolve(_ name: String) async -> [String] {
        let (status, output) = await Phase2SelfTest.runProcess(
            URL(filePath: "/usr/bin/dscacheutil"), arguments: ["-q", "host", "-a", "name", name]
        )
        guard status == 0 else { return [] }
        var v4: String?
        var v6: String?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "ip_address", v4 == nil {
                v4 = parts[1]
            } else if parts[0] == "ipv6_address", v6 == nil, !parts[1].contains("%"), !parts[1].lowercased().hasPrefix("fe80") {
                v6 = parts[1]
            }
        }
        return [v4, v6].compactMap { $0 }
    }

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        return loads.prefix(Int(max(count, 0))).map { rounded($0) }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Writes unbuffered, so a log file shows the markers as they happen.
    nonisolated static func log(_ message: String, prefix: String = "perf") {
        FileHandle.standardOutput.write(Data("[\(prefix)] \(message)\n".utf8))
    }

    /// Rounds to three decimals for the report.
    nonisolated static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    private static func text(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// Once-a-second CPU, memory and ssh process readings, off the main actor.
enum PerfSampler {
    /// One interval between two readings. CPU is a percentage of one core.
    struct Second: Sendable {
        var wallNs: Double
        var appCPU: Double
        var appCPUProcRusage: Double
        var samplerCPU: Double
        var clientsCPU: Double
        var mastersCPU: Double
        var footprintMB: Double
        var masters: Int
        var clients: Int
    }

    private struct Reading {
        var wallNs: UInt64
        var selfNs: UInt64
        var selfRusageNs: UInt64
        var footprint: UInt64
        var childrenNs: UInt64
        var masters: [ProcessKey: UInt64]
        var clients: Int
        var samplerNs: UInt64
    }

    private struct ProcessKey: Hashable {
        let pid: pid_t
        let startSeconds: Int
        let startMicroseconds: Int32
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Samples every second for `seconds` (or until cancelled).
    static func run(seconds: Int, needle: String) async -> [Second] {
        var isMaster: [ProcessKey: Bool] = [:]
        let clock = ContinuousClock()
        let start = clock.now
        var previous = read(needle: needle, cache: &isMaster)
        var result: [Second] = []
        for tick in 1...max(seconds, 1) {
            try? await Task.sleep(until: start.advanced(by: .seconds(tick)), clock: .continuous)
            if Task.isCancelled { break }
            let current = read(needle: needle, cache: &isMaster)
            result.append(second(from: previous, to: current))
            previous = current
        }
        return result
    }

    private static func second(from a: Reading, to b: Reading) -> Second {
        let wall = Double(max(b.wallNs - a.wallNs, 1))
        func percent(_ ns: UInt64, _ old: UInt64) -> Double { Double(ns &- old) / wall * 100 }
        var masters = 0.0
        for (key, ns) in b.masters {
            if let old = a.masters[key], ns >= old { masters += Double(ns - old) }
        }
        return Second(
            wallNs: wall,
            appCPU: percent(b.selfNs, a.selfNs),
            appCPUProcRusage: percent(b.selfRusageNs, a.selfRusageNs),
            samplerCPU: Double(b.samplerNs) / wall * 100,
            clientsCPU: percent(b.childrenNs, a.childrenNs),
            mastersCPU: masters / wall * 100,
            footprintMB: Double(b.footprint) / 1_048_576,
            masters: b.masters.count,
            clients: b.clients
        )
    }

    private static func read(needle: String, cache: inout [ProcessKey: Bool]) -> Reading {
        let threadStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let me = getpid()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let selfNs = nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
        getrusage(RUSAGE_CHILDREN, &usage)
        let childrenNs = nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
        let own = rusageInfo(me)

        var masters: [ProcessKey: UInt64] = [:]
        var clients = 0
        let uid = getuid()
        var seen = Set<ProcessKey>()
        for info in processTable() where info.kp_eproc.e_ucred.cr_uid == uid && command(info) == "ssh" {
            let pid = info.kp_proc.p_pid
            let start = info.kp_proc.p_un.__p_starttime
            let key = ProcessKey(pid: pid, startSeconds: Int(start.tv_sec), startMicroseconds: Int32(start.tv_usec))
            seen.insert(key)
            if info.kp_eproc.e_ppid == me {
                clients += 1
                continue
            }
            let matches = cache[key] ?? (arguments(of: pid)?.contains(needle) ?? false)
            cache[key] = matches
            if matches, let usage = rusageInfo(pid) {
                masters[key] = usage.cpuNs
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return Reading(
            wallNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            selfNs: selfNs,
            selfRusageNs: own?.cpuNs ?? 0,
            footprint: own?.footprint ?? 0,
            childrenNs: childrenNs,
            masters: masters,
            clients: clients,
            samplerNs: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- threadStart
        )
    }

    /// Every process of this user whose arguments contain `needle`, except this one.
    static func processes(matching needle: String) -> [String] {
        let me = getpid()
        let uid = getuid()
        return processTable().compactMap { info in
            let pid = info.kp_proc.p_pid
            guard pid != me, info.kp_eproc.e_ucred.cr_uid == uid,
                  let arguments = arguments(of: pid), arguments.contains(needle) else { return nil }
            return "\(pid) \(command(info)): \(arguments.prefix(200))"
        }
    }

    private static func nanoseconds(_ time: timeval) -> UInt64 {
        UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1000
    }

    /// CPU (user + system, in ns) and physical footprint of `pid`.
    private static func rusageInfo(_ pid: pid_t) -> (cpuNs: UInt64, footprint: UInt64)? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        return (ticks * timebase.numer / timebase.denom, info.ri_phys_footprint)
    }

    private static func processTable() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = buffer.count * stride
            if sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 {
                return Array(buffer.prefix(size / stride))
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    private static func command(_ info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The process's arguments (`KERN_PROCARGS2`), NULs as spaces; `nil` when unreadable.
    private static func arguments(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(size).dropFirst(MemoryLayout<Int32>.size).map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
    }
}
#endif
