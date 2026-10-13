#if DEBUG
import AeroCore
import AgentBridge
import AppKit
import BridgeProtocol
import Collectors
import Foundation
import KeyAgent
import SSHKit

/// `-AeroSelfTest phase7`: proves Phases 7 and 8 end to end in the built app, against the dev
/// servers (`docker compose -f dev/compose.yml up -d`, the OrbStack VM from `dev/vm`), with the
/// app's own signed `aeroops-mcp` as the client.
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest phase7 \
///   -AeroSelfTestOutput /tmp/aeroops-phase7.json \
///   -AeroSelfTestAuthorizeScript dev/add-key.sh \               # authorizes the new .pub
///   [-AeroSelfTestRevokeScript dev/remove-key.sh] \             # default: next to add-key.sh
///   [-AeroSelfTestDriveScript dev/selftest/phase7-drive.sh] \   # default: next to add-key.sh
///   [-AeroSelfTestKeepRoot YES]
/// ```
///
/// Runs under ``Phase2SelfTest``'s temporary root and Keychain service, so the bridge socket
/// (`<root>/d/bridge.sock`) is the self-test's own; `~/.aeroops` and the
/// user's agent configuration are never touched. Notifications are off for the run (no
/// permission prompt); the floating approval panel is shown as usual.
///
/// Hosts: `dev-container` (dev@localhost:2222, Read), `alpine` (dev@localhost:2223, Off) and
/// `staging` (dev@aeroops-vm.orb.local:22, Read + Exec, Docker as dev).
///
/// Steps: generate an Ed25519 key → authorize it → add the hosts and trust their keys
/// (automatic only here) → wait until all three are online → run `dev/selftest/phase7-drive.sh`
/// with `AEROOPS_BRIDGE_SOCKET` set: MCP Inspector CLI calls through the embedded `aeroops-mcp`
/// (the bridge's peer check runs as always), then one `claude -p` run per prompt in
/// ``prompts``. While it runs, the self-test answers each approval through
/// ``BridgeService/decide(_:_:)`` (the panel's path into `ApprovalCenter.decide`):
///
/// | call (staging unless noted)  | answer                                   | expected            |
/// | ---------------------------- | ---------------------------------------- | ------------------- |
/// | `uname -a` on dev-container  | none (Read host)                         | rejected, no prompt |
/// | `uname -a`                   | Allow once after 2 s                     | exit 0              |
/// | `uname -a` again             | Deny                                     | "denied" error      |
/// | `hostname`                   | Allow host for 15 minutes                | exit 0              |
/// | `uptime`                     | none (window)                            | allowed by window   |
/// | `sudo -n true`               | asked despite the window; Allow once, then Revoke All | runs   |
/// | `sleep 120`                  | Allow once; Cancel as the Activity tab does | remote process gone |
///
/// Then checks the live output in the Activity tab's model, the connection and agent events,
/// and shuts down, revokes and deletes the
/// key. An authentication failure ends the run at once (sshd's PerSourcePenalties). Writes a
/// JSON report (the driver's raw output is copied next to it, as `<name>-drive/`) and exits 0
/// on success, 1 otherwise.
@MainActor
struct Phase7SelfTest {
    private static var defaults: UserDefaults { .standard }
    static var isRequested: Bool { defaults.string(forKey: "AeroSelfTest") == "phase7" }
    static var driveScript: URL? {
        if let path = defaults.string(forKey: "AeroSelfTestDriveScript") { return URL(filePath: path) }
        return Phase2SelfTest.authorizeScript?.deletingLastPathComponent().appending(path: "selftest/phase7-drive.sh")
    }

    static let prompts = (
        memory: "which of my servers uses the most memory?",
        logs: "show the last 100 lines of the demo-logger container on staging"
    )
    static let sleepCommand = "sleep 120"
    static let onlineLimit: TimeInterval = 45
    static let driveLimit: TimeInterval = 15 * 60
    /// Longest a cancelled command may stay on the host (two heartbeats, then TERM and KILL).
    static let cancelLimit: TimeInterval = 10

    /// Before services start: approvals show the panel, but no notification permission prompt.
    static func configure(_ model: AppModel) {
        model.agents.postsNotifications = false
    }

