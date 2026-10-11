import AeroCore
import Foundation

/// Fetches a server's host keys with `ssh-keyscan` (first contact, before anything is trusted).
public struct HostKeyScanner: Sendable {
    /// `/usr/bin/ssh-keyscan` in the app.
    public var executable: URL
    /// Passed as `-T`: seconds per connection attempt.
    public var connectTimeoutSeconds: Int
    /// Hard deadline for the whole scan.
    public var overallTimeout: Duration

    public init(
        executable: URL = SSHContext.systemKeyscan,
        connectTimeoutSeconds: Int = 5,
        overallTimeout: Duration = .seconds(30)
    ) {
        self.executable = executable
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.overallTimeout = overallTimeout
    }

    /// Key types requested from the server, one connection each.
    ///
    /// Explicit because the default also tries the two `sk-*` types, which servers almost never
    /// offer: six connections instead of three, and every one that closes before authenticating
    /// counts towards OpenSSH 9.8+'s `PerSourcePenalties` (`noauth`), which drops all connections
    /// from the source address once 15 s of penalties accrue.
    public static let keyTypes = "ed25519,ecdsa,rsa"

    /// `ssh-keyscan -t ed25519,ecdsa,rsa -p <port> -T <timeout> -- <address>`.
    func arguments(address: String, port: Int) -> [String] {
        ["-t", Self.keyTypes, "-p", String(port), "-T", String(connectTimeoutSeconds), "--", address]
    }

    /// Scans `host`. See ``scan(address:port:)``.
    public func scan(_ host: RemoteHost) async throws -> [HostKey] {
        try await scan(address: host.address, port: host.port)
    }

    /// Returns every key the server offers (Ed25519, ECDSA, RSA), deduplicated, in output order.
    /// Each call opens three unauthenticated connections; scan on first contact or on request,
    /// not routinely (see ``keyTypes``).
    ///
    /// Throws ``HostKeyError/invalidHost(_:)`` for an address or port that cannot be used,
    /// ``SSHError`` when nothing was received, and `CancellationError`.
    public func scan(address: String, port: Int) async throws -> [HostKey] {
        guard HostValidation.isValidAddress(address) else { throw HostKeyError.invalidHost("“\(address)” is not a valid address") }
        guard (1...65535).contains(port) else { throw HostKeyError.invalidHost("port \(port) is outside 1–65535") }
        let spec = ChildSpec(
            executable: executable.filePath,
            arguments: arguments(address: address, port: port),
            environment: ProcessInfo.processInfo.environment,
            timeout: overallTimeout
        )
        let outcome: ChildOutcome
        do {
            outcome = try await ChildProcess.run(spec)
        } catch let error as ChildLaunchError {
            throw SSHError.launchFailed(error.message)
        }
        if outcome.timedOut { throw SSHError.timeout }
        return try Self.parse(
            stdout: String(decoding: outcome.stdout.data, as: UTF8.self),
            stderr: String(decoding: outcome.stderr.data, as: UTF8.self)
        )
    }

    /// Parses `ssh-keyscan` output; throws a classified ``SSHError`` when it holds no keys.
    static func parse(stdout: String, stderr: String) throws(SSHError) -> [HostKey] {
        var keys: [HostKey] = []
        var sawBanner = false
        for line in stdout.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") {
                sawBanner = true // "# host:port SSH-2.0-OpenSSH_10.3"
                continue
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, let key = try? HostKey(type: String(fields[1]), base64: String(fields[2])) else { continue }
            if !keys.contains(key) { keys.append(key) }
        }
        if !keys.isEmpty { return keys }

        // ssh-keyscan exits 1 with these patterns (OpenSSH 10.3):
        //   refused:  "write (localhost): Broken pipe", repeated per key type
        //   DNS:      "getaddrinfo <name>: nodename nor servname provided, or not known"
        //   timeout:  no output at all
        if stderr.contains("Broken pipe") && stderr.contains("write (") { throw .connectionRefused }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw sawBanner ? .other("The server offered no supported host keys.") : .timeout
        }
        throw SSHError.classify(stderr: stderr)
    }
}

/// The outcome of ``HostKeyStore/verify(_:)``.
public enum HostKeyVerification: Sendable, Hashable {
    /// Nothing pinned yet. Show the fingerprints and let the user trust one (TOFU).
    case unknown(offered: [HostKey])
    /// The server presents this pinned key.
    case trusted(HostKey)
    /// Keys are pinned but the server presents none of them. The host is now blocked.
    case changed(pinned: [HostKey], offered: [HostKey])
}

/// Why a host is blocked.
public struct HostKeyBlock: Sendable, Hashable {
    /// The known_hosts name (`address` or `[address]:port`).
    public var knownHostsName: String
    /// Keys pinned when the change was detected.
    public var pinned: [HostKey]
    /// Keys the server offered, when known (empty if ssh detected the change on its own).
    public var offered: [HostKey]
    public var detectedAt: Date

    public init(knownHostsName: String, pinned: [HostKey], offered: [HostKey], detectedAt: Date = .now) {
        self.knownHostsName = knownHostsName
        self.pinned = pinned
        self.offered = offered
        self.detectedAt = detectedAt
    }
}

