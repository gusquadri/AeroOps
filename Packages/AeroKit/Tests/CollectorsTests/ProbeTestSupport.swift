import AeroCore
import AeroTestSupport
import Foundation
import SSHKit
import Synchronization
import Testing
@testable import Collectors

/// A fake `RemoteCommandRunning` for the probe, Docker, Kubernetes and log collector tests:
/// records every command and answers from closures, without ssh.
final class ProbeScriptedRunner: RemoteCommandRunning {
    struct Call: Sendable, Hashable {
        var command: String
        var hostID: UUID
        var stdin: Data?
        var timeout: Duration?
        var outputLimit: Int?
        var streamed: Bool
    }

    /// How a scripted stream ends after yielding its lines.
    enum StreamEnd: Sendable {
        case finish
        case fail(SSHError)
        /// Stays open until the consumer cancels (like `docker logs -f`).
        case hang
    }

    struct StreamScript: Sendable {
        var lines: [String]
        var end: StreamEnd
    }

    private struct State {
        var calls: [Call] = []
        var cancelledStreams = 0
    }

    private let state = Mutex(State())
    private let runHandler: @Sendable (String) async throws -> SSHResult
    private let streamHandler: @Sendable (String) -> StreamScript

    init(
        run: @escaping @Sendable (String) async throws -> SSHResult = { _ in SSHResult(exitCode: 0) },
        stream: @escaping @Sendable (String) -> StreamScript = { _ in StreamScript(lines: [], end: .finish) }
    ) {
        runHandler = run
        streamHandler = stream
    }

    /// Answers every `run` with `result`.
    convenience init(result: SSHResult) {
        self.init(run: { _ in result })
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var commands: [String] { calls.map(\.command) }
    /// Streams whose consumer cancelled or dropped them before they finished.
    var cancelledStreams: Int { state.withLock { $0.cancelledStreams } }

    func run(
        _ command: String,
        on host: RemoteHost,
        stdin: Data?,
        timeout: Duration,
        outputLimit: Int
    ) async throws -> SSHResult {
        state.withLock {
            $0.calls.append(Call(command: command, hostID: host.id, stdin: stdin, timeout: timeout,
                                 outputLimit: outputLimit, streamed: false))
        }
        return try await runHandler(command)
    }

    func stream(
        _ command: String,
        on host: RemoteHost,
        stdin: Data?,
        timeout: Duration?,
        maxBufferedLines: Int
    ) async throws -> AsyncThrowingStream<String, any Error> {
        state.withLock {
            $0.calls.append(Call(command: command, hostID: host.id, stdin: stdin, timeout: timeout,
                                 outputLimit: nil, streamed: true))
        }
        let script = streamHandler(command)
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        continuation.onTermination = { [self] termination in
            if case .cancelled = termination { state.withLock { $0.cancelledStreams += 1 } }
        }
        for line in script.lines { continuation.yield(line) }
        switch script.end {
        case .finish: continuation.finish()
        case .fail(let error): continuation.finish(throwing: error)
        case .hang: break
        }
        return stream
    }

    /// Waits up to `timeout` for `condition` to hold.
    func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable (ProbeScriptedRunner) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(self)
    }
}

/// Hosts and results shared by the collector tests.
enum ProbeTestData {
    static func host(
        id: UUID = UUID(),
        address: String = "aeroops-vm.orb.local",
        user: String = "dev",
        kubectlPrefix: String? = nil,
        dockerSudo: Bool = false
    ) -> RemoteHost {
        RemoteHost(id: id, name: "vm", address: address, user: user, kubectlPrefix: kubectlPrefix, dockerSudo: dockerSudo)
    }

    static func ok(_ stdout: String = "") -> SSHResult {
        SSHResult(exitCode: 0, stdout: Data(stdout.utf8))
    }

    static func failure(exitCode: Int32 = 1, stdout: String = "", stderr: String = "") -> SSHResult {
        SSHResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    /// An error fixture (`docker/error-*.txt`, `kubectl/error-*.txt`) as a failed result on
    /// stderr: the trailing `[exit status N]` line becomes the exit code.
    static func errorFixture(_ path: String, onStdout: Bool = false) throws -> SSHResult {
        var lines = try Fixtures.string(path).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        var exitCode: Int32 = 1
        if let last = lines.last, last.hasPrefix("[exit status "), let code = Int32(last.dropFirst(13).dropLast()) {
            exitCode = code
            lines.removeLast()
        }
        let text = lines.joined(separator: "\n") + "\n"
        return onStdout ? failure(exitCode: exitCode, stdout: text) : failure(exitCode: exitCode, stderr: text)
    }
}