    let model: AppModel

    // MARK: - Report

    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    /// One driver step: an inspector call or a `claude -p` run.
    struct Call: Codable {
        var step: String
        var exitStatus: Int32
        var seconds: Double
        var excerpt: String
    }

    struct Approval: Codable {
        var host: String
        var command: String
        var client: String
        var offersHostWindow: Bool
        var alwaysAsk: [String]
        var windowOpenWhenAsked: Bool
        var decision: String?
        var decidedAfterSeconds: Double?
        var applied: Bool?
    }

    struct Cancel: Codable {
        var remoteProcessesBefore: [String] = []
        var cancelAccepted = false
        var remoteGoneAfterSeconds: Double?
        var psFailures = 0
        var activityState = ""
    }

    struct ClaudeRun: Codable {
        var prompt: String
        var exitStatus: Int32
        var seconds: Double
        var turns: Int?
        var bridgeConnections: Int
        var answer: String
    }

    struct Report: Codable {
        var ok = false
        var root = ""
        var socket = ""
        var socketPathBytes = 0
        var mcpPath = ""
        var driveExitStatus: Int32?
        var peers: [String] = []
        var rejectedConnections: [String] = []
        var calls: [Call] = []
        var approvals: [Approval] = []
        var cancel: Cancel?
        var claude: [ClaudeRun] = []
        var agentSignEvents = 0
        var authFailed = false
        var privateKeyMaterialFound: [String] = []
        var steps: [Step] = []
    }

    private final class Recorder {
        var report = Report()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            report.steps.append(Step(name: name, ok: ok, detail: detail))
            print("[selftest] \(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }
    }

    /// Watches the dashboard's batches until each host is online; trusts first-contact keys as
    /// the trust sheet's Trust button would.
    @MainActor
    private final class HostWatch {
        var online: Set<UUID> = []
        var trustStarted: Set<UUID> = []
        var authFailure: String?
        var lastStatus: [UUID: String] = [:]
        let hosts: [UUID: RemoteHost]
        var onUnknownKey: ((RemoteHost) -> Void)?

        init(_ hosts: [RemoteHost]) {
            self.hosts = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        }

        func receive(_ updates: [HostMonitorUpdate]) {
            for update in updates {
                guard let host = hosts[update.hostID] else { continue }
                lastStatus[host.id] = "\(update.status)" + (update.lastError.map { " (\($0.localizedDescription))" } ?? "")
                if update.snapshot != nil, update.status == .online { online.insert(host.id) }
                if update.lastError == .authFailed, authFailure == nil {
                    authFailure = "\(host.name): \(SSHError.authFailed.localizedDescription)"
                }
                if update.hostKeyIssue == .unknown, trustStarted.insert(host.id).inserted {
                    onUnknownKey?(host)
                }
            }
        }
    }

    /// Answers approvals the way the panel's buttons do, by command.
    @MainActor
    private final class Approver {
        let agents: BridgeService
        let staging: RemoteHost
        var records: [Approval] = []
        var unexpected: [String] = []
        private var seen: Set<UUID> = []
        private var unameCount = 0

        init(agents: BridgeService, staging: RemoteHost) {
            self.agents = agents
            self.staging = staging
        }

        func receive(_ snapshot: ApprovalSnapshot) {
            for approval in snapshot.pending where seen.insert(approval.id).inserted {
                handle(approval, windowOpen: snapshot.windows.contains { $0.hostID == approval.hostID })
            }
        }

