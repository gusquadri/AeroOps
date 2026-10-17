import AeroCore
import AgentBridge
import BridgeProtocol
import Foundation

/// One agent `run_command` as the Activity tab shows it: what runs where, its state and its
/// output so far (stdout and stderr interleaved in arrival order, capped).
///
/// The output is remote text: shown verbatim as plain text, terminal escapes stripped.
struct LiveCommand: Identifiable, Hashable {
    enum State: Hashable {
        case running
        case finished(exitCode: Int32, durationMs: Int)
        case failed(String)
        case cancelled(byUser: Bool)
    }

    /// A run of output from one stream. Raw bytes are kept so a UTF-8 character or escape
    /// sequence split across two chunks still decodes.
    struct Segment: Identifiable, Hashable {
        let id: Int
        let stream: CommandOutputChunk.Stream
        private(set) var data: Data
        /// Plain text: invalid UTF-8 replaced, terminal escapes stripped. Decoded when output
        /// arrives, not on every render.
        private(set) var text: String

        init(id: Int, stream: CommandOutputChunk.Stream, data: Data) {
            self.id = id
            self.stream = stream
            self.data = data
            text = Self.decode(data)
        }

        mutating func append(_ more: Data) {
            data.append(more)
            text = Self.decode(data)
        }

        private static func decode(_ data: Data) -> String {
            LogText.stripANSI(String(decoding: data, as: UTF8.self))
        }
    }

    /// Output kept per command; later output is dropped and ``isTruncated`` set.
    static let outputLimit = BridgeLimits.maxCommandOutputBytes

    let id: UUID
    let hostID: UUID
    let hostName: String
    let command: String
    let startedAt: Date
    private(set) var state: State = .running
    private(set) var endedAt: Date?
    private(set) var segments: [Segment] = []
    private(set) var byteCount = 0
    private(set) var isTruncated = false

    init(id: UUID, hostID: UUID, hostName: String, command: String, startedAt: Date) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.command = command
        self.startedAt = startedAt
    }

    init(_ command: RunningCommand) {
        self.init(id: command.id, hostID: command.hostID, hostName: command.hostName,
                  command: command.command, startedAt: command.startedAt)
    }

    var isRunning: Bool { state == .running }
    var hasOutput: Bool { !segments.isEmpty }

    mutating func append(_ chunk: CommandOutputChunk) {
        guard isRunning, !chunk.data.isEmpty, !isTruncated else { return }
        var data = chunk.data
        let room = Self.outputLimit - byteCount
        if data.count > room {
            data = data.prefix(max(room, 0))
            isTruncated = true
        }
        guard !data.isEmpty else { return }
        byteCount += data.count
        if let last = segments.indices.last, segments[last].stream == chunk.stream {
            segments[last].append(data)
        } else {
            segments.append(Segment(id: segments.count, stream: chunk.stream, data: data))
        }
    }

    mutating func end(_ state: State, at date: Date = .now) {
        guard isRunning, state != .running else { return }
        self.state = state
        endedAt = date
    }
}
