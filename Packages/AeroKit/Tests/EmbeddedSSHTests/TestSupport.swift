import AeroCore
import CryptoKit
import Darwin
import Foundation
import KeyAgent
import NIOCore
import NIOPosix
import Synchronization
@testable import EmbeddedSSH
@testable import SSHKit

/// A private `/tmp/aero-e-XXXXXX` directory, removed on deinit.
final class ScratchDirectory: Sendable {
    let url: URL

    init() throws {
        var template = Array("/tmp/aero-e-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        url = URL(filePath: String(cString: created), directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

/// A user-presence verifier with a fixed answer that records the reasons it was asked with.
final class ScriptedVerifier: UserPresenceVerifier {
    private let state: Mutex<[String]> = Mutex([])
    let answer: Bool

    init(answer: Bool) {
        self.answer = answer
    }

    func verifyUserPresence(reason: String) async -> Bool {
        state.withLock { $0.append(reason) }
        return answer
    }

    var reasons: [String] { state.withLock { $0 } }
}

/// Keys, passwords and host keys in a scratch directory and memory, never the Keychain.
struct TestEnvironment {
    let scratch: ScratchDirectory
    let keyStore: KeyStore
    let vault: HostPasswordVault
    let hostKeys: HostKeyStore
    let verifier: ScriptedVerifier

    init(approve: Bool = true) throws {
        scratch = try ScratchDirectory()
        keyStore = try KeyStore(keychain: InMemoryKeychain(), publicKeysDirectory: scratch.file("pub"))
        vault = HostPasswordVault(keychain: InMemoryKeychain())
        hostKeys = HostKeyStore(keychain: InMemoryKeychain(), knownHostsFile: scratch.file("known_hosts"), scanner: EmbeddedHostKeyScanner())
        verifier = ScriptedVerifier(answer: approve)
    }

    var credentials: EmbeddedSSHCredentials {
        EmbeddedSSHCredentials(keyStore: keyStore, passwords: vault, authorizer: PolicySigningAuthorizer(verifier: verifier))
    }

    func client(gate: PasswordAttemptGate? = nil) -> EmbeddedSSHClient {
        EmbeddedSSHClient(hostKeys: hostKeys, credentials: credentials, passwordGate: gate)
    }
}

/// SSH wire `string`.
func wireString(_ bytes: some Sequence<UInt8>) -> Data {
    let body = Data(bytes)
    var length = UInt32(body.count).bigEndian
    return Data(bytes: &length, count: 4) + body
}

/// Fresh public host keys built in memory.
enum TestKeys {
    static func ed25519() -> HostKey {
        let raw = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        return try! HostKey(type: "ssh-ed25519", base64: (wireString("ssh-ed25519".utf8) + wireString(raw)).base64EncodedString())
    }

    static func ecdsa256() -> HostKey {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let blob = wireString("ecdsa-sha2-nistp256".utf8) + wireString("nistp256".utf8) + wireString(point)
        return try! HostKey(type: "ecdsa-sha2-nistp256", base64: blob.base64EncodedString())
    }
}

extension RemoteHost {
    static func test(
        id: UUID = UUID(),
        address: String = "localhost",
        port: Int = 2222,
        user: String = "dev",
        keyId: String? = nil,
        auth: HostAuthMethod = .key
    ) -> RemoteHost {
        RemoteHost(id: id, name: "test", address: address, port: port, user: user, keyId: keyId, auth: auth)
    }
}

/// A TCP server on 127.0.0.1 that accepts connections and never says anything, like a server
/// that hangs before its SSH banner. ``close()`` also closes the connections it accepted.
final class SilentServer: Sendable {
    let channel: any Channel
    private let accepted: Accepted

    private final class Accepted: Sendable {
        let channels = Mutex<[any Channel]>([])
    }

    init() async throws {
        let accepted = Accepted()
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                accepted.channels.withLock { $0.append(child) }
                return child.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        self.accepted = accepted
    }

    var port: Int { channel.localAddress?.port ?? 0 }

    /// A plain TCP connection to the server, wrapped like a logged-in SSH connection.
    func connection() async throws -> SSHConnection {
        let client = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(host: "127.0.0.1", port: port).get()
        return SSHConnection(channel: client)
    }

    func close() async {
        try? await channel.close()
        for child in accepted.channels.withLock({ $0 }) { try? await child.close() }
    }
}

struct ToolResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs a local tool to completion through SSHKit's process layer.
func runTool(_ executable: String, _ arguments: [String], stdin: Data? = nil, timeout: Duration = .seconds(60)) async throws -> ToolResult {
    let spec = ChildSpec(
        executable: executable,
        arguments: arguments,
        environment: ProcessInfo.processInfo.environment,
        stdin: stdin,
        timeout: timeout,
        outputLimit: 1 << 20
    )
    let outcome = try await ChildProcess.run(spec)
    let status: Int32 = switch outcome.termination {
    case .exited(let code): code
    case .signaled(let signal): 128 + signal
    }
    return ToolResult(
        status: status,
        stdout: String(decoding: outcome.stdout.data, as: UTF8.self),
        stderr: String(decoding: outcome.stderr.data, as: UTF8.self)
    )
}
