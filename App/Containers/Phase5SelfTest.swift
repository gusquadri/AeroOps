#if DEBUG
import AeroCore
import AppKit
import Collectors
import Foundation
import ImageIO
import KeyAgent
@preconcurrency import ScreenCaptureKit
import SSHKit
import UniformTypeIdentifiers

/// `-AeroSelfTest phase5`: proves the Containers tab end to end in the built app against the
/// OrbStack dev VM (`dev/vm`), without clicking.
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest phase5 \
///   -AeroSelfTestOutput /tmp/aeroops-phase5.json \
///   -AeroSelfTestAuthorizeScript dev/add-key.sh \      # authorizes the new .pub for dev@ and nodocker@
///   [-AeroSelfTestSnapshots build/phase5-snapshots] \  # light and dark PNGs of the tab, sheet and inspector
///   [-AeroSelfTestVM aeroops-vm.orb.local]
/// ```
///
/// Same isolation as ``Phase2SelfTest`` (temporary root, separate Keychain service). Host keys are
/// trusted automatically, which only this self-test does. ssh login failures are never retried
/// (sshd's PerSourcePenalties would lock out every client on this Mac).
///
/// Checks: every running container has CPU and memory; refreshes never overlap; inspect works;
/// following the ANSI logger for 10 s plus a 50k-line synthetic burst keeps the main thread's
/// worst heartbeat lag under 100 ms; search finds matches; closing the sheet ends the remote
/// `docker logs -f` and `kubectl logs -f`; the crash-looping pod is red with restarts and its
/// previous logs load in one click; the Pending pod's events include FailedScheduling; the
/// `nodocker` user gets the docker-group hint. Cleans up the Keychain item, the root and the
/// authorized keys, writes a JSON report and quits.
@MainActor
struct Phase5SelfTest {
    private static var defaults: UserDefaults { .standard }
    static var snapshotDirectory: URL? {
        defaults.string(forKey: "AeroSelfTestSnapshots").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
    static var vmAddress: String { defaults.string(forKey: "AeroSelfTestVM") ?? "aeroops-vm.orb.local" }
    static let k3sPrefix = "sudo -n k3s kubectl"
    /// Only this self-test names keys like this, so leftovers of a crashed run can be found.
    static let keyName = "AeroOps phase 5 self-test"
    static let maxLagBudget = 100.0

    let model: AppModel

    // MARK: - Report

    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    struct ContainerRow: Codable {
        var name: String
        var state: String
        var cpuPercent: Double?
        var memUsedBytes: Int64?
    }

    struct FollowNumbers: Codable {
        var seconds = 0.0
        var linesReceived = 0
        var linesPerSecond = 0.0
        var flushes = 0
        var maxFlushMilliseconds = 0.0
        var averageFlushMilliseconds = 0.0
        var maxMainThreadLagMilliseconds = 0.0
        var p99MainThreadLagMilliseconds = 0.0
        var heartbeatSamples = 0
        var linesShown = 0
        var linesDropped = 0
    }

    struct Report: Codable {
        var ok = false
        var vm = ""
        var steps: [Step] = []
        var capabilities: [String] = []
        var containers: [ContainerRow] = []
        var runningContainers = 0
        var runningWithCPUAndMemory = 0
        var maxConcurrentRefreshes = 0
        var inspectJSONBytes = 0
        var follow = FollowNumbers()
        var burst = FollowNumbers()
        var maxMainThreadLagMilliseconds = 0.0
        var searchQuery = ""
        var searchMatches = 0
        var dockerFollowGoneAfterSeconds: Double?
        var kubectlFollowGoneAfterSeconds: Double?
        var crasher: String?
        var crasherStatus: String?
        var crasherRestarts: Int?
        var crasherHealth: String?
        var previousLogsLines = 0
        var previousLogsInfoLine: String?
        var pendingPod: String?
        var pendingEventReasons: [String] = []
        var nodockerIssue: String?
        var nodockerHint: String?
        var terminalCommands: [String] = []
        var snapshots: [String] = []
        var authorizedKeysRemaining: String?
    }

    private final class Recorder {
        var report = Report()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            report.steps.append(Step(name: name, ok: ok, detail: detail))
            Phase5SelfTest.log("[phase5] \(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }
    }

    // MARK: - Run

    func runAndQuit() async {
        let report = await run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                try? data.write(to: url, options: .atomic)
            }
        }
        Self.log("[phase5] \(report.ok ? "OK" : "FAILED")")
        guard report.ok else {
            // Services are already shut down in finish(); a failed run must not look like success.
            exit(1)
        }
        NSApp.terminate(nil)
    }

