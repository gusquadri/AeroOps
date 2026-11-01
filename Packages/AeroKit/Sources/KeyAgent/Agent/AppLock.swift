import LocalAuthentication

/// What the iOS app's lock decides: when to prompt, which result counts, and what the lock screen
/// hides. Lives in memory only, so every launch starts locked.
public struct AppLock: Equatable, Sendable {
    public enum ScenePhase: Sendable {
        case active, inactive, background
    }

    public enum Outcome: Equatable, Sendable {
        case success, passcodeNotSet, failed

        /// Only a missing passcode is told apart, because only Settings can fix it. Cancel, lockout
        /// and anything unknown are plain failures, and every failure stays locked.
        init(failure error: (any Error)?) {
            self = (error as? LAError)?.code == .passcodeNotSet ? .passcodeNotSet : .failed
        }
    }

    /// One prompt in flight. Only the latest attempt's result counts.
    public struct Attempt: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    public private(set) var isUnlocked = false
    /// The last attempt failed because the device has no passcode.
    public private(set) var needsPasscode = false
    private var promptsWhenActive = true
    private var pending: UInt64?
    private var attempts: UInt64 = 0

    public init() {}

    /// A device that cannot authenticate at all still gets to try the sample servers. Anyone else
    /// reaches them through the empty dashboard, after unlocking.
    public var offersSampleServers: Bool { needsPasscode }

    /// Whether the lock screen hides the app. Sample servers hold nothing real, so only the user's
    /// own data waits for an unlock, and leaving the samples without one lands back here.
    public func covers(showingSamples: Bool) -> Bool {
        !showingSamples && !isUnlocked
    }

    /// Follows the scene, and returns the prompt to run if there is one. The prompt itself makes
    /// the scene inactive and then active again, so only the first `active` after launch or after
    /// the background prompts; a retry after that takes `requestUnlock()`.
    public mutating func sceneChanged(to phase: ScenePhase) -> Attempt? {
        switch phase {
        case .inactive:
            return nil
        case .background:
            isUnlocked = false
            pending = nil
            promptsWhenActive = true
            return nil
        case .active:
            guard promptsWhenActive else { return nil }
            promptsWhenActive = false
            return requestUnlock()
        }
    }

    /// Returns the prompt to run, or nil when unlocked or while another prompt is up.
    public mutating func requestUnlock() -> Attempt? {
        guard !isUnlocked, pending == nil else { return nil }
        attempts += 1
        pending = attempts
        return Attempt(id: attempts)
    }

    /// Applies a prompt's result, unless the app went to the background or a newer prompt began.
    public mutating func finish(_ attempt: Attempt, with outcome: Outcome) {
        guard attempt.id == pending else { return }
        pending = nil
        isUnlocked = outcome == .success
        needsPasscode = outcome == .passcodeNotSet
    }
}
