#if DEBUG
import AeroCore
import AppKit
import Darwin
import Foundation
import KeyAgent
import SSHKit
import Synchronization

/// `-AeroSelfTest phase2`: proves Phase 2's "Done when" end to end in the built app, without
/// clicking, against the dev SSH server (`dev@localhost:2222`, `docker compose -f dev/compose.yml up -d`).
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest phase2 \
///   -AeroSelfTestOutput /tmp/aeroops-selftest.json \
///   -AeroSelfTestAuthorizeScript dev/add-key.sh \   # authorizes the new .pub on the dev server
///   [-AeroSelfTestRevokeScript dev/remove-key.sh] \ # default: remove-key.sh next to the authorize script
///   [-AeroSelfTestKeepRoot YES]                      # keep the temporary root for inspection
/// ```
///
/// Everything runs under a fresh `mkdtemp` root in `/tmp` (short, so socket paths stay under
/// 104 bytes) instead of `~/.aeroops` and Application Support, with keys in a separate Keychain
/// service (``keychainService``). The real inventory, keys and `~/.aeroops` are not touched.
///
/// Steps: start services → generate an Ed25519 key (policy "always", so no Touch ID) → authorize
/// its .pub → add the host → Test connection (expects first contact) → trust the scanned keys →
/// Test connection (expects success) → a ControlMaster run → a simulated changed host key (expects
/// the host to be blocked and never contacted) → scan for private key material on disk →
/// shutdown → revoke the .pub on the dev servers → delete the key and the root. Writes a JSON
/// report (`"ok": true` on success) and quits.
///
/// Not covered: Touch ID prompts (policy "always" never asks) and Secure Enclave keys.
@MainActor
struct Phase2SelfTest {
    static let keychainService = "app.aeroops.keys.selftest"

    private static var defaults: UserDefaults { .standard }
    static var outputURL: URL? { defaults.string(forKey: "AeroSelfTestOutput").map { URL(filePath: $0) } }
    static var authorizeScript: URL? { defaults.string(forKey: "AeroSelfTestAuthorizeScript").map { URL(filePath: $0) } }
    static var keepsRoot: Bool { defaults.bool(forKey: "AeroSelfTestKeepRoot") }

