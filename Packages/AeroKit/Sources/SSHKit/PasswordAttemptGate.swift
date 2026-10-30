import AeroCore
import Foundation

/// Keeps background ssh from guessing passwords.
///
/// Every failed password login counts against the account on the server: fail2ban,
/// `pam_faillock` and sshd's `PerSourcePenalties` lock out after a few. Collectors poll every few
/// seconds, so ``SSHRunner`` asks the gate before it starts ssh for a password host:
///
/// - No saved password: refused before ssh starts. (ssh would send an empty password when the
///   helper has nothing to give, which also counts as a failure.)
/// - Rejected once: refused until ``reset(_:)``, which the app calls when the user saves a new
///   password (here or on another device), a test connection succeeds, or the host's connection
///   settings change.
/// - Not proven yet (no login since the last reset): one ssh at a time. The others wait until it
///   logs in, fails, or ``probeWindow`` passes, so a wrong password costs one attempt rather than
///   one per collector.
///
/// Both refusals throw ``SSHError/authFailed``, like the server would. Key hosts always pass.
public actor PasswordAttemptGate {
    /// How long a login attempt holds back other runs for the same host. Long-lived sessions
    /// (streams, channels) only report failures, so a silent success frees the host after this.
    public let probeWindow: Duration

    private let hasPassword: @Sendable (RemoteHost.ID) -> Bool
    private var rejected: Set<RemoteHost.ID> = []
    /// Hosts whose saved password logged in since the last reset.
    private var proven: Set<RemoteHost.ID> = []
    /// Unproven hosts with a login in flight, and when it started.
    private var probes: [RemoteHost.ID: ContinuousClock.Instant] = [:]
    private var observers: [UUID: AsyncStream<Set<RemoteHost.ID>>.Continuation] = [:]

    /// - Parameter hasPassword: Whether a password is saved for the host. Called on every
    ///   admission, so it must be cheap (the app's vault caches it).
    public init(probeWindow: Duration = .seconds(20), hasPassword: @escaping @Sendable (RemoteHost.ID) -> Bool) {
        self.probeWindow = probeWindow
        self.hasPassword = hasPassword
    }

    /// Hosts whose saved password the server rejected.
    public var rejectedHosts: Set<RemoteHost.ID> { rejected }

    public func isRejected(_ id: RemoteHost.ID) -> Bool {
        rejected.contains(id)
    }

    /// Whether `id`'s password logged in since the last reset.
    public func isProven(_ id: RemoteHost.ID) -> Bool {
        proven.contains(id)
    }

    /// Returns when ssh may try `host`'s password: at once for key hosts and proven ones, else
    /// once no other login to the host is in flight. Report the outcome with ``accept(_:)``,
    /// ``reject(_:)`` or ``release(_:)``.
    ///
    /// - Throws: ``SSHError/authFailed`` if ssh must not try the password now;
    ///   `CancellationError` if the task is cancelled while waiting.
    public func admit(_ host: RemoteHost) async throws {
        guard host.auth == .password else { return }
        while true {
            if rejected.contains(host.id) || !hasPassword(host.id) { throw SSHError.authFailed }
            if proven.contains(host.id) { return }
            let now = ContinuousClock.now
            guard let started = probes[host.id], now - started < probeWindow else {
                probes[host.id] = now
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The password logged in: later runs pass without waiting.
    public func accept(_ id: RemoteHost.ID) {
        probes[id] = nil
        proven.insert(id)
    }

    /// The attempt ended without telling whether the password works (timeout, unreachable,
    /// cancelled): the next run may try.
    public func release(_ id: RemoteHost.ID) {
        probes[id] = nil
    }

    /// Stops password attempts for `id` until ``reset(_:)``.
    public func reject(_ id: RemoteHost.ID) {
        probes[id] = nil
        proven.remove(id)
        guard rejected.insert(id).inserted else { return }
        publish()
    }

    /// Allows password attempts for `id` again; the next login proves the password anew.
    public func reset(_ id: RemoteHost.ID) {
        probes[id] = nil
        proven.remove(id)
        guard rejected.remove(id) != nil else { return }
        publish()
    }

    /// The rejected set now and after every change, for the UI.
    public func changes() -> AsyncStream<Set<RemoteHost.ID>> {
        let (stream, continuation) = AsyncStream<Set<RemoteHost.ID>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        observers[key] = continuation
        continuation.yield(rejected)
        continuation.onTermination = { _ in
            Task { await self.removeObserver(key) }
        }
        return stream
    }

    private func removeObserver(_ key: UUID) {
        observers[key] = nil
    }

    private func publish() {
        for continuation in observers.values { continuation.yield(rejected) }
    }
}
