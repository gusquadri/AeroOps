import CryptoKit
import Foundation
import Testing
@testable import KeyAgent

private let integrationEnabled = ProcessInfo.processInfo.environment["AEROOPS_INTEGRATION"] == "1"

/// End-to-end tests against the real OpenSSH client tools and the dev SSH server
/// (`docker compose -f dev/compose.yml up -d`). Run with
/// `AEROOPS_INTEGRATION=1 swift test --package-path Packages/AeroKit --filter KeyAgentTests`.
///
/// Keys live in an ``InMemoryKeychain``; keys authorized on the dev server are tagged with a
/// unique comment and removed afterwards.
@Suite("Integration (AEROOPS_INTEGRATION=1)", .enabled(if: integrationEnabled), .serialized)
struct IntegrationTests {
    private struct Agent {
        let dir: TempDirectory
        let store: KeyStore
        let verifier: ScriptedVerifier
        let server: SSHAgentServer
        let recorder: EventRecorder
        let records: [SSHKeyRecord]
        let tag: String

        var socket: String { server.socketURL.path }

        init(policy: SigningPolicy, verifierAnswer: Bool = true) async throws {
            dir = try TempDirectory()
            tag = "aeroops-keyagent-test-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
            store = try makeKeyStore(dir)
            var records = [try await store.generate(.ed25519, name: "ed25519", comment: "\(tag)-ed25519", policy: policy)]
            if SecureEnclave.isAvailable {
                records.append(try await store.generate(.secureEnclaveP256, name: "se", comment: "\(tag)-se", policy: policy))
            }
            for (type, bits) in [("ecdsa", 256), ("rsa", 3072)] {
                let key = try await GeneratedOpenSSHKey.make(type: type, bits: bits, comment: "\(tag)-\(type)", in: dir)
                records.append(try await store.importOpenSSHPrivateKey(key.privateKeyText, policy: policy))
            }
            self.records = records
            verifier = ScriptedVerifier(answer: verifierAnswer)
            server = SSHAgentServer(
                socketURL: dir.appending("agent/agent.sock"), keyStore: store,
                authorizer: PolicySigningAuthorizer(verifier: verifier), appProcessID: getpid())
            recorder = EventRecorder(server.events)
            try await server.start()
        }

        func pubFile(_ record: SSHKeyRecord) -> String { store.publicKeyFileURL(for: record.id).path }

        var environment: [String: String] {
            var env = ProcessInfo.processInfo.environment
            env["SSH_AUTH_SOCK"] = socket
            env["SSH_ASKPASS"] = nil
            env["DISPLAY"] = nil
            return env
        }

        func sshAdd(_ arguments: [String]) async throws -> ProcessResult {
            try await runProcess("/usr/bin/ssh-add", arguments, environment: environment)
        }

        func shutdown() async {
            await server.stop()
            recorder.stop()
            dir.remove()
        }
    }

