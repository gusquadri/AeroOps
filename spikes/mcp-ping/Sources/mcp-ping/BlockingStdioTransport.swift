// Alternative to the SDK's StdioTransport, which sets O_NONBLOCK on stdin/stdout and polls
// with a 10 ms sleep while idle (~100 wakeups/s for the whole agent session).
// This one parks a dedicated thread in a blocking read(2) and leaves the fd flags alone.
// Enabled with `mcp-ping --blocking-stdio`.

import Foundation
import Logging
import MCP

actor BlockingStdioTransport: Transport {
    nonisolated let logger = Logger(label: "aerospike.stdio", factory: { _ in SwiftLogNoOpLogHandler() })

    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var started = false

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        guard !started else { return }
        started = true
        let continuation = self.continuation
        let reader = Thread {
            let size = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: size)
            var pending = Data()
            while true {
                let n = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, size) }
                if n < 0 {
                    if errno == EINTR { continue }
                    continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
                if n == 0 { break }  // EOF: client closed the pipe
                pending.append(contentsOf: buffer[..<n])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { continuation.yield(Data(line)) }
                }
            }
            continuation.finish()
        }
        reader.name = "stdin-reader"
        reader.start()
    }

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        var line = data
        line.append(UInt8(ascii: "\n"))
        try FileHandle.standardOutput.write(contentsOf: line)  // blocking write, serialized by the actor
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        stream
    }
}