        private func handle(_ approval: PendingApproval, windowOpen: Bool) {
            let index = records.count
            records.append(Approval(
                host: approval.hostName, command: approval.command, client: approval.clientLabel,
                offersHostWindow: approval.offersHostWindow, alwaysAsk: approval.alwaysAskReasons.map(\.rawValue),
                windowOpenWhenAsked: windowOpen))
            var revokeAfter = false
            let decision: ApprovalDecision
            let delay: Duration
            switch (approval.hostID == staging.id, approval.command) {
            case (true, "uname -a"):
                unameCount += 1
                (decision, delay) = unameCount == 1 ? (.allowOnce, .seconds(2)) : (.deny, .seconds(1))
            case (true, "hostname"):
                (decision, delay) = (.allowHost15Min, .seconds(1))
            case (true, "sudo -n true"):
                (decision, delay) = (.allowOnce, .seconds(1))
                revokeAfter = true
            case (true, Phase7SelfTest.sleepCommand):
                (decision, delay) = (.allowOnce, .seconds(1))
            default:
                unexpected.append("\(approval.hostName): \(approval.command)")
                (decision, delay) = (.deny, .zero)
            }
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                let applied = await agents.decide(approval.id, decision)
                records[index].decision = decision.rawValue
                records[index].decidedAfterSeconds = Phase7SelfTest.rounded(Date.now.timeIntervalSince(approval.requestedAt))
                records[index].applied = applied
                if revokeAfter {
                    // Settings › MCP's "Revoke All Allow Windows".
                    await agents.revokeAllWindows()
                }
            }
        }
    }

    /// Cancels `sleep 120` the way the Activity tab's Cancel button does, after checking with
    /// `ps` over ssh that it runs on the host, then waits until it is gone there.
    @MainActor
    private final class Canceller {
        let agents: BridgeService
        let runner: SSHRunner
        let host: RemoteHost
        var result = Cancel()
        private(set) var started = false
        private(set) var done = false

        init(agents: BridgeService, runner: SSHRunner, host: RemoteHost) {
            self.agents = agents
            self.runner = runner
            self.host = host
        }

        func receive(_ activity: CommandActivity) {
            guard case .started(let command) = activity, command.command == Phase7SelfTest.sleepCommand, !started else { return }
            started = true
            Task { @MainActor in await cancel(command) }
        }

        private func cancel(_ command: RunningCommand) async {
            try? await Task.sleep(for: .seconds(4))
            result.remoteProcessesBefore = await remoteProcesses() ?? []
            result.cancelAccepted = await agents.cancel(command.id)
            let start = Date.now
            while Date.now.timeIntervalSince(start) < Phase7SelfTest.cancelLimit * 2 {
                try? await Task.sleep(for: .seconds(1))
                if let processes = await remoteProcesses(), processes.isEmpty {
                    result.remoteGoneAfterSeconds = Phase7SelfTest.rounded(Date.now.timeIntervalSince(start))
                    break
                }
            }
            result.activityState = agents.liveCommands.first { $0.id == command.id }.map { "\($0.state)" } ?? "not in the Activity tab"
            done = true
        }