    @Test func sshAddListsKeysAndCannotChangeThem() async throws {
        let agent = try await Agent(policy: .always)
        do {
            let list = try await agent.sshAdd(["-L"])
            #expect(list.status == 0, "\(list.stderr)")
            let lines = list.stdout.split(separator: "\n").map(String.init)
            #expect(lines == agent.records.map(\.authorizedKeysLine))

            let fingerprints = try await agent.sshAdd(["-l", "-E", "sha256"])
            for record in agent.records { #expect(fingerprints.stdout.contains(record.fingerprint)) }

            #expect(try await agent.sshAdd(["-D"]).status != 0)
            #expect(try await agent.sshAdd(["-d", agent.pubFile(agent.records[0])]).status != 0)
            #expect(await agent.store.keys == agent.records)
            #expect(try await agent.sshAdd(["-L"]).stdout == list.stdout)
            #expect(agent.recorder.all.contains(.refused(request: "REMOVE_ALL_IDENTITIES")))
        } catch {
            await agent.shutdown()
            throw error
        }
        await agent.shutdown()
    }

    @Test func sshAddSignatureTestNeedsUserPresence() async throws {
        // ssh-add is not /usr/bin/ssh, so even an "always" key needs Touch ID for it.
        let agent = try await Agent(policy: .always, verifierAnswer: true)
        do {
            for record in agent.records {
                let result = try await agent.sshAdd(["-T", agent.pubFile(record)])
                #expect(result.status == 0, "\(record.algorithm): \(result.stderr)")
            }
            #expect(agent.verifier.callCount == agent.records.count)
            #expect(agent.verifier.reasons.allSatisfy { $0.hasSuffix("for ssh-add") })

            agent.verifier.setAnswer(false)
            let denied = try await agent.sshAdd(["-T", agent.pubFile(agent.records[0])])
            #expect(denied.status != 0)
            #expect(await agent.recorder.wait { $0.contains(.signFailed(keyID: agent.records[0].id, reason: "denied: user presence not confirmed")) })
        } catch {
            await agent.shutdown()
            throw error
        }
        await agent.shutdown()
    }

    @Test func logsIntoTheDevServerWithEveryKeyType() async throws {
        let agent = try await Agent(policy: .always)
        do {
            for record in agent.records { try await authorize(agent.pubFile(record)) }
            for record in agent.records {
                let result = try await ssh(agent, record)
                #expect(result.status == 0, "\(record.algorithm): \(result.stderr)")
            }
            // /usr/bin/ssh started by this process with "always" keys: no user presence needed.
            #expect(agent.verifier.callCount == 0)
            #expect(await agent.recorder.wait { events in
                agent.records.allSatisfy { record in
                    events.contains { if case .signed(record.id, _, _, "dev", .some(_)) = $0 { true } else { false } }
                }
            })
            let peers = agent.recorder.all.compactMap { if case .connected(let peer) = $0 { peer } else { nil } }
            #expect(!peers.isEmpty)
            #expect(peers.allSatisfy { $0.isTrustedAppSSH }, "\(peers.map(\.summary))")
            let algorithms = agent.recorder.all.compactMap { if case .signed(_, _, let algorithm, _, _) = $0 { algorithm } else { nil } }
            #expect(algorithms.contains("rsa-sha2-512"))
            #expect(!algorithms.contains("ssh-rsa"))
        } catch {
            await deauthorize(agent.tag)
            await agent.shutdown()
            throw error
        }
        await deauthorize(agent.tag)
        await agent.shutdown()
    }

    @Test func everySignatureLoginFollowsTheVerifier() async throws {
        let agent = try await Agent(policy: .everySignature, verifierAnswer: true)
        do {
            let record = agent.records[0]
            try await authorize(agent.pubFile(record))
            #expect(try await ssh(agent, record).status == 0)
            #expect(agent.verifier.callCount == 1)
            agent.verifier.setAnswer(false)
            #expect(try await ssh(agent, record).status != 0)
            #expect(agent.verifier.callCount == 2)
        } catch {
            await deauthorize(agent.tag)
            await agent.shutdown()
            throw error
        }
        await deauthorize(agent.tag)
        await agent.shutdown()
    }

    // MARK: Dev server helpers

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func ssh(_ agent: Agent, _ record: SSHKeyRecord) async throws -> ProcessResult {
        try await runProcess("/usr/bin/ssh", [
            "-F", "/dev/null",
            "-o", "IdentityAgent=\(agent.socket)", "-o", "IdentitiesOnly=yes", "-i", agent.pubFile(record),
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR", "-p", "2222", "dev@localhost", "true",
        ], environment: agent.environment)
    }

    /// `dev/add-key.sh <file.pub>`.
    private func authorize(_ pubFile: String) async throws {
        let script = Self.repositoryRoot.appending(path: "dev/add-key.sh").path
        let result = try await runProcess("/bin/sh", [script, pubFile], environment: ProcessInfo.processInfo.environment)
        guard result.status == 0 else { throw TestFailure("add-key.sh failed: \(result.stderr)") }
    }

    /// Removes this run's lines from the container's authorized_keys, keeping the file's owner,
    /// mode and inode.
    private func deauthorize(_ tag: String) async {
        let script = #"f=/config/.ssh/authorized_keys; t=$(mktemp); grep -vF "$1" "$f" > "$t"; cat "$t" > "$f"; rm -f "$t""#
        let result = try? await runProcess(
            "/usr/local/bin/docker", ["exec", "aeroops-ssh", "sh", "-c", script, "sh", tag],
            environment: ProcessInfo.processInfo.environment)
        if result?.status != 0 { Issue.record("could not remove \(tag) keys: \(result?.stderr ?? "docker failed")") }
    }
}
