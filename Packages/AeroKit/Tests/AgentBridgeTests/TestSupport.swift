import AeroCore
import BridgeProtocol
import Darwin
import Foundation
import Synchronization
@testable import AgentBridge

// MARK: - Files

/// A short directory under `/tmp` (socket paths must fit in 104 bytes), removed by `remove()`.
struct TempDirectory {
    let url: URL
    var path: String { url.path(percentEncoded: false) }

    init() throws {
        url = URL(filePath: "/tmp/aero-b\(String(UInt32.random(in: 0...UInt32.max), radix: 16))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func appending(_ component: String) -> URL { url.appending(path: component) }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

func fileMode(_ path: String) -> mode_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode : nil
}

/// A test precondition that did not hold.
struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Waiting

/// Polls `condition` until it holds or `timeout` passes.
@discardableResult
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Clock

/// A clock that only moves when told to.
final class FakeClock: BridgeClock {
    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [UInt64: Sleeper] = [:]
        var nextID: UInt64 = 1
    }

    private let state: Mutex<State>

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        state = Mutex(State(now: now))
    }

    var now: Date { state.withLock { $0.now } }

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Date) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: (any Error)?? = state.withLock { state in
                    if Task.isCancelled { return .some(CancellationError()) }
                    if deadline <= state.now { return .some(nil) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .none
                }
                switch resumeNow {
                case .none: break
                case .some(.none): continuation.resume()
                case .some(.some(let error)): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline passed.
    func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.addingTimeInterval(seconds)
            let now = state.now
            let ids = state.sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

// MARK: - Hosts and handler

enum TestHosts {
    static let staging = RemoteHost(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "staging",
                                    address: "10.0.0.5", user: "deploy", tags: ["web"], mcpTier: .readExec)
    static let prod = RemoteHost(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "prod",
                                 address: "10.0.0.6", user: "deploy", tags: ["web", "prod"], mcpTier: .read)
    static let vault = RemoteHost(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "vault",
                                  address: "10.0.0.7", user: "root", tags: ["secret"], mcpTier: .off)
    static let all = [staging, prod, vault]
}

/// Canned data for the read tools; records what was asked.
final class FakeToolHandler: BridgeToolHandler {
    let hostList: [BridgeHostState]
    let logText: String
    let failure: BridgeHandlerError?
    private let requests = Mutex<[String]>([])

    init(hosts: [RemoteHost] = TestHosts.all, logText: String = "line 1\n\u{1B}[31mline 2\u{1B}[0m\nline 3\n",
         failure: BridgeHandlerError? = nil) {
        hostList = hosts.map { BridgeHostState(host: $0, status: $0.mcpTier == .read ? .offline : .online) }
        self.logText = logText
        self.failure = failure
    }

    var calls: [String] { requests.withLock { $0 } }

    private func note(_ call: String) throws {
        requests.withLock { $0.append(call) }
        if let failure { throw failure }
    }

    func hosts() async -> [BridgeHostState] { hostList }

    func metrics(for host: RemoteHost) async throws -> MetricsSnapshot {
        try note("metrics \(host.name)")
        return MetricsSnapshot(
            cpuPercent: 12.345, cpuCount: 4, memUsedBytes: 1 << 30, memTotalBytes: 4 << 30,
            disks: [DiskUsage(mount: "/", device: "/dev/sda1", usedBytes: 10, totalBytes: 100, availableBytes: 90)],
            uptimeSeconds: 3600, load1: 0.5, load5: 0.25, load15: 0.125, hostname: host.name, kernel: "6.1",
            sampledAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func containers(on host: RemoteHost, includeStopped: Bool) async throws -> [ContainerInfo] {
        try note("containers \(host.name) \(includeStopped)")
        return [ContainerInfo(id: "abc123", name: "api", image: "shop/api:1", state: .running, status: "Up 2 hours")]
    }

    func pods(on host: RemoteHost, namespace: String?) async throws -> [PodInfo] {
        try note("pods \(host.name) \(namespace ?? "*")")
        return []
    }

    func logs(_ request: LogRequest, on host: RemoteHost) async throws -> String {
        try note("logs \(host.name) \(request.kind.rawValue) \(request.name) tail=\(request.tail)")
        return logText
    }
}

// MARK: - Command runner

/// A ``RemoteCommandRunner`` that never touches ssh.
final class FakeRunner: RemoteCommandRunner {
    struct Call: Sendable {
        var remoteCommand: String
        var host: String
        var timeout: Duration
        var outputLimit: Int
    }

    enum Behavior: Sendable {
        case outcome(RemoteCommandOutcome)
        /// Waits until cancelled (or `seconds`), recording the cancellation.
        case hang(seconds: Double)
        case throwing(String)
    }

    private let behavior: Behavior
    private let state = Mutex<(calls: [Call], cancellations: Int)>(([], 0))

    init(_ behavior: Behavior = .outcome(RemoteCommandOutcome(exitCode: 0, stdout: Data("ok\n".utf8)))) {
        self.behavior = behavior
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    func run(_ remoteCommand: String, on host: RemoteHost, timeout: Duration, outputLimit: Int,
             output: @escaping @Sendable (CommandOutputChunk) -> Void) async throws -> RemoteCommandOutcome {
        state.withLock { $0.calls.append(Call(remoteCommand: remoteCommand, host: host.name, timeout: timeout, outputLimit: outputLimit)) }
        switch behavior {
        case .outcome(let outcome):
            if !outcome.stdout.isEmpty { output(CommandOutputChunk(stream: .stdout, data: outcome.stdout)) }
            return outcome
        case .hang(let seconds):
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                state.withLock { $0.cancellations += 1 }
                throw CancellationError()
            }
            return RemoteCommandOutcome(exitCode: 0)
        case .throwing(let message):
            struct Failure: Error, CustomStringConvertible { var description: String }
            throw Failure(description: message)
        }
    }
}

// MARK: - Peers

/// Accepts every peer without looking at it. Tests only.
struct AcceptAllPeers: BridgePeerValidator {
    func validate(socket fd: Int32) -> PeerValidation {
        .accepted(BridgePeer(pid: PeerCredentials.pid(fd) ?? 0, uid: getuid(), trust: .custom))
    }
}

struct RejectAllPeers: BridgePeerValidator {
    func validate(socket fd: Int32) -> PeerValidation { .rejected("test says no") }
}

let testPeer = BridgePeer(pid: 1, uid: getuid(), executablePath: "/test/aeroops-mcp", trust: .custom)

// MARK: - Socket client

/// A raw bridge client: writes lines, collects every message the app sends.
final class BridgeTestClient: Sendable {
    let fd: Int32
    private let state = Mutex<(messages: [BridgeServerMessage], badLines: [String], closed: Bool)>(([], [], false))

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let status = BridgeServerCore.withAddress(path) { connect(fd, $0, $1) }
        guard status == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let thread = Thread { [self] in readLoop() }
        thread.start()
    }

    private func readLoop() {
        var framer = LineFramer(maxLineBytes: BridgeLimits.maxReplyLineBytes)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            for event in framer.append(Data(buffer[0..<count])) {
                guard case .line(let line) = event else { continue }
                do {
                    let message = try BridgeWire.decodeServerMessage(line)
                    state.withLock { $0.messages.append(message) }
                } catch {
                    state.withLock { $0.badLines.append(String(decoding: line, as: UTF8.self)) }
                }
            }
        }
        state.withLock { $0.closed = true }
    }

    var messages: [BridgeServerMessage] { state.withLock { $0.messages } }
    var isClosedByServer: Bool { state.withLock { $0.closed } }

    var replies: [BridgeReply] {
        messages.compactMap { if case .reply(let reply) = $0 { reply } else { nil } }
    }

    func progress(for id: Int) -> [String] {
        messages.compactMap { if case .progress(let p) = $0, p.id == id { p.message } else { nil } }
    }

    func reply(for id: Int) -> BridgeReply? {
        replies.first { $0.id == id }
    }

    /// Waits for the reply to `id`.
    func waitForReply(_ id: Int, timeout: Duration = .seconds(5)) async -> BridgeReply? {
        await eventually(timeout: timeout) { self.reply(for: id) != nil }
        return reply(for: id)
    }

    @discardableResult
    func send(_ message: BridgeClientMessage) -> Bool {
        guard let line = try? BridgeWire.line(message) else { return false }
        return sendRaw(line)
    }

    @discardableResult
    func sendRaw(_ data: Data) -> Bool {
        BridgeServerCore.writeAll(fd, data)
    }

    func close() {
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

// MARK: - Scripted request handler

/// A ``BridgeRequestHandler`` driven by the tool name:
/// - `echo`: replies with `arguments.text` at once.
/// - `sleep`: replies after `arguments.ms` milliseconds.
/// - `wait`: sends a progress line, then waits until cancelled.
final class ScriptedRequestHandler: BridgeRequestHandler {
    private let state = Mutex<(started: [Int], cancelled: [Int])>(([], []))

    var started: [Int] { state.withLock { $0.started } }
    var cancelled: [Int] { state.withLock { $0.cancelled } }

    func handle(_ request: BridgeRequest, from peer: BridgePeer,
                progress: @escaping @Sendable (String) -> Void) async -> BridgeReply? {
        state.withLock { $0.started.append(request.id) }
        switch request.tool {
        case "echo":
            return .success(id: request.id, content: [.text(request.arguments["text"]?.stringValue ?? "")])
        case "whoami":
            return .success(id: request.id, content: [.text("\(request.client?.displayName ?? "-") \(request.toolUseId ?? "-")")])
        case "sleep":
            try? await Task.sleep(for: .milliseconds(request.arguments["ms"]?.intValue ?? 0))
            return .success(id: request.id, content: [.text("slept")])
        case "wait":
            progress("waiting")
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                state.withLock { $0.cancelled.append(request.id) }
                return .failure(id: request.id, .cancelled, "cancelled")
            }
            return .success(id: request.id, content: [.text("woke")])
        default:
            return .failure(id: request.id, .unknownTool, "unknown")
        }
    }
}
