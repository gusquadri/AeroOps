import Foundation

/// ``CommandActivity`` waiting for the app's next update. Live output comes as one event per ssh
/// read, often a few hundred bytes, so a chatty command sends hundreds a second. The buffer
/// merges consecutive output of one command on one stream into a single chunk; everything else
/// keeps its arrival order.
public struct CommandActivityBuffer: Sendable {
    private enum Entry: Sendable {
        case event(CommandActivity)
        /// Output kept in ``chunks`` (at this index), so merging appends in place.
        case output(id: UUID, chunk: Int)
    }

    private var entries: [Entry] = []
    private var chunks: [CommandOutputChunk] = []
    /// Per command, the chunk later output on the same stream is merged into.
    private var openChunk: [UUID: Int] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func append(_ activity: CommandActivity) {
        guard case .output(let id, let chunk) = activity else {
            openChunk[activity.commandID] = nil
            entries.append(.event(activity))
            return
        }
        if let index = openChunk[id], chunks[index].stream == chunk.stream {
            chunks[index].data.append(chunk.data)
        } else {
            openChunk[id] = chunks.count
            entries.append(.output(id: id, chunk: chunks.count))
            chunks.append(chunk)
        }
    }

    /// Everything buffered, oldest first; the buffer is empty afterwards.
    public mutating func drain() -> [CommandActivity] {
        defer { self = CommandActivityBuffer() }
        return entries.map { entry in
            switch entry {
            case .event(let activity): activity
            case .output(let id, let index): .output(id: id, chunks[index])
            }
        }
    }
}
