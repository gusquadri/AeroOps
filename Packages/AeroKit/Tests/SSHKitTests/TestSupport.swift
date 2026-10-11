import AeroCore
import CryptoKit
import Darwin
import Foundation
@testable import SSHKit

/// A private temporary directory under `/tmp` (short, so Unix socket paths stay < 104 bytes),
/// removed on deinit.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        var template = Array("/tmp/aero-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        url = URL(filePath: String(cString: created), directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path(percentEncoded: false).trimmingSuffix("/") }

    func file(_ name: String) -> URL { url.appending(path: name) }

    /// Writes `contents` and returns the URL.
    @discardableResult
    func write(_ name: String, _ contents: String, mode: mode_t = 0o644) throws -> URL {
        let target = file(name)
        try Data(contents.utf8).write(to: target)
        chmod(target.path(percentEncoded: false), mode)
        return target
    }

    /// Writes an executable `/bin/sh` script.
    @discardableResult
    func script(_ name: String, _ body: String) throws -> URL {
        try write(name, "#!/bin/sh\n" + body + "\n", mode: 0o755)
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: file(name), encoding: .utf8)
    }

    /// `AeroPaths` rooted in this directory: `<scratch>/<name>/` as the dot directory.
    func paths(_ name: String = "d") -> AeroPaths {
        AeroPaths(
            dotDirectory: url.appending(path: name, directoryHint: .isDirectory),
            applicationSupport: url.appending(path: "\(name)-support", directoryHint: .isDirectory)
        )
    }
}

/// A fake `ssh` that runs its last argument (the remote command) with `/bin/sh -c`,
/// so runner tests exercise the real argv layout without a server.
let fakeSSHBody = #"for a; do last=$a; done; exec /bin/sh -c "$last""#

struct ToolResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs a local tool to completion (through SSHKit's own process layer).
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

/// `true` once `pid` no longer exists (reaped, not a zombie), polling up to `timeout`.
func waitUntilGone(_ pid: pid_t, timeout: Duration = .seconds(3)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return kill(pid, 0) != 0 && errno == ESRCH
}

/// Polls `condition` until true or `timeout`.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// SSH wire `string`.
func wireString(_ bytes: some Sequence<UInt8>) -> Data {
    let body = Data(bytes)
    var length = UInt32(body.count).bigEndian
    return Data(bytes: &length, count: 4) + body
}

/// Fresh public host keys built in memory (no private key ever touches the disk).
enum TestKeys {
    static func ed25519() -> HostKey {
        let raw = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        return try! HostKey(type: "ssh-ed25519", base64: (wireString("ssh-ed25519".utf8) + wireString(raw)).base64EncodedString())
    }

    static func ecdsa384() -> HostKey {
        let point = P384.Signing.PrivateKey().publicKey.x963Representation
        let blob = wireString("ecdsa-sha2-nistp384".utf8) + wireString("nistp384".utf8) + wireString(point)
        return try! HostKey(type: "ecdsa-sha2-nistp384", base64: blob.base64EncodedString())
    }

    static func ecdsa521() -> HostKey {
        let point = P521.Signing.PrivateKey().publicKey.x963Representation
        let blob = wireString("ecdsa-sha2-nistp521".utf8) + wireString("nistp521".utf8) + wireString(point)
        return try! HostKey(type: "ecdsa-sha2-nistp521", base64: blob.base64EncodedString())
    }
}

/// The dev server's host keys (`ssh-keyscan -p 2222 localhost`), public data.
enum DevServerKeys {
    static let ed25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIPfVoGPvXD/pnZyxb+hG6xVPXZ4tyYudnqH3H3ZcLQ1B"
    static let ecdsa = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHXA9dWWECl717zA/VBdIMT7eo113RpCbNaiYZ6mXuLj3tA6xmaDLlrbMSeGfW1THodsXuW/xGwk5sgWRlhS1hA="
    static let rsa = "AAAAB3NzaC1yc2EAAAADAQABAAABgQCnsYU9zLNPxgFb3vYp6lxxfpKS0s3VGvIwqIOK8LKDoTewuhK/E0ZiOAb7o5jfJWWBKm6xONIfuCVI2eWArKSiZIBGMsAMlZZS3z5CezpvfqSYc8nl8/cxuNoSzJLSefgQTqrSXd6J6U2mbwX5YXVGcSZ8vLQF6e5kaZCgSp8KLUA8qhyU9c1DaALAHB9Vn8HdmmOGFKyqaSBblClpVW28jWwgso+BGia8m+wO7heTyjO0O1t2X9C3bEdb1hSLbCbpnjkfgT/2KDR3Mat84S/BC/o4OBF/LvttuENcnOqIMregM5nB9FmXDntGuWBwRUy4ctK1YnZWmZVUe/PejkJFQuoW7Q360C+BhMjSqrHmls2UvydsFNXRAD8lvYSSXtZB8jgziWpqyNeY+/LOK/i7K22SutZefYSC1AQ1xq0W4QnvaGCLvsFP3BO1zk+mFMb7OJlWOICTp/+/FjqQUFEVNfVgFlsR0foOB27Q8sHpCr86mgejT+eOxbORHmodCbk="

    static var keyscanOutput: String {
        """
        # localhost:2222 SSH-2.0-OpenSSH_10.3
        [localhost]:2222 ssh-rsa \(rsa)
        # localhost:2222 SSH-2.0-OpenSSH_10.3
        [localhost]:2222 ecdsa-sha2-nistp256 \(ecdsa)
        # localhost:2222 SSH-2.0-OpenSSH_10.3
        [localhost]:2222 ssh-ed25519 \(ed25519)

        """
    }

    static var ed25519Key: HostKey { try! HostKey(type: "ssh-ed25519", base64: ed25519) }
}

extension RemoteHost {
    static func test(
        id: UUID = UUID(),
        address: String = "localhost",
        port: Int = 2222,
        user: String = "dev",
        keyId: String? = nil
    ) -> RemoteHost {
        RemoteHost(id: id, name: "test", address: address, port: port, user: user, keyId: keyId)
    }
}