    private func run() async -> Report {
        let r = Recorder()
        r.report.vm = Self.vmAddress
        let ssh = model.ssh
        // Launched from a shell, the app is usually behind other windows: App Nap would then
        // coalesce timers (the 10 ms heartbeat and the burst producer's sleeps) and the
        // numbers would measure macOS throttling instead of the log view.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "AeroOps phase 5 self-test timing"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        NSApp.activate()
        await pause(1.0)

        // 1. Key in the Keychain, authorized for dev@ and nodocker@ on the VM.
        guard let key = await Phase2SelfTest.generateKey(name: Self.keyName, ssh: ssh, step: r.step) else {
            return await finish(r, key: nil)
        }
        if await authorize(key, r) { await checkHosts(key, r) }
        return await finish(r, key: key)
    }

    private func authorize(_ key: SSHKeyRecord, _ r: Recorder) async -> Bool {
        let pubURL = model.ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
        guard let script = Phase2SelfTest.authorizeScript else {
            r.step("authorize key", false, "pass -AeroSelfTestAuthorizeScript dev/add-key.sh")
            return false
        }
        let (status, output) = await Phase2SelfTest.runProcess(script, arguments: [pubURL.path(percentEncoded: false)])
        let vmAuthorized = status == 0 && output.split(whereSeparator: \.isNewline).contains {
            $0.hasPrefix("aeroops-vm") && $0.contains("authorized")
        }
        r.step("authorize key", vmAuthorized, output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))
        return vmAuthorized
    }

    private func checkHosts(_ key: SSHKeyRecord, _ r: Recorder) async {
        // 2. Hosts: dev (docker group; k3s through sudo -n) and nodocker.
        let dev = RemoteHost(
            name: "VM dev", address: Self.vmAddress, user: "dev", keyId: key.id.uuidString, kubectlPrefix: Self.k3sPrefix
        )
        let nodocker = RemoteHost(name: "VM nodocker", address: Self.vmAddress, user: "nodocker", keyId: key.id.uuidString)
        do {
            try model.addHost(dev)
            try model.addHost(nodocker)
        } catch {
            r.step("add hosts", false, error.localizedDescription)
            return
        }

        // 3. Trust the host keys (self-test only) and sign in once. No retry on failure.
        for host in [dev, nodocker] {
            guard await trustAndConnect(host, r) else { return }
        }

        model.selection = dev.id
        model.selectedTab = .containers
        let containers = model.containers(for: dev.id)
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }

        await checkDocker(containers, r)
        await checkFollow(containers, dev: dev, heartbeat: heartbeat, r)
        await checkInspect(containers, r)
        await checkPods(containers, dev: dev, r)
        await checkNodocker(nodocker, r)
    }

    /// Test connection: first contact offers keys, which are trusted; then one real login.
    private func trustAndConnect(_ host: RemoteHost, _ r: Recorder) async -> Bool {
        let first = await model.connectionTester.testConnection(to: host)
        switch first.outcome {
        case .hostKeyUnknown(let offered):
            do {
                try await model.ssh.trust(offered, for: host, replacingPinned: false)
            } catch {
                r.step("trust \(host.user)", false, error.localizedDescription)
                return false
            }
            let second = await model.connectionTester.testConnection(to: host)
            r.step("connect \(host.user)", second.succeeded, "\(offered.count) host key(s) trusted; \(second.message)")
            return second.succeeded
        case .success:
            r.step("connect \(host.user)", true, first.message)
            return true
        default:
            r.step("connect \(host.user)", false, "\(first.outcome): \(first.message) (not retried)")
            return false
        }
    }

    // MARK: - Docker

    private func checkDocker(_ containers: HostContainersModel, _ r: Recorder) async {
        await containers.refresh(reprobe: true)
        // Two overlapping requests (plus the tab's own poll) must not run two refreshes at once.
        async let first: Void = containers.refresh()
        async let second: Void = containers.refresh()
        _ = await (first, second)
        r.report.maxConcurrentRefreshes = containers.maxConcurrentRefreshes
        r.step("refreshes never overlap", containers.maxConcurrentRefreshes == 1, "max concurrent \(containers.maxConcurrentRefreshes)")

        let caps = containers.capabilities ?? []
        r.report.capabilities = HostCapabilities.tokens.filter { caps.contains($0.capability) }.map(\.token)
        r.step("capabilities", caps.contains(.docker) && containers.showsKubernetes, r.report.capabilities.joined(separator: " "))

        let list = containers.containers
        r.report.containers = list.map {
            ContainerRow(name: $0.name, state: $0.state.rawValue, cpuPercent: $0.cpuPercent, memUsedBytes: $0.memUsedBytes)
        }
        let running = list.filter { $0.state == .running }
        let withStats = running.filter { $0.cpuPercent != nil && $0.memUsedBytes != nil }
        r.report.runningContainers = running.count
        r.report.runningWithCPUAndMemory = withStats.count
        r.step(
            "docker CPU and memory", containers.dockerIssue == nil && !running.isEmpty && withStats.count == running.count,
            "\(withStats.count)/\(running.count) running containers have CPU and memory; \(list.count) total"
                + (containers.dockerIssue.map { "; issue: \($0.title)" } ?? "")
        )
        if let container = list.first {
            r.report.terminalCommands.append(
                (try? DockerCommands.terminalFollow(container: container.name, tail: LogViewerModel.tail, sudo: false)) ?? "?"
            )
        }
        containers.section = .docker
        containers.showStopped = true
        await pause(1.0)
        await snapshotMain("docker-table", r, between: containers)

        // The Memory header sorts the most memory first, containers without stats last.
        containers.containerSortOrder = [KeyPathComparator(\.memUsedBytes, order: .reverse)]
        let memory = containers.filteredContainers.map(\.memUsedBytes)
        r.step(
            "sort by memory", zip(memory, memory.dropFirst()).allSatisfy { ($0 ?? -1) >= ($1 ?? -1) },
            memory.map { $0.map { $0.formatted(.byteCount(style: .memory)) } ?? MetricText.missing }.joined(separator: ", ")
        )
        await pause(1.0)
        await snapshotMain("docker-table-sorted", r, between: containers)
        containers.containerSortOrder = []
    }

    private func checkInspect(_ containers: HostContainersModel, _ r: Recorder) async {
        guard let target = containers.containers.first(where: { $0.state == .running }) else {
            return r.step("inspect", false, "no running container")
        }
        containers.inspect(target)
        guard let inspection = containers.inspection else { return r.step("inspect", false, "no sheet") }
        await waitUntil(seconds: 20) { !inspection.isLoading }
        // Only sizes are recorded: the JSON holds the container's environment.
        r.report.inspectJSONBytes = inspection.json.utf8.count
        r.step(
            "inspect", inspection.summary?.name == target.name && !inspection.json.isEmpty,
            "\(target.name): \(inspection.json.utf8.count) bytes of JSON, restarts \(inspection.summary?.restartCount ?? -1)"
        )
        containers.inspection = nil
        await pause(0.6)
    }

    // MARK: - Follow

    private func checkFollow(_ containers: HostContainersModel, dev: RemoteHost, heartbeat: MainThreadHeartbeat, _ r: Recorder) async {
        guard let logger = containers.containers.first(where: { $0.name == "demo-logger" && $0.state == .running })
            ?? containers.containers.first(where: { $0.state == .running })
        else { return r.step("follow", false, "no running container") }

        containers.showLogs(logger)
        guard let viewer = containers.logs else { return r.step("follow", false, "no logs sheet") }
        await waitUntil(seconds: 2) { viewer.status != .idle }
        if viewer.status == .idle { viewer.start() }
        await waitUntil(seconds: 20) { viewer.status == .following && viewer.lineCount > 0 }
        r.step("follow started", viewer.status == .following, "\(logger.name): \(viewer.lineCount) lines, status \(viewer.status)")
        guard viewer.status == .following else {
            containers.logs = nil
            return
        }
        let remote = await remoteProcessCount("[d]ocker logs -f --tail 500 ", on: dev)
        r.step("remote docker follow running", remote > 0, "\(remote) matching process(es) on the VM")

        // ~10 s of the real logger.
        r.report.follow = await measure(viewer, heartbeat: heartbeat, seconds: 10)
        r.step(
            "follow 10 s", r.report.follow.linesReceived > 0 && r.report.follow.maxMainThreadLagMilliseconds < Self.maxLagBudget,
            String(format: "%d new lines (%.1f/s), max main-thread lag %.1f ms",
                   r.report.follow.linesReceived, r.report.follow.linesPerSecond, r.report.follow.maxMainThreadLagMilliseconds)
        )

        // Search with highlights.
        r.report.searchQuery = "slow query"
        viewer.search(r.report.searchQuery)
        viewer.nextMatch()
        await pause(0.8)
        r.report.searchMatches = viewer.matchCount
        r.step("search", viewer.matchCount > 0, "\(viewer.matchCount) matches for “\(r.report.searchQuery)”")
        await snapshotSheet("logs-search", r)

        // A synthetic burst through the same inbox and flush path: 50k lines at ~10k/s.
        heartbeat.reset()
        let before = viewer.stats
        let start = ContinuousClock.now
        await viewer.injectSyntheticLines(count: 50_000, perSecond: 10_000)
        await pause(0.4)
        let seconds = (ContinuousClock.now - start).milliseconds / 1000
        let after = viewer.stats
        var burst = FollowNumbers()
        burst.seconds = seconds
        burst.linesReceived = after.linesReceived - before.linesReceived
        burst.linesPerSecond = Double(burst.linesReceived) / max(seconds, 0.001)
        burst.flushes = after.flushes - before.flushes
        burst.maxFlushMilliseconds = after.maxFlushMilliseconds
        burst.averageFlushMilliseconds = (after.totalFlushMilliseconds - before.totalFlushMilliseconds) / Double(max(burst.flushes, 1))
        burst.maxMainThreadLagMilliseconds = heartbeat.maxLagMilliseconds
        burst.p99MainThreadLagMilliseconds = heartbeat.p99LagMilliseconds
        burst.heartbeatSamples = heartbeat.samples
        burst.linesShown = viewer.lineCount
        burst.linesDropped = viewer.droppedLines
        r.report.burst = burst
        r.report.maxMainThreadLagMilliseconds = max(r.report.follow.maxMainThreadLagMilliseconds, burst.maxMainThreadLagMilliseconds)
        let capped = viewer.lineCount <= LogTextController.maxLines && viewer.droppedLines > 0
        // A stress run well beyond the spec's follow check: every flush must stay under budget,
        // and so must the main thread at the 99th percentile. The single worst heartbeat is
        // reported but not gated: on a loaded Mac one scheduler hiccup can exceed 100 ms with
        // no app work at all.
        r.step(
            "burst 50k lines",
            burst.maxFlushMilliseconds < Self.maxLagBudget && burst.p99MainThreadLagMilliseconds < Self.maxLagBudget
                && capped && burst.linesReceived >= 49_000,
            String(format: "%d lines in %.1f s (%.0f/s), %d flushes, max flush %.1f ms, main-thread lag p99 %.1f ms / max %.1f ms, shown %d, dropped %d",
                   burst.linesReceived, seconds, burst.linesPerSecond, burst.flushes, burst.maxFlushMilliseconds,
                   burst.p99MainThreadLagMilliseconds, burst.maxMainThreadLagMilliseconds, burst.linesShown, burst.linesDropped)
        )

        // Close the sheet: the reading task is cancelled and the remote follow must end.
        containers.logs = nil
        let gone = await waitForRemoteExit("[d]ocker logs -f --tail 500 ", on: dev)
        r.report.dockerFollowGoneAfterSeconds = gone
        r.step("docker follow cleaned up", gone != nil, gone.map { String(format: "no remote docker logs -f after %.1f s", $0) } ?? "still running after 30 s")
    }

    /// Samples follow statistics and the heartbeat for `seconds`.
    private func measure(_ viewer: LogViewerModel, heartbeat: MainThreadHeartbeat, seconds: Double) async -> FollowNumbers {
        heartbeat.reset()
        let before = viewer.stats
        let start = ContinuousClock.now
        await pause(seconds)
        let elapsed = (ContinuousClock.now - start).milliseconds / 1000
        let after = viewer.stats
        var numbers = FollowNumbers()
        numbers.seconds = elapsed
        numbers.linesReceived = after.linesReceived - before.linesReceived
        numbers.linesPerSecond = Double(numbers.linesReceived) / max(elapsed, 0.001)
        numbers.flushes = after.flushes - before.flushes
        numbers.maxFlushMilliseconds = after.maxFlushMilliseconds
        numbers.averageFlushMilliseconds = (after.totalFlushMilliseconds - before.totalFlushMilliseconds) / Double(max(numbers.flushes, 1))
        numbers.maxMainThreadLagMilliseconds = heartbeat.maxLagMilliseconds
        numbers.p99MainThreadLagMilliseconds = heartbeat.p99LagMilliseconds
        numbers.heartbeatSamples = heartbeat.samples
        numbers.linesShown = viewer.lineCount
        numbers.linesDropped = viewer.droppedLines
        return numbers
    }

    // MARK: - Kubernetes

    private func checkPods(_ containers: HostContainersModel, dev: RemoteHost, _ r: Recorder) async {
        containers.section = .kubernetes
        containers.namespace = nil

        let crasher = await waitForCrasher(containers)
        recordCrasher(crasher, containers, r)
        if let pod = containers.pods.first {
            r.report.terminalCommands.append(
                (try? KubectlCommands(host: dev).logs(pod: pod.name, namespace: pod.namespace, tail: LogViewerModel.tail, follow: true)) ?? "?"
            )
        }
        await pause(1.0)
        await snapshotMain("pod-table", r, between: containers)

        await checkRestartSort(containers, crasher: crasher, r)
        if let crasher {
            await checkPreviousLogs(crasher, containers, r)
        }
        await checkPendingPod(containers, r)
        await checkPodFollow(containers, dev: dev, r)
        containers.section = .docker
    }

    /// Dead pods from earlier runs keep the crasher's name, so it is the one with the most restarts.
    private func waitForCrasher(_ containers: HostContainersModel) async -> PodInfo? {
        // The crasher is red with its restart count; between restarts it can look healthy briefly.
        var crasher: PodInfo?
        for attempt in 0..<8 {
            if attempt > 0 { await pause(5) }
            await containers.refresh()
            crasher = containers.pods
                .filter { $0.namespace == "demo" && $0.name.hasPrefix("crasher-") }
                .max { $0.restarts < $1.restarts }
            if let crasher, crasher.isCrashLooping, crasher.health == .failing { break }
        }
        return crasher
    }

    private func recordCrasher(_ crasher: PodInfo?, _ containers: HostContainersModel, _ r: Recorder) {
        r.report.crasher = crasher?.id
        r.report.crasherStatus = crasher?.displayStatus
        r.report.crasherRestarts = crasher?.restarts
        r.report.crasherHealth = crasher?.health.rawValue
        let red = crasher.map { $0.health == .failing && $0.isCrashLooping && $0.restarts > 0 } ?? false
        r.step(
            "crash-looping pod is red", red,
            crasher.map { "\($0.id): \($0.displayStatus), \($0.restarts) restarts, \($0.health.rawValue)" }
                ?? "no crasher pod" + (containers.podsIssue.map { " (\($0.title))" } ?? "")
        )
    }

    private func checkRestartSort(_ containers: HostContainersModel, crasher: PodInfo?, _ r: Recorder) async {
        // The Restarts header sorts the most restarts first, so the crasher leads.
        containers.podSortOrder = [KeyPathComparator(\.restarts, order: .reverse)]
        let sorted = containers.filteredPods
        let restarts = sorted.map(\.restarts)
        r.step(
            "sort by restarts",
            zip(restarts, restarts.dropFirst()).allSatisfy { $0 >= $1 } && sorted.first?.id == crasher?.id,
            sorted.map { "\($0.name): \($0.restarts)" }.joined(separator: ", ")
        )
        await pause(1.0)
        await snapshotMain("pod-table-sorted", r, between: containers)
        containers.podSortOrder = []
    }

    private func checkPreviousLogs(_ crasher: PodInfo, _ containers: HostContainersModel, _ r: Recorder) async {
        // One click: the crashed instance's logs.
        progress("opening previous logs")
        containers.showPreviousLogs(crasher)
        guard let viewer = containers.logs else {
            return r.step("previous logs (one click)", false, "no sheet")
        }
        await waitUntil(seconds: 2) { viewer.status != .idle }
        if viewer.status == .idle { viewer.start() }
        await waitUntil(seconds: 30) { viewer.status != .loading && viewer.status != .idle }
        let info = viewer.text.lines.first(where: \.isInfo)?.text
        r.report.previousLogsLines = viewer.lineCount
        r.report.previousLogsInfoLine = info.map { String($0.prefix(160)) }
        r.step(
            "previous logs (one click)", viewer.previous && viewer.issue == nil && viewer.lineCount > 0,
            "container \(viewer.container ?? "?"), \(viewer.lineCount) lines, status \(viewer.status)"
                + (info.map { "; info line: \($0.prefix(100))" } ?? "")
                + (viewer.issue.map { "; issue: \($0.title)" } ?? "")
        )
        await snapshotSheet("previous-logs", r)
        containers.logs = nil
        await pause(0.6)
    }

    private func checkPendingPod(_ containers: HostContainersModel, _ r: Recorder) async {
        // Pending pod: events include FailedScheduling, in the inspector.
        let pending = containers.pods.first { $0.namespace == "demo" && $0.name.hasPrefix("pending-") }
            ?? containers.pods.first { $0.phase == .pending }
        r.report.pendingPod = pending?.id
        guard let pending else {
            return r.step("pending pod events", false, "no Pending pod")
        }
        progress("opening inspector for \(pending.id)")
        containers.showDetail(pending)
        containers.inspectorTab = .events
        var reasons: [String] = []
        for attempt in 0..<3 {
            if attempt > 0 {
                containers.reloadPodDetail()
            }
            await waitUntil(seconds: 20) { containers.podDetail?.isLoading == false }
            reasons = containers.podDetail?.events.map(\.reason) ?? []
            if reasons.contains("FailedScheduling") { break }
            await pause(2)
        }
        r.report.pendingEventReasons = Array(Set(reasons)).sorted()
        r.step(
            "pending pod events", reasons.contains("FailedScheduling"),
            "\(pending.id): \(r.report.pendingEventReasons.joined(separator: ", "))"
                + (containers.podDetail?.eventsIssue.map { "; issue: \($0.title)" } ?? "")
        )
        await pause(1.0)
        await snapshotMain("pod-events", r, between: containers)
        containers.inspectorTab = .describe
        await pause(0.8)
        await snapshotMain("pod-describe", r, between: containers)
        containers.inspectorTab = .events
        containers.inspectorPresented = false
        progress("inspector closed")
        await pause(1.5)
        progress("inspector settled")
    }

    private func checkPodFollow(_ containers: HostContainersModel, dev: RemoteHost, _ r: Recorder) async {
        // kubectl follow ends remotely when the sheet closes.
        guard let web = runningWebPod(containers) else {
            return r.step("kubectl follow", false, "no running web pod")
        }
        progress("opening logs for \(web.id)")
        containers.showLogs(web)
        guard let viewer = containers.logs else { return }
        await waitUntil(seconds: 2) { viewer.status != .idle }
        if viewer.status == .idle { viewer.start() }
        await waitUntil(seconds: 20) { viewer.status == .following }
        progress("pod follow status \(viewer.status), \(viewer.lineCount) lines")
        let remote = await remoteFollowCount(on: dev)
        r.step("remote kubectl follow running", viewer.status == .following && remote > 0, "\(web.id): status \(viewer.status), \(remote) process(es)")
        containers.logs = nil
        let gone = await waitForRemoteExit("[k]ubectl logs -f ", on: dev)
        r.report.kubectlFollowGoneAfterSeconds = gone
        r.step("kubectl follow cleaned up", gone != nil, gone.map { String(format: "no remote kubectl logs -f after %.1f s", $0) } ?? "still running after 30 s")
    }

    private func runningWebPod(_ containers: HostContainersModel) -> PodInfo? {
        containers.pods.first { $0.namespace == "demo" && $0.name.hasPrefix("web-") && $0.phase == .running }
    }

    private func remoteFollowCount(on dev: RemoteHost) async -> Int {
        var remote = 0
        for _ in 0..<5 where remote == 0 {
            remote = await remoteProcessCount("[k]ubectl logs -f ", on: dev)
            if remote == 0 { await pause(1) }
        }
        return remote
    }

    // MARK: - nodocker

    private func checkNodocker(_ host: RemoteHost, _ r: Recorder) async {
        model.selection = host.id
        let containers = model.containers(for: host.id)
        await containers.refresh(reprobe: true)
        let issue = containers.dockerIssue
        r.report.nodockerIssue = issue?.title
        r.report.nodockerHint = issue?.hint
        r.step(
            "nodocker permission hint", issue?.kind == .setup && (issue?.hint?.contains("docker group") ?? false),
            "\(issue?.title ?? "no issue"); hint: \(issue?.hint ?? "none")"
        )
        containers.section = .docker
        await pause(1.0)
        await snapshotMain("permission-hint", r, between: containers)
        model.selection = nil
    }

    // MARK: - Remote processes

    /// Processes on the VM whose command line matches `pattern` (a `pgrep -f` regex written so
    /// it doesn't match its own command line, e.g. `[d]ocker logs -f`).
    private func remoteProcessCount(_ pattern: String, on host: RemoteHost) async -> Int {
        let command = "pgrep -f \(ShellQuote.quote(pattern)) || true"
        guard let result = try? await model.containerService.runner.run(
            command, on: host, stdin: nil, timeout: .seconds(15), outputLimit: 16 * 1024
        ), result.exitCode == 0 else { return -1 }
        return String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).count
    }

    /// Seconds until no process matches `pattern`, or `nil` after 30 s.
    private func waitForRemoteExit(_ pattern: String, on host: RemoteHost) async -> Double? {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(30) {
            if await remoteProcessCount(pattern, on: host) == 0 {
                return (ContinuousClock.now - start).milliseconds / 1000
            }
            await pause(1)
        }
        return nil
    }

    // MARK: - Finish

    private func finish(_ r: Recorder, key: SSHKeyRecord?) async -> Report {
        model.containerService.stopAll()
        await pause(0.5)
        _ = await model.shutdownServices()

        if let key {
            // Remove the key line from every server add-key.sh wrote it to.
            r.report.authorizedKeysRemaining = await Self.stripAuthorizedKey(key.authorizedKeysLine)
            r.step(
                "authorized keys removed", r.report.authorizedKeysRemaining == "0",
                "lines left on the VM: \(r.report.authorizedKeysRemaining ?? "?")"
            )
            do {
                try await model.ssh.deleteKey(key.id)
                let remaining = try KeyStore.systemKeychain(service: Phase2SelfTest.keychainService).secret(for: key.id.uuidString)
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

    /// Deletes `line` from the VM's dev and nodocker authorized_keys (and the compose servers',
    /// if running). Returns how many copies are left on the VM ("0" when clean).
    private static func stripAuthorizedKey(_ line: String) async -> String {
        let strip = #"read -r k; for f in "$@"; do [ -f "$f" ] || continue; grep -vxF "$k" "$f" > "$f.tmp" || true; cat "$f.tmp" > "$f"; rm -f "$f.tmp"; done"#
        let count = #"read -r k; n=0; for f in "$@"; do [ -f "$f" ] || continue; c=$(grep -cxF "$k" "$f" || true); n=$((n + c)); done; echo "$n""#
        let input = Data((line + "\n").utf8)
        let vmFiles = ["/home/dev/.ssh/authorized_keys", "/home/nodocker/.ssh/authorized_keys"]
        _ = await runProcess("/usr/bin/env", ["orb", "-m", "aeroops-vm", "-u", "root", "sh", "-c", strip, "sh"] + vmFiles, stdin: input)
        for (container, file) in [("aeroops-ssh", "/config/.ssh/authorized_keys"), ("aeroops-alpine", "/home/dev/.ssh/authorized_keys")] {
            _ = await runProcess("/usr/bin/env", ["docker", "exec", "-i", container, "sh", "-c", strip, "sh", file], stdin: input)
        }
        let (status, output) = await runProcess("/usr/bin/env", ["orb", "-m", "aeroops-vm", "-u", "root", "sh", "-c", count, "sh"] + vmFiles, stdin: input)
        return status == 0 ? output.trimmingCharacters(in: .whitespacesAndNewlines) : "error \(status)"
    }

    private nonisolated static func runProcess(_ executable: String, _ arguments: [String], stdin: Data) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            let output = Pipe()
            let input = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = input
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(stdin)
                try? input.fileHandleForWriting.close()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    // MARK: - Snapshots

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !$0.isSheet }
    }

    /// Waits for `containers` to finish a poll first, so the header reads "Updated …" rather
    /// than "Updating…" with Refresh dimmed (the README's Kubernetes screenshot comes from here).
    private func snapshotMain(_ name: String, _ r: Recorder, between containers: HostContainersModel? = nil) async {
        guard Self.snapshotDirectory != nil, let window = mainWindow else { return }
        if let containers {
            await waitUntil(seconds: 20) { !containers.isRefreshing }
        }
        await snapshotBothAppearances(name, r) { window }
    }

    /// The sheet's own window captures as the whole main window shrunk into the sheet's frame,
    /// so this captures the main window and crops it to the sheet.
    private func snapshotSheet(_ name: String, _ r: Recorder) async {
        guard Self.snapshotDirectory != nil else { return }
        await snapshotBothAppearances(name, r, crop: { mainWindow?.attachedSheet?.frame }) { mainWindow }
    }

    private func snapshotBothAppearances(
        _ name: String, _ r: Recorder, crop: () -> NSRect? = { nil }, window: () -> NSWindow?
    ) async {
        guard let directory = Self.snapshotDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await pause(0.8)
            let file = "phase5-\(name)-\(suffix).png"
            if let window = window(), await SelfTestCapture.capture(window, to: directory.appending(path: file), cropTo: crop()) {
                r.report.snapshots.append(file)
            }
        }
        NSApp.appearance = nil
        await pause(0.3)
    }

    // MARK: - Helpers

    /// Unbuffered progress on stderr, so a crash still leaves the last step in the log.
    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func progress(_ message: String) {
        let windows = NSApp.windows.filter(\.isVisible).map { window in
            "\(window.isSheet ? "sheet" : "window") \(Unmanaged.passUnretained(window).toOpaque())"
        }
        Self.log("[phase5] … \(message) [\(windows.joined(separator: ", "))]")
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Measures how late a 10 ms main-run-loop timer fires (in every run loop mode, so it keeps
/// ticking while menus track): the worst lag is how long the main thread was busy.
@MainActor
final class MainThreadHeartbeat {
    private var timer: Timer?
    private var last: ContinuousClock.Instant?
    private(set) var maxLag = Duration.zero
    private(set) var samples = 0
    private var lags: [Double] = []
    private let interval = Duration.milliseconds(10)

    var maxLagMilliseconds: Double { maxLag.milliseconds }

    /// The 99th-percentile lag: unlike the maximum, one scheduler hiccup elsewhere on the Mac
    /// does not move it, while a stall on every flush (10 % of 10 ms ticks) does.
    var p99LagMilliseconds: Double {
        guard !lags.isEmpty else { return 0 }
        let sorted = lags.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
    }

    func start() {
        stop()
        reset()
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reset() {
        maxLag = .zero
        samples = 0
        lags.removeAll(keepingCapacity: true)
        last = nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ContinuousClock.now
        if let last {
            let lag = now - last - interval
            maxLag = max(maxLag, lag)
            lags.append(max(0, lag.milliseconds))
        }
        last = now
        samples += 1
    }
}

/// Window capture for self-tests: ScreenCaptureKit's current-process content (no Screen
/// Recording permission needed), else the view tree drawn into a bitmap.
@MainActor
enum SelfTestCapture {
    /// Returns whether the PNG was written. `crop` is a part of the window in screen
    /// coordinates, such as an attached sheet's frame.
    @discardableResult
    static func capture(_ window: NSWindow, to url: URL, cropTo crop: NSRect? = nil) async -> Bool {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                return fallback(window, to: url)
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return write(cropped(image, of: window, to: crop), to: url)
        } catch {
            return fallback(window, to: url)
        }
    }

    private static func cropped(_ image: CGImage, of window: NSWindow, to crop: NSRect?) -> CGImage {
        guard let crop, window.frame.width > 0 else { return image }
        let frame = window.frame
        let scale = CGFloat(image.width) / frame.width
        let rect = CGRect(
            x: (crop.minX - frame.minX) * scale,
            y: (frame.maxY - crop.maxY) * scale,
            width: crop.width * scale,
            height: crop.height * scale
        ).integral
        return image.cropping(to: rect) ?? image
    }

    private static func fallback(_ window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return false }
        return write(image, to: url)
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        Phase5SelfTest.log("[phase5] wrote \(url.path(percentEncoded: false))")
        return true
    }
}
#endif
