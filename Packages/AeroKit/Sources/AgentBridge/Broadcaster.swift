import Foundation
import Synchronization

/// Fans values out to any number of `AsyncStream` subscribers. Each subscriber keeps the newest
/// `bufferSize` values it has not consumed yet, or every one when `bufferSize` is `nil`.
final class Broadcaster<Element: Sendable>: Sendable {
    private let subscribers = Mutex<[UInt64: AsyncStream<Element>.Continuation]>([:])
    private let nextID = Atomic<UInt64>(1)
    private let bufferSize: Int?

    init(bufferSize: Int? = 64) {
        self.bufferSize = bufferSize
    }

    /// A new stream, starting with `initial` when given.
    func subscribe(initial: Element? = nil) -> AsyncStream<Element> {
        let policy: AsyncStream<Element>.Continuation.BufferingPolicy = bufferSize.map { .bufferingNewest($0) } ?? .unbounded
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: policy)
        let id = nextID.add(1, ordering: .relaxed).oldValue
        if let initial { continuation.yield(initial) }
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.subscribers.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ element: Element) {
        for continuation in subscribers.withLock({ Array($0.values) }) {
            continuation.yield(element)
        }
    }

    func finish() {
        for continuation in subscribers.withLock({ state in
            defer { state.removeAll() }
            return Array(state.values)
        }) {
            continuation.finish()
        }
    }

    deinit {
        for continuation in subscribers.withLock({ Array($0.values) }) {
            continuation.finish()
        }
    }
}
