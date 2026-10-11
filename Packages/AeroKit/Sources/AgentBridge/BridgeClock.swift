import Foundation

/// Wall-clock time and sleeping, injectable so tests can expire approvals and allow windows
/// without waiting.
public protocol BridgeClock: Sendable {
    /// The current time.
    var now: Date { get }
    /// Sleeps until `deadline`. Throws `CancellationError` when the task is cancelled.
    func sleep(until deadline: Date) async throws
}

/// The real clock.
public struct SystemBridgeClock: BridgeClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        if interval > 0 {
            try await Task.sleep(for: .seconds(interval))
        } else {
            try Task.checkCancellation()
        }
    }
}

extension Duration {
    /// The duration in seconds as a `TimeInterval`.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    /// Whole milliseconds, rounded down.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
