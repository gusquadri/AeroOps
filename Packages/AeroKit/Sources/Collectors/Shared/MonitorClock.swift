import Foundation

/// Time for polling schedules: a monotonic clock that can sleep, plus wall-clock dates for
/// timestamps. The app uses ``SystemMonitorClock``; tests drive a manual clock so schedules,
/// timeouts and backoff are checked without real waiting.
///
/// Monotonic time is a `Duration` since an arbitrary origin fixed when the clock is created.
public protocol MonitorClock: Sendable {
    /// Monotonic time since the clock's origin.
    func now() -> Duration
    /// Wall-clock time, for `sampledAt` and `lastSuccessAt`.
    func date() -> Date
    /// Returns once ``now()`` has reached `deadline` (immediately if it already has).
    /// Throws `CancellationError` if the calling task is cancelled first.
    func sleep(until deadline: Duration) async throws
}

/// ``MonitorClock`` on `ContinuousClock`, which keeps counting while the Mac sleeps: a poll
/// that fell due during sleep runs right after wake (unless the monitor is paused).
public struct SystemMonitorClock: MonitorClock {
    private let origin: ContinuousClock.Instant
    /// How late a sleep may end, so the system can coalesce timers across hosts.
    public var tolerance: Duration?

    public init(tolerance: Duration? = .milliseconds(250)) {
        origin = ContinuousClock.now
        self.tolerance = tolerance
    }

    public func now() -> Duration {
        origin.duration(to: ContinuousClock.now)
    }

    public func date() -> Date {
        Date()
    }

    public func sleep(until deadline: Duration) async throws {
        try await ContinuousClock().sleep(until: origin.advanced(by: deadline), tolerance: tolerance)
    }
}