        /// `ps` lines on the host that mention the command; `nil` when ps could not run.
        private func remoteProcesses() async -> [String]? {
            guard let output = try? await runner.run(arguments: ["ps", "-eo", "pid=,pgid=,args="], on: host, timeout: .seconds(10)),
                  output.exitCode == 0 else {
                result.psFailures += 1
                return nil
            }
            return String(decoding: output.stdout, as: UTF8.self)
                .split(separator: "\n")
                .filter { $0.contains(Phase7SelfTest.sleepCommand) }
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(120)) }
        }
    }

    /// One line of the driver's `steps.tsv` with its output.
    private struct DriveStep {
        let name: String
        let status: Int32
        let seconds: Double
        let start: Date
        let stdout: String
        let stderr: String

        static func load(_ directory: URL) -> [DriveStep] {
            guard let table = try? String(contentsOf: directory.appending(path: "steps.tsv"), encoding: .utf8) else { return [] }
            return table.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 4, let status = Int32(fields[1]), let seconds = Double(fields[2]),
                      let start = Double(fields[3]) else { return nil }
                let id = fields[0]
                func read(_ suffix: String) -> String {
                    (try? String(contentsOf: directory.appending(path: "\(id).\(suffix)"), encoding: .utf8)) ?? ""
                }
                return DriveStep(name: String(id.drop { $0 != "-" }.dropFirst()), status: status, seconds: seconds,
                                 start: Date(timeIntervalSince1970: start), stdout: read("out"), stderr: read("err"))
            }
        }

        /// The JSON object printed on stdout (the inspector's result, or claude's).
        var json: [String: Any]? {
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidates = [trimmed] + (trimmed.firstIndex(of: "{").map { [String(trimmed[$0...])] } ?? [])
            for candidate in candidates {
                if let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any] { return object }
            }
            return nil
        }

        var structured: [String: Any]? { json?["structuredContent"] as? [String: Any] }
        var isError: Bool { json?["isError"] as? Bool ?? (status != 0) }

        /// The result's text content, or the raw output when there is none.
        var text: String {
            let parts = (json?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
            return parts.isEmpty ? stdout + stderr : parts.joined(separator: "\n")
        }

        var excerpt: String {
            let source = text.isEmpty ? stderr : text
            return String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        }
    }

    // MARK: - Run

    func runAndQuit() async {
        let report = await run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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
        let agents = model.agents
        let socket = agents.socketURL.path(percentEncoded: false)
        r.report.root = Phase2SelfTest.root.path(percentEncoded: false)
        r.report.socket = socket
        r.report.socketPathBytes = socket.utf8.count
        r.report.mcpPath = MCPClientConfig.executablePath

        guard case .running = ssh.agentStatus, model.monitoring.isRunning, agents.status == .listening else {
            r.step("services", false, "agent \(ssh.agentStatus), monitoring running \(model.monitoring.isRunning), bridge \(agents.status)")
            return await finish(r, key: nil)
        }
        r.step("services", socket.utf8.count <= 104,
               "agent running, monitoring started, bridge listening on \(socket) (\(socket.utf8.count) bytes, limit 104)")
        let fileManager = FileManager.default
        guard let script = Self.driveScript, fileManager.isExecutableFile(atPath: script.path(percentEncoded: false)),
              fileManager.isExecutableFile(atPath: r.report.mcpPath) else {
            r.step("driver", false, "need an executable -AeroSelfTestDriveScript (\(Self.driveScript?.path(percentEncoded: false) ?? "none")) and \(r.report.mcpPath)")
            return await finish(r, key: nil)
        }

        // 1. Key: Ed25519 in the self-test Keychain service, policy "always" (no Touch ID).
        let key: SSHKeyRecord
        do {
            key = try await ssh.generateKey(.ed25519, name: "AeroOps phase 7 self-test", policy: .always)
        } catch {
            r.step("generate key", false, error.localizedDescription)
            return await finish(r, key: nil)
        }
        r.step("generate key", true, "\(key.algorithm.displayName) \(key.fingerprint)")

        // 2. Authorize it on every dev server.
        let pub = ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
        if let authorize = Phase2SelfTest.authorizeScript {
            let (status, output) = await Phase2SelfTest.runProcess(authorize, arguments: [pub.path(percentEncoded: false)])
            r.step("authorize key", status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
            guard status == 0 else { return await finish(r, key: key) }
        } else {
            r.step("authorize key", true, "skipped: no -AeroSelfTestAuthorizeScript (key must already be authorized)")
        }

        // 3. Hosts, one per tier; trust first-contact keys; wait until all are online.
        let keyID = key.id.uuidString
        let devContainer = RemoteHost(name: "dev-container", address: "localhost", port: 2222, user: "dev", keyId: keyID, mcpTier: .read)
        let alpine = RemoteHost(name: "alpine", address: "localhost", port: 2223, user: "dev", keyId: keyID, mcpTier: .off)
        let staging = RemoteHost(name: "staging", address: "aeroops-vm.orb.local", port: 22, user: "dev", keyId: keyID,
                                 dockerSudo: false, mcpTier: .readExec)
        let hosts = [devContainer, alpine, staging]
        let watch = HostWatch(hosts)
        let monitoring = model.monitoring
        watch.onUnknownKey = { host in
            Task { @MainActor in
                await monitoring.requestHostKeyTrust(for: host)
                guard let request = monitoring.trustRequest, request.id == host.id else { return }
                do {
                    try await monitoring.trust(request)
                } catch {
                    print("[selftest] trust \(host.name) failed: \(error.localizedDescription)")
                }
            }
        }
        monitoring.didApplyUpdates = { watch.receive($0) }
        defer { monitoring.didApplyUpdates = nil }
        do {
            for host in hosts { try model.addHost(host) }
            model.selection = nil
        } catch {
            r.step("add hosts", false, error.localizedDescription)
            return await finish(r, key: key)
        }
        let online = await waitUntil(seconds: Self.onlineLimit) {
            watch.authFailure != nil || hosts.allSatisfy { watch.online.contains($0.id) }
        }
        if let failure = watch.authFailure {
            r.report.authFailed = true
            r.step("authentication", false, "\(failure); stopping now (sshd PerSourcePenalties)")
            return await finish(r, key: key)
        }
        r.step("hosts online", online, hosts.map { "\($0.name) [\($0.mcpTier.rawValue)]: \(watch.lastStatus[$0.id] ?? "no update")" }.joined(separator: ", "))
        guard online else { return await finish(r, key: key) }

        // 4. The driver, with the approval answers and the cancel wired in.
        let approver = Approver(agents: agents, staging: staging)
        let canceller = Canceller(agents: agents, runner: ssh.runner, host: staging)
        agents.didUpdateApprovals = { approver.receive($0) }
        agents.didReceiveCommandActivity = { canceller.receive($0) }
        defer {
            agents.didUpdateApprovals = nil
            agents.didReceiveCommandActivity = nil
        }
        let results = Phase2SelfTest.root.appending(path: "drive", directoryHint: .isDirectory)
        let driveStart = Date.now
        let status = await drive(script: script, results: results, socket: socket)
        r.report.driveExitStatus = status
        r.step("driver", status == 0, "\(script.lastPathComponent) exited \(status) after \(Self.rounded(Date.now.timeIntervalSince(driveStart))) s")
        await waitUntil(seconds: 30) { !canceller.started || canceller.done }
        try? await Task.sleep(for: .milliseconds(500))  // let the last events land
        copyDriveOutput(results)

        let steps = DriveStep.load(results)
        r.report.calls = steps.map { Call(step: $0.name, exitStatus: $0.status, seconds: $0.seconds, excerpt: $0.excerpt) }
        r.report.approvals = approver.records
        r.report.cancel = canceller.result
        let byName = Dictionary(steps.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        checkReadTools(r, byName)
        checkRunCommand(r, byName, approver: approver, canceller: canceller)
        checkClaude(r, byName)
        checkActivity(r)

        return await finish(r, key: key)
    }

    // MARK: - Driver

    /// Runs the driver script; its output goes to `drive.log` in `results`. Killed after
    /// ``driveLimit``.
    private func drive(script: URL, results: URL, socket: String) async -> Int32 {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: results, withIntermediateDirectories: true)
        let logURL = results.appending(path: "drive.log")
        fileManager.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        defer { try? log?.close() }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path(percentEncoded: false), MCPClientConfig.executablePath, results.path(percentEncoded: false)]
        // A self-test started from a Claude Code session must not look nested to `claude -p`.
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            key != "CLAUDECODE" && !key.hasPrefix("CLAUDE_CODE_")
        }
        environment["AEROOPS_BRIDGE_SOCKET"] = socket
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice

        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.driveLimit))
            if !Task.isCancelled, process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                print("[selftest] driver did not start: \(error.localizedDescription)")
                continuation.resume(returning: -1)
            }
        }
    }

    /// Copies the driver's raw output next to the report (`<report>-drive/`): the root is removed.
    private func copyDriveOutput(_ results: URL) {
        guard let output = Phase2SelfTest.outputURL else { return }
        let destination = output.deletingPathExtension().appendingPathExtension("drive")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: results, to: destination)
    }

    // MARK: - Checks

    private func checkReadTools(_ r: Recorder, _ steps: [String: DriveStep]) {
        if let step = steps["tools-list"] {
            let names = Set((step.json?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [])
            let expected = Set(BridgeTool.allCases.map(\.rawValue))
            r.step("tools/list", step.status == 0 && names == expected, "exit \(step.status): \(names.sorted().joined(separator: ", "))")
        } else {
            r.step("tools/list", false, "the driver did not run it")
        }

        if let step = steps["list-hosts"] {
            let names = (step.structured?["hosts"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            r.step("list_hosts", !step.isError && names == ["dev-container", "staging"],
                   "exit \(step.status): \(names.joined(separator: ", ")) (alpine is Off, so hidden)")
        } else {
            r.step("list_hosts", false, "the driver did not run it")
        }

        for host in ["dev-container", "staging"] {
            guard let step = steps["metrics-\(host)"] else {
                r.step("get_host_metrics \(host)", false, "the driver did not run it")
                continue
            }
            let memory = step.structured?["memory"] as? [String: Any]
            let used = (memory?["usedBytes"] as? NSNumber)?.int64Value ?? 0
            let total = (memory?["totalBytes"] as? NSNumber)?.int64Value ?? 0
            let age = (step.structured?["ageSeconds"] as? NSNumber)?.intValue
            r.step("get_host_metrics \(host)", !step.isError && used > 0 && total >= used,
                   "exit \(step.status): memory \(Self.mebibytes(used)) of \(Self.mebibytes(total)) MiB, sample age \(age.map(String.init) ?? "-") s")
        }

        if let step = steps["metrics-alpine"] {
            r.step("get_host_metrics alpine (Off)", step.isError && step.text.contains("not shared"), "exit \(step.status): \(step.excerpt)")
        } else {
            r.step("get_host_metrics alpine (Off)", false, "the driver did not run it")
        }

        if let step = steps["containers-staging"] {
            let rows = step.structured?["containers"] as? [[String: Any]] ?? []
            func row(_ name: String) -> [String: Any]? { rows.first { $0["name"] as? String == name } }
            let running = ["demo-web", "demo-logger"].compactMap(row)
            let withStats = running.filter { $0["cpuPercent"] != nil && $0["memUsedBytes"] != nil }
            let exited = row("demo-exited")
            let summary = rows.map { row in
                let cpu = (row["cpuPercent"] as? NSNumber).map { "\($0.doubleValue)%" } ?? "-"
                let memory = (row["memUsedBytes"] as? NSNumber).map { "\(Self.mebibytes($0.int64Value)) MiB" } ?? "-"
                return "\(row["name"] as? String ?? "?") \(row["state"] as? String ?? "?") cpu \(cpu) mem \(memory)"
            }
            r.step("list_containers staging", !step.isError && running.count == 2 && withStats.count == 2 && exited?["state"] as? String == "exited",
                   "exit \(step.status): \(summary.joined(separator: "; "))")
        } else {
            r.step("list_containers staging", false, "the driver did not run it")
        }

        if let step = steps["logs-demo-logger"] {
            let text = step.text
            let lines = Self.untrustedBody(text)?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
            let header = text.split(separator: "\n").first.map(String.init) ?? ""
            let clean = !text.unicodeScalars.contains { $0.value == 0x1B }
            r.step("get_logs demo-logger", !step.isError && lines == 100 && clean && header.contains("untrusted"),
                   "exit \(step.status): \(lines) lines between the untrusted markers, ANSI escapes \(clean ? "none" : "present"); header: \(header)")
        } else {
            r.step("get_logs demo-logger", false, "the driver did not run it")
        }
    }

    private func checkRunCommand(_ r: Recorder, _ steps: [String: DriveStep], approver: Approver, canceller: Canceller) {
        let approvals = approver.records
        func asked(_ command: String) -> [Approval] { approvals.filter { $0.command == command } }
        func exitCode(_ step: DriveStep) -> Int? { (step.structured?["exitCode"] as? NSNumber)?.intValue }
        func missing(_ name: String) { r.step(name, false, "the driver did not run it") }

        if let step = steps["run-read-host"] {
            let prompted = approvals.contains { $0.host == "dev-container" }
            r.step("run_command on Read host", step.isError && step.text.contains("read tools only") && !prompted,
                   "rejected without asking: \(!prompted); \(step.excerpt)")
        } else { missing("run_command on Read host") }

        let uname = asked("uname -a")
        if let step = steps["run-allow-once"] {
            let stdout = step.structured?["stdout"] as? String ?? ""
            let first = uname.first
            r.step("run_command allow once", !step.isError && exitCode(step) == 0 && stdout.contains("Linux")
                    && first?.decision == ApprovalDecision.allowOnce.rawValue && first?.applied == true && (first?.decidedAfterSeconds ?? 0) >= 2,
                   "decision \(first?.decision ?? "none") after \(first?.decidedAfterSeconds.map { "\($0)" } ?? "-") s, exit \(exitCode(step).map(String.init) ?? "-"): \(stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else { missing("run_command allow once") }

        if let step = steps["run-denied"] {
            let second = uname.dropFirst().first
            r.step("run_command denied", step.isError && step.text.contains("denied") && second?.decision == ApprovalDecision.deny.rawValue,
                   "decision \(second?.decision ?? "none"); agent sees: \(step.excerpt)")
        } else { missing("run_command denied") }

        if let step = steps["run-allow-window"] {
            let approval = asked("hostname").first
            r.step("run_command allow host 15 min", !step.isError && exitCode(step) == 0 && approval?.decision == ApprovalDecision.allowHost15Min.rawValue
                    && approval?.offersHostWindow == true,
                   "decision \(approval?.decision ?? "none"), exit \(exitCode(step).map(String.init) ?? "-")")
        } else { missing("run_command allow host 15 min") }

        if let step = steps["run-in-window"] {
            let prompted = !asked("uptime").isEmpty
            r.step("run_command inside window", !step.isError && exitCode(step) == 0 && !prompted,
                   "ran without asking: \(!prompted), exit \(exitCode(step).map(String.init) ?? "-")")
        } else { missing("run_command inside window") }

        if let step = steps["run-sudo"] {
            let approval = asked("sudo -n true").first
            r.step("sudo asks inside window", !step.isError && approval?.windowOpenWhenAsked == true && approval?.offersHostWindow == false
                    && approval?.alwaysAsk.contains(AlwaysAskReason.sudo.rawValue) == true && approval?.decision == ApprovalDecision.allowOnce.rawValue,
                   "asked with window open \(approval?.windowOpenWhenAsked ?? false), 15-minute option offered \(approval?.offersHostWindow ?? true), "
                    + "reasons \(approval?.alwaysAsk ?? []), decision \(approval?.decision ?? "none"), exit \(exitCode(step).map(String.init) ?? "-") (sudoers allows only k3s kubectl)")
        } else { missing("sudo asks inside window") }

        if let step = steps["run-cancelled"] {
            let approval = asked(Self.sleepCommand).first
            let cancel = canceller.result
            let gone = cancel.remoteGoneAfterSeconds.map { $0 <= Self.cancelLimit } ?? false
            r.step("cancel from Activity", step.isError && step.text.contains("cancelled") && approval != nil && cancel.cancelAccepted
                    && !cancel.remoteProcessesBefore.isEmpty && gone && cancel.activityState == "cancelled(byUser: true)",
                   "asked again after Revoke All: \(approval != nil); on host before cancel: \(cancel.remoteProcessesBefore.count) processes; "
                    + "cancel accepted \(cancel.cancelAccepted); gone from host after \(cancel.remoteGoneAfterSeconds.map { "\($0)" } ?? "-") s "
                    + "(limit \(Int(Self.cancelLimit)) s); Activity shows \(cancel.activityState); agent sees: \(step.excerpt)")
        } else { missing("cancel from Activity") }

        r.step("windows revoked", model.agents.windows.isEmpty, "\(model.agents.windows.count) allow windows open at the end")
        r.step("no unexpected approvals", approver.unexpected.isEmpty && approvals.allSatisfy { $0.applied == true },
               "\(approvals.count) approvals, all answered: \(approvals.allSatisfy { $0.applied == true })"
                + (approver.unexpected.isEmpty ? "" : "; unexpected (denied): \(approver.unexpected)"))
    }

    /// Each `claude -p` run answered, and connected to the bridge (through `aeroops-mcp`) while it ran.
    private func checkClaude(_ r: Recorder, _ steps: [String: DriveStep]) {
        let runs = [("claude-memory", Self.prompts.memory), ("claude-logs", Self.prompts.logs)]
        for (name, prompt) in runs {
            guard let step = steps[name] else {
                r.step("claude -p \"\(prompt)\"", false, "the driver did not run it")
                continue
            }
            let answer = (step.json?["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let failed = step.json?["is_error"] as? Bool ?? true
            let turns = (step.json?["num_turns"] as? NSNumber)?.intValue
            let start = step.start.addingTimeInterval(-1)
            let end = step.start.addingTimeInterval(step.seconds + 1)
            let connections = model.agents.connectionEvents.filter { record in
                guard case .connected = record.kind else { return false }
                return record.date >= start && record.date <= end
            }.count
            r.report.claude.append(ClaudeRun(prompt: prompt, exitStatus: step.status, seconds: step.seconds, turns: turns,
                                             bridgeConnections: connections, answer: answer))
            let ok = step.status == 0 && !failed && !answer.isEmpty && connections > 0
            r.step("claude -p \"\(prompt)\"", ok,
                   "exit \(step.status), \(turns.map(String.init) ?? "-") turns, \(connections) bridge connections; answer: \(answer.prefix(240))"
                    + (answer.isEmpty ? "; stderr: \(step.stderr.prefix(300))" : ""))
        }
    }

    /// Connections came from the real signed `aeroops-mcp`, the agent signed, and live output
    /// reached the Activity tab's model.
    private func checkActivity(_ r: Recorder) {
        let agents = model.agents
        var peers: [BridgePeer] = []
        var rejected: [String] = []
        for record in agents.connectionEvents {
            switch record.kind {
            case .connected(let peer): peers.append(peer)
            case .rejected(let reason): rejected.append(reason)
            case .protocolError, .disconnected: break
            }
        }
        r.report.peers = Array(Set(peers.map(\.summary))).sorted()
        r.report.rejectedConnections = rejected
        let signed = peers.allSatisfy { $0.trust == .codeSignature && $0.signingIdentifier == "app.aeroops.mcp" }
        r.step("peer check", !peers.isEmpty && signed && rejected.isEmpty,
               "\(peers.count) connections, all code-signature trusted aeroops-mcp: \(signed); rejected \(rejected.count)"
                + (peers.first.map { "; e.g. \($0.summary)" } ?? ""))

        let signs = model.ssh.agentEvents.filter { if case .signed = $0.kind { true } else { false } }.count
        r.report.agentSignEvents = signs
        r.step("agent events", signs > 0 && !agents.connectionEvents.isEmpty,
               "\(signs) agent signatures and \(agents.connectionEvents.count) bridge connection events")

        let uname = agents.liveCommands.first { $0.command == "uname -a" }
        let output = uname?.segments.filter { $0.stream == .stdout }.map(\.text).joined() ?? ""
        let finished = if case .finished(exitCode: 0, _)? = uname?.state { true } else { false }
        r.step("live output", finished && output.contains("Linux"),
               "\(agents.liveCommands.count) commands in the Activity tab; uname -a \(uname.map { "\($0.state)" } ?? "missing"): \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))")
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

        let bridgeSocket = model.agents.socketURL
        let closed = await model.shutdownServices()
        let agentSocketGone = !FileManager.default.fileExists(atPath: paths.agentSocket.path(percentEncoded: false))
        let bridgeSocketGone = !FileManager.default.fileExists(atPath: bridgeSocket.path(percentEncoded: false))
        r.step("shutdown", agentSocketGone && bridgeSocketGone && !model.monitoring.isRunning && model.agents.status == .stopped,
               "bridge stopped first, monitoring stopped, masters closed \(closed), agent socket removed \(agentSocketGone), bridge socket removed \(bridgeSocketGone)")

        if let key {
            let pub = paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
            // Revoke before deleting: the script reads the .pub.
            if let script = Phase3SelfTest.revokeScript, Phase2SelfTest.authorizeScript != nil {
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

    /// The text between a get_logs reply's untrusted markers, without the final newline.
    private static func untrustedBody(_ text: String) -> String? {
        guard let begin = text.range(of: "----- BEGIN UNTRUSTED LOG OUTPUT"),
              let lineEnd = text[begin.upperBound...].firstIndex(of: "\n"),
              let end = text.range(of: "\n----- END UNTRUSTED LOG OUTPUT", range: lineEnd..<text.endIndex) else { return nil }
        return String(text[text.index(after: lineEnd)..<end.lowerBound])
    }

    private static func mebibytes(_ bytes: Int64) -> Int64 { bytes / (1 << 20) }

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

    /// Rounds to three decimals (milliseconds) for the report.
    static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
#endif