/// Trust-on-first-use host keys in `~/.aeroops/known_hosts`.
///
/// ssh enforces the pins itself (`StrictHostKeyChecking yes`); this actor manages the file and
/// remembers hosts whose key changed. A blocked host stays blocked (``SSHRunner`` refuses to
/// connect) until the user trusts a key with `replacingPinned: true`, forgets the host, or
/// calls ``unblock(_:)``. Blocks are in memory: after a relaunch ssh detects the change again.
public actor HostKeyStore {
    public nonisolated let knownHostsFile: URL
    public nonisolated let scanner: HostKeyScanner
    private var blocks: [String: HostKeyBlock] = [:]

    public init(knownHostsFile: URL, scanner: HostKeyScanner = HostKeyScanner()) {
        self.knownHostsFile = knownHostsFile
        self.scanner = scanner
    }

    /// The store for `context.knownHostsFile`, scanning with `context.keyscanExecutable`.
    public init(context: SSHContext = .standard) {
        self.init(knownHostsFile: context.knownHostsFile, scanner: HostKeyScanner(executable: context.keyscanExecutable))
    }

    /// Keys pinned for `host`.
    public func pinnedKeys(for host: RemoteHost) throws(HostKeyError) -> [HostKey] {
        try load().keys(for: host.knownHostsName)
    }

    /// Scans the server and compares with the pins. A mismatch blocks the host.
    ///
    /// Conservative: if any key is pinned, the server must present one of the pinned keys.
    /// Throws ``SSHError`` when the scan fails, ``HostKeyError`` for file problems.
    public func verify(_ host: RemoteHost) async throws -> HostKeyVerification {
        let offered = try await scanner.scan(host)
        let pinned = try pinnedKeys(for: host)
        if pinned.isEmpty { return .unknown(offered: offered) }
        if let match = offered.first(where: pinned.contains) { return .trusted(match) }
        blocks[host.knownHostsName] = HostKeyBlock(
            knownHostsName: host.knownHostsName, pinned: pinned, offered: offered, detectedAt: .now
        )
        return .changed(pinned: pinned, offered: offered)
    }

    /// Pins `key` for `host` (atomic rewrite, mode 0600) and lifts any block.
    ///
    /// Adding a key of a type that already has a different pin throws
    /// ``HostKeyError/conflictsWithPinnedKey(pinned:)`` unless `replacingPinned` is `true`,
    /// in which case every existing pin for the host is removed first. Pass it only after the
    /// user explicitly accepted the new key.
    public func trust(_ key: HostKey, for host: RemoteHost, replacingPinned: Bool = false) throws(HostKeyError) {
        let name = host.knownHostsName
        var file = try load()
        if replacingPinned {
            file.remove(name: name)
        } else {
            let pinned = file.keys(for: name)
            if pinned.contains(where: { $0.type == key.type && $0 != key }) || blocks[name] != nil {
                throw .conflictsWithPinnedKey(pinned: pinned)
            }
        }
        if file.add(key, for: name) { try save(file) }
        blocks[name] = nil
    }

    /// Removes every pin for `host` and lifts any block. The next connection needs TOFU again.
    public func forget(_ host: RemoteHost) throws(HostKeyError) {
        var file = try load()
        if file.remove(name: host.knownHostsName) > 0 { try save(file) }
        blocks[host.knownHostsName] = nil
    }

    /// Whether connections to `host` are refused because its key changed.
    public func isBlocked(_ host: RemoteHost) -> Bool {
        blocks[host.knownHostsName] != nil
    }

    /// The block for `host`, if any.
    public func block(for host: RemoteHost) -> HostKeyBlock? {
        blocks[host.knownHostsName]
    }

    /// Every blocked host, keyed by known_hosts name.
    public var blockedHosts: [String: HostKeyBlock] { blocks }

    /// Blocks `host`, e.g. after ssh itself reported a changed key.
    public func block(_ host: RemoteHost, offered: [HostKey] = []) {
        let name = host.knownHostsName
        if blocks[name] != nil && offered.isEmpty { return }
        let pinned = (try? load().keys(for: name)) ?? []
        blocks[name] = HostKeyBlock(knownHostsName: name, pinned: pinned, offered: offered, detectedAt: .now)
    }

    /// Lifts a block without touching the pins (the user fixed the server or the file).
    public func unblock(_ host: RemoteHost) {
        blocks[host.knownHostsName] = nil
    }

    // MARK: - File

    private func load() throws(HostKeyError) -> KnownHostsFile {
        do {
            return try FileSystem.readText(knownHostsFile).map(KnownHostsFile.init(text:)) ?? KnownHostsFile()
        } catch {
            throw .knownHostsUnreadable(error.description)
        }
    }

    private func save(_ file: KnownHostsFile) throws(HostKeyError) {
        do {
            try FileSystem.ensureDirectory(knownHostsFile.deletingLastPathComponent(), permissions: 0o700)
            try FileSystem.writeAtomically(Data(file.text.utf8), to: knownHostsFile, permissions: 0o600)
        } catch {
            throw .knownHostsWriteFailed(error.description)
        }
    }
}