    /// The temporary root, created on first use: `/tmp/aero-st-XXXXXX`.
    static let root: URL = {
        var template = Array("/tmp/aero-st-XXXXXX".utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let result = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: result)
        }
        return URL(filePath: path ?? "/tmp/aero-st-fallback-\(getpid())", directoryHint: .isDirectory)
    }()

    static var paths: AeroPaths {
        AeroPaths(
            dotDirectory: root.appending(path: "d", directoryHint: .isDirectory),
            applicationSupport: root.appending(path: "s", directoryHint: .isDirectory)
        )
    }

    /// Self-test keys sign without asking ("Never ask"), so any request for user presence is a
    /// bug: it is recorded and denied here instead of showing a real Touch ID prompt.
    static let presenceVerifier = SelfTestPresenceVerifier()

    static func makeModel() -> AppModel {
        let ssh = SSHServices(
            paths: paths, keychain: KeyStore.systemKeychain(service: keychainService), defaults: nil,
            authorizer: PolicySigningAuthorizer(verifier: presenceVerifier)
        )
        return AppModel(hostStore: .inMemory(), ssh: ssh)
    }

    let model: AppModel

    // MARK: - Report

    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    struct Report: Codable {
        var ok = false
        var root = ""
        var agentSocket = ""
        var agentSocketBytes = 0
        var keyID: String?
        var keyAlgorithm: String?
        var keyFingerprint: String?
        var publicKeyFile: String?
        var hostKeyFingerprints: [String] = []
        var connectionMessage: String?
        var connectionMilliseconds: Int?
        var agentEvents: [String] = []
        var controlMastersClosed: Int?
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

    // MARK: - Run

    func runAndQuit() async {
        let report = await run()
        if let url = Self.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                try? data.write(to: url, options: .atomic)
            }
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED")")
        // Quit through the normal path (AppDelegate), as a menu Quit would.
        NSApp.terminate(nil)
    }

    func run() async -> Report {
        let r = Recorder()
        let ssh = model.ssh
        r.report.root = Self.root.path(percentEncoded: false)
        r.report.agentSocket = ssh.paths.agentSocket.path(percentEncoded: false)
        r.report.agentSocketBytes = r.report.agentSocket.utf8.count

        guard checkAgentRunning(r), let key = await generateKey(r) else { return await finish(r, key: nil) }
        await Self.authorize(key, ssh: ssh, step: r.step)
        await checkConnection(key, r)
        return await finish(r, key: key)
    }

    private func checkAgentRunning(_ r: Recorder) -> Bool {
        let ssh = model.ssh
        // 1. Services: agent socket up, ssh_config written.
        let socketExists = FileManager.default.fileExists(atPath: r.report.agentSocket)
        if case .running = ssh.agentStatus, socketExists, r.report.agentSocketBytes < 104 {
            r.step("agent running", true, "\(r.report.agentSocket) (\(r.report.agentSocketBytes) bytes)")
            return true
        }
        r.step("agent running", false, "status \(ssh.agentStatus), socket exists \(socketExists)")
        return false
    }

    private func generateKey(_ r: Recorder) async -> SSHKeyRecord? {
        let ssh = model.ssh
        // 2. Generate an Ed25519 key in the Keychain; the .pub is written, the secret is not.
        let key: SSHKeyRecord
        do {
            key = try await ssh.generateKey(.ed25519, name: "AeroOps self-test", policy: .always, syncs: false)
        } catch {
            r.step("generate key", false, error.localizedDescription)
            return nil
        }
        let pubURL = ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
        let pubText = (try? String(contentsOf: pubURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inKeychain = (try? KeyStore.systemKeychain(service: Self.keychainService).secret(for: key.id.uuidString)) != nil
        r.report.keyID = key.id.uuidString
        r.report.keyAlgorithm = key.algorithm.displayName
        r.report.keyFingerprint = key.fingerprint
        r.report.publicKeyFile = pubURL.path(percentEncoded: false)
        r.step(
            "generate key", pubText == key.authorizedKeysLine && inKeychain,
            "\(key.algorithm.displayName) \(key.fingerprint); .pub matches \(pubText == key.authorizedKeysLine); Keychain item \(inKeychain)"
        )

        return key
    }

    private func checkConnection(_ key: SSHKeyRecord, _ r: Recorder) async {
        guard let host = addHost(key, r),
              let offered = await firstContact(host, r),
              await trust(offered, for: host, r),
              await testConnection(host, r)
        else { return }
        await checkControlMaster(host, r)
        await checkAgentEvents(key, r)
        await checkChangedKey(r, host: host, realKeys: offered)
    }

    private func addHost(_ key: SSHKeyRecord, _ r: Recorder) -> RemoteHost? {
        // 4. Add the host through the model; the inventory observer rewrites ssh_config.
        let host = RemoteHost(name: "Self-test dev", address: "localhost", port: 2222, user: "dev", keyId: key.id.uuidString)
        do {
            try model.addHost(host)
            let config = (try? String(contentsOf: model.ssh.paths.sshConfig, encoding: .utf8)) ?? ""
            let ok = config.contains("Host \(host.sshAlias)")
                && config.contains("IdentityAgent \(r.report.agentSocket)")
                && config.contains("\(key.id.uuidString).pub")
            r.step("ssh_config", ok, "alias \(host.sshAlias), IdentityAgent and IdentityFile present: \(ok)")
            return host
        } catch {
            r.step("ssh_config", false, error.localizedDescription)
            return nil
        }
    }

    private func firstContact(_ host: RemoteHost, _ r: Recorder) async -> [HostKey]? {
        // 5. First contact: Test connection scans the host key and asks for trust.
        let first = await model.connectionTester.testConnection(to: host)
        guard case .hostKeyUnknown(let offered) = first.outcome, !offered.isEmpty else {
            r.step("first contact", false, "expected an unknown host key, got \(first.outcome): \(first.message)")
            return nil
        }
        r.report.hostKeyFingerprints = offered.map(\.description)
        r.step("first contact", true, "\(offered.count) key(s) offered: \(offered.map(\.description).joined(separator: ", "))")
        return offered
    }

    private func trust(_ offered: [HostKey], for host: RemoteHost, _ r: Recorder) async -> Bool {
        let ssh = model.ssh
        // 6. Trust (the user's click in the sheet; automatic only in this self-test).
        do {
            try await ssh.trust(offered, for: host, replacingPinned: false)
            let pinned = (try? await ssh.hostKeys.pinnedKeys(for: host)) ?? []
            r.step("trust host key", pinned.count == offered.count, "\(pinned.count) key(s) pinned in known_hosts")
            return true
        } catch {
            r.step("trust host key", false, error.localizedDescription)
            return false
        }
    }

    private func testConnection(_ host: RemoteHost, _ r: Recorder) async -> Bool {
        // 7. Test connection through /usr/bin/ssh and the in-app agent.
        let second = await model.connectionTester.testConnection(to: host)
        r.report.connectionMessage = second.message
        r.report.connectionMilliseconds = Int(second.elapsed.components.seconds * 1000 + second.elapsed.components.attoseconds / 1_000_000_000_000_000)
        r.step("test connection", second.succeeded, second.message)
        return second.succeeded
    }

    private func checkControlMaster(_ host: RemoteHost, _ r: Recorder) async {
        // 8. A regular run opens a ControlMaster; a second run reuses it.
        do {
            let (ok, detail) = try await runOverMaster(host)
            r.step("control master", ok, detail)
        } catch {
            r.step("control master", false, error.localizedDescription)
        }
    }

    private func runOverMaster(_ host: RemoteHost) async throws -> (ok: Bool, detail: String) {
        let ssh = model.ssh
        let firstRun = try await ssh.runner.run("echo aeroops", on: host)
        let status = try await ControlMaster(context: ssh.context).check(host)
        let secondRun = try await ssh.runner.run("true", on: host)
        let running = if case .running = status { true } else { false }
        let ok = firstRun.succeeded && firstRun.stdoutString == "aeroops\n" && running && secondRun.succeeded
        return (ok, "run ok \(firstRun.succeeded), master \(status), reuse ok \(secondRun.succeeded)")
    }

    private func checkAgentEvents(_ key: SSHKeyRecord, _ r: Recorder) async {
        let ssh = model.ssh
        // 9. Agent events: the trusted /usr/bin/ssh connected and the key signed.
        try? await Task.sleep(for: .milliseconds(300))
        r.report.agentEvents = ssh.agentEvents.map(Self.describe)
        let trustedPeer = ssh.agentEvents.contains { if case .connected(let peer) = $0.kind { peer.isTrustedAppSSH } else { false } }
        let signed = ssh.agentEvents.contains { if case .signed(let id, _, _, _, _) = $0.kind { id == key.id } else { false } }
        r.step("agent events", trustedPeer && signed, "trusted app ssh connected \(trustedPeer), signed with the key \(signed)")
    }

    /// A host whose pinned key no longer matches is blocked, and blocked hosts are never contacted.
    private func checkChangedKey(_ r: Recorder, host: RemoteHost, realKeys: [HostKey]) async {
        let ssh = model.ssh
        // Test connection never reuses the open master (its probe config turns sharing off),
        // so ssh really checks the server's key against the fake pin.
        do {
            try await ssh.trust([SampleHostKeys.ed25519(seed: 7)], for: host, replacingPinned: true)
        } catch {
            return r.step("changed host key", false, "could not pin a fake key: \(error.localizedDescription)")
        }
        let result = await model.connectionTester.testConnection(to: host)
        let blocked = model.hostKeyBlock(for: host.id) != nil
        var refused = false
        do {
            _ = try await ssh.runner.run("true", on: host)
        } catch let error as SSHError {
            refused = error == .hostKeyChanged
        } catch {}
        let changedOutcome = if case .hostKeyChanged = result.outcome { true } else { false }
        r.step(
            "changed host key", changedOutcome && blocked && refused,
            "outcome hostKeyChanged \(changedOutcome), host blocked \(blocked), runner refuses \(refused)"
        )
        do {
            try await ssh.trust(realKeys, for: host, replacingPinned: true)
            r.step("trust new key", model.hostKeyBlock(for: host.id) == nil, "real keys pinned again, block lifted")
        } catch {
            r.step("trust new key", false, error.localizedDescription)
        }
    }

    /// Scans for key material, shuts down, deletes the key and the root.
    private func finish(_ r: Recorder, key: SSHKeyRecord?) async -> Report {
        let ssh = model.ssh
        let paths = ssh.paths

        // No private key on disk: no PEM/OpenSSH private key files, and the raw secret bytes
        // (compared in memory only) appear in no file under the root or ~/.aeroops.
        if let key {
            r.report.privateKeyMaterialFound = Self.checkNoKeyMaterial(key, step: r.step)
        }

        // Shutdown: masters closed, agent stopped, socket removed.
        let closed = await model.shutdownServices()
        r.report.controlMastersClosed = closed
        let socketGone = !FileManager.default.fileExists(atPath: paths.agentSocket.path(percentEncoded: false))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: paths.controlMasterDirectory.path(percentEncoded: false))) ?? []
        r.step("shutdown", socketGone && leftovers.isEmpty, "masters closed \(closed), agent socket removed \(socketGone), cm/ entries \(leftovers.count)")

        // Cleanup: authorized_keys line, Keychain item and root.
        if let key {
            await Self.revokeKey(key, ssh: ssh, step: r.step)
            await Self.deleteKey(key, ssh: ssh, step: r.step)
        }
        if !Self.keepsRoot {
            try? FileManager.default.removeItem(at: Self.root)
        }
        r.report.ok = !r.report.steps.isEmpty && r.report.steps.allSatisfy(\.ok)
        return r.report
    }

    // MARK: - Helpers

    typealias RecordStep = (String, Bool, String) -> Void

    static func generateKey(name: String, ssh: SSHServices, step: RecordStep) async -> SSHKeyRecord? {
        do {
            let key = try await ssh.generateKey(.ed25519, name: name, policy: .always, syncs: false)
            step("generate key", true, "\(key.algorithm.displayName) \(key.fingerprint)")
            return key
        } catch {
            step("generate key", false, error.localizedDescription)
            return nil
        }
    }

    /// False only when the script fails. With no script, the key must already be authorized.
    @discardableResult
    static func authorize(_ key: SSHKeyRecord, ssh: SSHServices, step: RecordStep) async -> Bool {
        guard let script = authorizeScript else {
            step("authorize key", true, "skipped: no -AeroSelfTestAuthorizeScript (key must already be authorized)")
            return true
        }
        let pub = ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
        let (status, output) = await runProcess(script, arguments: [pub.path(percentEncoded: false)])
        step("authorize key", status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
        return status == 0
    }

    /// The raw secret is compared in memory only.
    @discardableResult
    static func checkNoKeyMaterial(_ key: SSHKeyRecord, step: RecordStep) -> [String] {
        let secret = try? KeyStore.systemKeychain(service: keychainService).secret(for: key.id.uuidString)
        let roots = [root, AeroPaths.standard.dotDirectory]
        let found = roots.flatMap { filesContainingKeyMaterial(under: $0, secret: secret) }
        step("no private key on disk", found.isEmpty && secret != nil, found.isEmpty ? "checked \(roots.map { $0.path(percentEncoded: false) })" : "found: \(found)")
        return found
    }

    /// Call before ``deleteKey(_:ssh:step:)``: the script reads the .pub.
    static func revokeKey(_ key: SSHKeyRecord, ssh: SSHServices, step: RecordStep) async {
        guard let script = Phase3SelfTest.revokeScript, authorizeScript != nil else { return }
        let pub = ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub")
        let (status, output) = await runProcess(script, arguments: [pub.path(percentEncoded: false)])
        step("revoke key", status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func deleteKey(_ key: SSHKeyRecord, ssh: SSHServices, step: RecordStep) async {
        do {
            try await ssh.deleteKey(key.id)
            let remaining = try KeyStore.systemKeychain(service: keychainService).secret(for: key.id.uuidString)
            let pubGone = !FileManager.default.fileExists(atPath: ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub").path(percentEncoded: false))
            step("delete key", remaining == nil && pubGone, "Keychain item removed \(remaining == nil), .pub removed \(pubGone)")
        } catch {
            step("delete key", false, error.localizedDescription)
        }
    }

    static func describe(_ event: AgentEvent) -> String {
        switch event.kind {
        case .connected(let peer): "connected: \(peer.summary)"
        case .rejected(let reason): "rejected: \(reason)"
        case .signed(_, let name, let algorithm, let user, _): "signed: \(name) \(algorithm) user=\(user ?? "?")"
        case .signFailed(_, let reason): "sign failed: \(reason)"
        case .identitiesListed(let count): "identities listed: \(count)"
        case .sessionBound: "session bound"
        case .refused(let request): "refused: \(request)"
        case .disconnected: "disconnected"
        }
    }

    /// Regular files under `directory` that hold a private key: PEM/OpenSSH armour, or `secret`
    /// raw or base64-encoded.
    nonisolated static func filesContainingKeyMaterial(under directory: URL, secret: Data?) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let markers = [Data("PRIVATE KEY".utf8), Data("openssh-key-v1".utf8)]
            + (secret.map { [$0, Data($0.base64EncodedString().utf8)] } ?? [])
        var found: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            if markers.contains(where: { !$0.isEmpty && data.range(of: $0) != nil }) {
                found.append(url.path(percentEncoded: false))
            }
        }
        return found
    }

    /// Runs `executable` with `arguments`; returns the exit status and combined output.
    /// Runs a helper script and returns its exit status and combined output. A script still
    /// running after `timeout` seconds is terminated and reported as status -2, so a dev server
    /// that stops answering (an `orb` or `docker exec` that never returns) cannot stall a run.
    nonisolated static func runProcess(
        _ executable: URL, arguments: [String], timeout: TimeInterval = 120
    ) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            let finish: @Sendable (Int32, String) -> Void = { status, output in
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: (status, output))
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                // Blocks until every writer closes the pipe; a grandchild that outlives the
                // script keeps it open, which the timeout below covers.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                finish(process.terminationStatus, String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                finish(-1, error.localizedDescription)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                finish(-2, "\(executable.lastPathComponent) timed out after \(Int(timeout)) s")
            }
        }
    }
}

/// The self-tests' user-presence check: never prompts. Each request is recorded (the reason
/// names the key, user, host key fingerprint and program; nothing secret) and denied.
final class SelfTestPresenceVerifier: UserPresenceVerifier {
    private let reasons = Mutex<[String]>([])

    /// Every reason asked for so far, oldest first.
    var requests: [String] { reasons.withLock { $0 } }

    func verifyUserPresence(reason: String) async -> Bool {
        reasons.withLock { $0.append(reason) }
        print("[selftest] Touch ID requested (denied, no prompt in self-tests): \(reason)")
        return false
    }
}
#endif
