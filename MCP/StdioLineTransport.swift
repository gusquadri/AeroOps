// Newline-delimited JSON-RPC over stdin/stdout without busy polling.
//
// The SDK's StdioTransport sets O_NONBLOCK on the inherited fds and sleeps 10 ms between reads
// while idle. This one parks a dedicated thread in a blocking read(2), leaves the fd flags
// alone, and serializes writes through the actor.

import BridgeProtocol
import Darwin
import Foundation
import Logging
import MCP
import Synchronization

actor StdioLineTransport: Transport {
    /// Longest JSON-RPC line accepted from the client; longer lines are dropped.
    static let maxLineBytes = 4 << 20

    nonisolated let logger: Logger

    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let requests = UnansweredRequests()
    private var started = false

    init(logger: Logger) {
        self.logger = logger
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        guard !started else { return }
        started = true
        let sink = StdinLineSink(continuation: continuation, logger: logger, requests: requests)
        let reader = Thread { sink.run() }
        reader.name = "stdin-reader"
        reader.start()
    }

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        var line = data
        line.append(UInt8(ascii: "\n"))
        do {
            try FileHandle.standardOutput.write(contentsOf: line)
        } catch {
            requests.outputClosed()
            throw error
        }
        requests.sent(data)
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        stream
    }

    /// For after stdin closed: the SDK answers each request in its own task, so requests read
    /// just before EOF may still be running. Waits until all of them were answered (or stdout is
    /// gone), at most `timeout`, and returns how many are left.
    func drain(timeout: Duration) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while requests.count > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return requests.count
    }
}

/// Ids of requests read from stdin that have no response on stdout yet.
final class UnansweredRequests: Sendable {
    private struct State {
        var ids: Set<String> = []
        var outputClosed = false
    }

    private let state = Mutex(State())

    /// Requests still owed a response; 0 once stdout is closed.
    var count: Int {
        state.withLock { $0.outputClosed ? 0 : $0.ids.count }
    }

    func received(_ line: Data) {
        let messages = Self.messages(in: line)
        state.withLock { state in
            for message in messages {
                if message["method"] as? String == "notifications/cancelled" {
                    if let id = Self.key((message["params"] as? [String: Any])?["requestId"]) { state.ids.remove(id) }
                } else if message["method"] != nil, let id = Self.key(message["id"]) {
                    state.ids.insert(id)
                }
            }
        }
    }

    func sent(_ data: Data) {
        let messages = Self.messages(in: data)
        state.withLock { state in
            for message in messages where message["method"] == nil {
                if let id = Self.key(message["id"]) { state.ids.remove(id) }
            }
        }
    }

    func outputClosed() {
        state.withLock { $0.outputClosed = true }
    }

    private static func messages(in data: Data) -> [[String: Any]] {
        switch try? JSONSerialization.jsonObject(with: data) {
        case let object as [String: Any]: [object]
        case let batch as [Any]: batch.compactMap { $0 as? [String: Any] }
        default: []
        }
    }

    /// JSON-RPC ids are strings or numbers; `"1"` and `1` are different ids.
    private static func key(_ id: Any?) -> String? {
        switch id {
        case let string as String: "s:" + string
        case let number as NSNumber: "n:" + number.stringValue
        default: nil
        }
    }
}

private struct StdinLineSink: Sendable {
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    let logger: Logger
    let requests: UnansweredRequests

    func run() {
        var framer = LineFramer(maxLineBytes: StdioLineTransport.maxLineBytes)
        if let failure = pump(&framer) {
            continuation.finish(throwing: failure)
            return
        }
        if let line = framer.finish() {
            deliver(line)
        }
        continuation.finish()
    }

    private func pump(_ framer: inout LineFramer) -> POSIXError? {
        let size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, size) }
            if count > 0 {
                handle(framer.append(Data(buffer[0..<count])))
                continue
            }
            if count == 0 { return nil }
            if errno != EINTR { return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private func handle(_ events: [LineFramer.Event]) {
        for event in events {
            switch event {
            case .line(let line):
                deliver(line)
            case .oversized(let bytes):
                logger.warning("Dropped a JSON-RPC line over \(StdioLineTransport.maxLineBytes) bytes (\(bytes) so far)")
            }
        }
    }

    private func deliver(_ line: Data) {
        requests.received(line)
        continuation.yield(line)
    }
}
