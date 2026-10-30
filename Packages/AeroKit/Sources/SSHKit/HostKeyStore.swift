import AeroCore
import Foundation

/// Fetches a server's host keys on first contact, before anything is trusted: ``HostKeyScanner``
/// (`ssh-keyscan`) on macOS, EmbeddedSSH's scanner on iOS.
public protocol HostKeyScanning: Sendable {
    /// Every key the server offers, deduplicated. Throws ``HostKeyError/invalidHost(_:)`` for an
    /// address or port that cannot be used, ``SSHError`` when nothing was received, and
    /// `CancellationError`.
    func scan(address: String, port: Int) async throws -> [HostKey]
}

extension HostKeyScanning {
    /// Scans `host`. See ``scan(address:port:)``.
    public func scan(_ host: RemoteHost) async throws -> [HostKey] {
        try await scan(address: host.address, port: host.port)
    }
}

/// Fetches a server's host keys with `ssh-keyscan` (first contact, before anything is trusted).
public struct HostKeyScanner: HostKeyScanning {
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

/// Trust-on-first-use host keys, pinned in the Keychain the Mac and iOS apps share, so a key
/// trusted on one of the user's devices is trusted on the others.
///
/// ssh enforces the pins itself (`StrictHostKeyChecking yes`) from ``knownHostsFile``, a copy of
/// the Keychain's pins that every read brings up to date; this actor manages the pins and
/// remembers hosts whose key changed. A blocked host stays blocked (``SSHRunner`` refuses to
/// connect) until the user trusts a key with `replacingPinned: true`, forgets the host, or calls
/// ``unblock(_:)``. Blocks are in memory, on this device only: after a relaunch ssh detects the
/// change again.
public actor HostKeyStore {
    /// ssh's copy of the pins (`UserKnownHostsFile`), mode 0600.
    public nonisolated let knownHostsFile: URL
    /// The pins: one synced item per known_hosts name.
    public nonisolated let keychain: any KeychainStore
    public nonisolated let scanner: any HostKeyScanning
    private var blocks: [String: HostKeyBlock] = [:]

    public init(keychain: any KeychainStore, knownHostsFile: URL, scanner: any HostKeyScanning = HostKeyScanner()) {
        self.keychain = keychain
        self.knownHostsFile = knownHostsFile
        self.scanner = scanner
    }

    /// The store for `context.knownHostsFile`, scanning with `context.keyscanExecutable`.
    public init(context: SSHContext = .standard, keychain: any KeychainStore) {
        self.init(keychain: keychain, knownHostsFile: context.knownHostsFile, scanner: HostKeyScanner(executable: context.keyscanExecutable))
    }

    /// The apps' pins, in ``SystemKeychain``.
    public static func systemKeychain(service: String = "app.aeroops.host-keys") -> SystemKeychain {
        SystemKeychain(service: service, label: "AeroOps host key")
    }

    /// Keys pinned for `host`.
    public func pinnedKeys(for host: RemoteHost) throws(HostKeyError) -> [HostKey] {
        try load().keys(for: host.knownHostsName)
    }

    /// Scans the server and compares with the pins. A mismatch blocks the host.
    ///
    /// Conservative: if any key is pinned, the server must present one of the pinned keys.
    /// Throws ``SSHError`` when the scan fails, ``HostKeyError`` for Keychain and file problems.
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

    /// Pins `key` for `host` and lifts any block.
    ///
    /// Adding a key of a type that already has a different pin throws
    /// ``HostKeyError/conflictsWithPinnedKey(pinned:)`` unless `replacingPinned` is `true`,
    /// in which case every existing pin for the host is removed first. Pass it only after the
    /// user explicitly accepted the new key.
    public func trust(_ key: HostKey, for host: RemoteHost, replacingPinned: Bool = false) throws(HostKeyError) {
        let name = host.knownHostsName
        let pinned = try load().keys(for: name)
        if !replacingPinned, isConflict(key, with: pinned, name: name) {
            throw .conflictsWithPinnedKey(pinned: pinned)
        }
        let kept = replacingPinned ? [] : pinned
        if !kept.contains(key) { try store(kept + [key], for: name) }
        blocks[name] = nil
    }

    private func isConflict(_ key: HostKey, with pinned: [HostKey], name: String) -> Bool {
        blocks[name] != nil || pinned.contains { $0.type == key.type && $0 != key }
    }

    /// Removes every pin for `host` and lifts any block. The next connection needs TOFU again.
    public func forget(_ host: RemoteHost) throws(HostKeyError) {
        try store([], for: host.knownHostsName)
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

    /// Brings ``knownHostsFile`` up to date with pins made on the user's other devices, and lifts
    /// the blocks of hosts whose pins they changed: the next connection checks the new pins.
    /// Returns whether anything changed.
    @discardableResult
    public func refreshKnownHostsFile() throws(HostKeyError) -> Bool {
        let file = try pins()
        let blockCount = blocks.count
        blocks = blocks.filter { Set(file.keys(for: $0.key)) == Set($0.value.pinned) }
        let mirrored = try mirror(file)
        return mirrored || blocks.count != blockCount
    }

    /// Moves the pins an older AeroOps kept only in `file` (its known_hosts) into the Keychain.
    /// Hosts that already have pins keep them. What only ssh can use stays in `file`, which it
    /// reads beside ``knownHostsFile``; a file with nothing left is deleted. Returns how many
    /// hosts moved.
    @discardableResult
    public func importLegacyPins(from file: URL) throws(HostKeyError) -> Int {
        let text: String?
        do {
            text = try FileSystem.readText(file)
        } catch {
            throw .knownHostsUnreadable(error.description)
        }
        guard let text else { return 0 }
        let legacy = KnownHostsFile(text: text)
        let pinned = try pins()
        let names = legacy.plainNames.filter { pinned.keys(for: $0).isEmpty }
        for name in names { try store(legacy.keys(for: name), for: name) }
        try keepOnly(legacy.withoutPlainNames, in: file, replacing: text)
        return names.count
    }

    private func keepOnly(_ rest: KnownHostsFile, in file: URL, replacing text: String) throws(HostKeyError) {
        do {
            if rest.lines.isEmpty {
                try FileManager.default.removeItem(at: file)
            } else if rest.text != text {
                try FileSystem.writeAtomically(Data(rest.text.utf8), to: file, permissions: 0o600)
            }
        } catch {
            throw .knownHostsWriteFailed(error.localizedDescription)
        }
    }

    private func load() throws(HostKeyError) -> KnownHostsFile {
        let file = try pins()
        try mirror(file)
        return file
    }

    /// Each item's keys, for its own name only. An item from another device whose name is not one
    /// literal host never reaches ssh, so it cannot pin a key for other hosts.
    private func pins() throws(HostKeyError) -> KnownHostsFile {
        let items: [KeychainItem]
        do {
            items = try keychain.items().sorted { $0.account < $1.account }
        } catch {
            throw .knownHostsUnreadable(error.localizedDescription)
        }
        var file = KnownHostsFile()
        for item in items where KnownHostsFile.isPlainName(item.account) {
            let keys = KnownHostsFile(text: String(decoding: item.record, as: UTF8.self)).keys(for: item.account)
            for key in keys { file.add(key, for: item.account) }
        }
        return file
    }

    private func store(_ keys: [HostKey], for name: String) throws(HostKeyError) {
        var record = KnownHostsFile()
        for key in keys { record.add(key, for: name) }
        do {
            if keys.isEmpty {
                try keychain.delete(name)
            } else {
                try keychain.save(KeychainItem(account: name, record: Data(record.text.utf8), syncs: true), secret: Data())
            }
        } catch {
            throw .knownHostsWriteFailed(error.localizedDescription)
        }
        try mirror(pins())
    }

    @discardableResult
    private func mirror(_ file: KnownHostsFile) throws(HostKeyError) -> Bool {
        let text = file.text
        do {
            guard try FileSystem.readText(knownHostsFile) != text else { return false }
            try FileSystem.ensureDirectory(knownHostsFile.deletingLastPathComponent(), permissions: 0o700)
            try FileSystem.writeAtomically(Data(text.utf8), to: knownHostsFile, permissions: 0o600)
            return true
        } catch {
            throw .knownHostsWriteFailed(error.description)
        }
    }
}
