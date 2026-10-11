import AeroCore
import BridgeProtocol
import Foundation

/// What the bridge asks the user to approve.
public struct ApprovalAsk: Sendable, Hashable {
    /// The MCP client as it named itself; anyone can claim any name.
    public var client: BridgeClientInfo?
    public var host: RemoteHost
    /// Exactly what will run (as `sh -c <command>`).
    public var command: String
    /// The agent's reason.
    public var reason: String
    /// Non-empty when an allow window must not apply (sudo and co.).
    public var alwaysAskReasons: [AlwaysAskReason]
    public var toolUseId: String?

    public init(client: BridgeClientInfo?, host: RemoteHost, command: String, reason: String,
                alwaysAskReasons: [AlwaysAskReason] = [], toolUseId: String? = nil) {
        self.client = client
        self.host = host
        self.command = command
        self.reason = reason
        self.alwaysAskReasons = alwaysAskReasons
        self.toolUseId = toolUseId
    }
}

/// One approval waiting for the user, as the approval panel shows it.
public struct PendingApproval: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The client's self-reported name, e.g. `claude-code`; "Unknown client" when it gave none.
    public var clientName: String
    public var clientVersion: String?
    /// Always shown next to the client name: the name is self-reported and unverified.
    public var clientLabel: String
    public var hostID: UUID
    public var hostName: String
    public var hostAddress: String
    public var command: String
    public var reason: String
    public var alwaysAskReasons: [AlwaysAskReason]
    public var toolUseId: String?
    public var requestedAt: Date
    /// When the request is denied automatically.
    public var expiresAt: Date

    /// "Allow this host for 15 minutes" is meaningful (the command itself is not always-ask).
    /// Choosing it anyway still allows this one call and opens the window for later ones.
    public var offersHostWindow: Bool { alwaysAskReasons.isEmpty }

    /// The suffix the UI must show after the client name.
    public static let selfReportedSuffix = "(self-reported)"
}

/// The user's answer.
public enum ApprovalDecision: String, Sendable, Hashable, Codable, CaseIterable {
    case deny
    case allowOnce
    /// Allow this call and further non-always-ask calls on the host for 15 minutes.
    case allowHost15Min
}

/// How an approval ended.
public enum ApprovalOutcome: Sendable, Hashable {
    case allowedOnce
    /// The user opened an allow window, which also allowed this call.
    case allowedHost(until: Date)
    /// An open allow window allowed the call without asking.
    case allowedByWindow(until: Date)
    case denied
    /// Nobody answered within the timeout; treated as a denial.
    case timedOut
    /// The agent cancelled the call (or its connection dropped).
    case cancelled

    public var isAllowed: Bool {
        switch self {
        case .allowedOnce, .allowedHost, .allowedByWindow: true
        case .denied, .timedOut, .cancelled: false
        }
    }
}

/// An open "allow this host for 15 minutes" window.
public struct AllowWindow: Sendable, Hashable, Identifiable {
    public var hostID: UUID
    public var hostName: String
    public var grantedAt: Date
    public var expiresAt: Date

    public var id: UUID { hostID }
}

/// Everything the approval UI shows.
public struct ApprovalSnapshot: Sendable, Hashable {
    /// Oldest first.
    public var pending: [PendingApproval]
    /// Sorted by host name.
    public var windows: [AllowWindow]

    public init(pending: [PendingApproval] = [], windows: [AllowWindow] = []) {
        self.pending = pending
        self.windows = windows
    }
}

/// Optional extra check before an allow decision takes effect (the app supplies a
/// LocalAuthentication / Touch ID implementation).
public protocol ApprovalAuthenticator: Sendable {
    /// Returns `true` to let `decision` proceed; `false` leaves the approval pending.
    func authenticate(_ approval: PendingApproval, decision: ApprovalDecision) async -> Bool
}

/// The queue of `run_command` approvals and the per-host allow windows. UI-agnostic: the app
/// observes ``updates()`` and calls ``decide(_:_:)``.
///
/// - No answer within 60 seconds denies the request (``ApprovalOutcome/timedOut``).
/// - When the agent cancels, the pending approval disappears (``ApprovalOutcome/cancelled``).
/// - An allow window lasts 15 minutes and never covers always-ask commands.
public actor ApprovalCenter {
    private struct Entry {
        var approval: PendingApproval
        var continuation: CheckedContinuation<ApprovalOutcome, Never>
        var timer: Task<Void, Never>?
    }

    private let clock: any BridgeClock
    /// How long a request waits for a decision before it is denied.
    public nonisolated let timeout: Duration
    private let windowLength: Duration
    private let authenticator: (any ApprovalAuthenticator)?

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var windows: [UUID: AllowWindow] = [:]
    private var windowTimers: [UUID: Task<Void, Never>] = [:]
    private nonisolated let broadcaster = Broadcaster<ApprovalSnapshot>(bufferSize: 8)

    public init(
        clock: any BridgeClock = SystemBridgeClock(),
        timeout: Duration = BridgeLimits.approvalTimeout,
        windowLength: Duration = BridgeLimits.allowWindow,
        authenticator: (any ApprovalAuthenticator)? = nil
    ) {
        self.clock = clock
        self.timeout = timeout
        self.windowLength = windowLength
        self.authenticator = authenticator
    }

    // MARK: Observing

    /// The current queue and windows.
    public func snapshot() -> ApprovalSnapshot {
        let now = clock.now
        return ApprovalSnapshot(
            pending: order.compactMap { entries[$0]?.approval },
            windows: windows.values.filter { $0.expiresAt > now }.sorted { $0.hostName < $1.hostName })
    }

    /// The current snapshot, then a new one after every change.
    public func updates() -> AsyncStream<ApprovalSnapshot> {
        broadcaster.subscribe(initial: snapshot())
    }

    /// The pending approval with `id`, if any.
    public func pending(_ id: UUID) -> PendingApproval? {
        entries[id]?.approval
    }

    // MARK: Asking

    /// Asks the user, or allows at once when an allow window covers the call. Returns when the
    /// user decides, the request times out, or the calling task is cancelled.
    public func authorize(_ ask: ApprovalAsk) async -> ApprovalOutcome {
        if ask.alwaysAskReasons.isEmpty, let window = activeWindow(for: ask.host.id) {
            return .allowedByWindow(until: window.expiresAt)
        }
        let id = UUID()
        let now = clock.now
        let clientName = ask.client.map { DisplayText.sanitized($0.name, maxLength: 64) }?.nonEmptyTrimmed ?? "Unknown client"
        let clientVersion = ask.client.map { DisplayText.sanitized($0.version, maxLength: 32) }?.nonEmptyTrimmed
        let approval = PendingApproval(
            id: id,
            clientName: clientName,
            clientVersion: clientVersion,
            clientLabel: [clientName, clientVersion, PendingApproval.selfReportedSuffix].compactMap { $0 }.joined(separator: " "),
            hostID: ask.host.id,
            hostName: ask.host.name,
            hostAddress: ask.host.address,
            command: ask.command,
            reason: ask.reason,
            alwaysAskReasons: ask.alwaysAskReasons,
            toolUseId: ask.toolUseId,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(timeout.timeInterval))

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalOutcome, Never>) in
                // Runs on this actor before any suspension (SE-0420), so a cancellation that
                // happened before this point is seen here, and a later one finds the entry.
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                enqueue(approval, continuation)
            }
        } onCancel: {
            Task { await self.resolve(id, .cancelled) }
        }
    }

    private func enqueue(_ approval: PendingApproval, _ continuation: CheckedContinuation<ApprovalOutcome, Never>) {
        let id = approval.id
        let clock = clock
        let deadline = approval.expiresAt
        let timer = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            await self?.resolve(id, .timedOut)
        }
        entries[id] = Entry(approval: approval, continuation: continuation, timer: timer)
        order.append(id)
        publish()
    }

    /// Ends the approval `id` with `outcome`. Returns `false` when it is no longer pending.
    @discardableResult
    private func resolve(_ id: UUID, _ outcome: ApprovalOutcome) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        order.removeAll { $0 == id }
        entry.timer?.cancel()
        entry.continuation.resume(returning: outcome)
        publish()
        return true
    }

    // MARK: Deciding

    /// Applies the user's decision to the pending approval `id`. Allow decisions first go through
    /// the authenticator, if any; when it refuses, the approval stays pending. Returns `false`
    /// when the approval is gone (decided, timed out or cancelled) or authentication failed.
    @discardableResult
    public func decide(_ id: UUID, _ decision: ApprovalDecision) async -> Bool {
        guard let approval = entries[id]?.approval else { return false }
        if decision != .deny, let authenticator {
            guard await authenticator.authenticate(approval, decision: decision) else { return false }
        }
        switch decision {
        case .deny:
            return resolve(id, .denied)
        case .allowOnce:
            return resolve(id, .allowedOnce)
        case .allowHost15Min:
            guard entries[id] != nil else { return false }
            let window = openWindow(hostID: approval.hostID, hostName: approval.hostName)
            resolve(id, .allowedHost(until: window.expiresAt))
            // The window covers the host's other waiting calls that are not always-ask.
            for other in order.compactMap({ entries[$0]?.approval })
            where other.hostID == approval.hostID && other.offersHostWindow {
                resolve(other.id, .allowedByWindow(until: window.expiresAt))
            }
            return true
        }
    }

    /// Denies every pending approval (e.g. when the bridge stops).
    public func denyAll() {
        for id in order { resolve(id, .denied) }
    }

    // MARK: Windows

    /// The open window for `hostID`, if it has not expired.
    public func activeWindow(for hostID: UUID) -> AllowWindow? {
        guard let window = windows[hostID] else { return nil }
        guard window.expiresAt > clock.now else {
            closeWindow(hostID)
            return nil
        }
        return window
    }

    /// Closes the window for `hostID` early.
    public func revokeWindow(for hostID: UUID) {
        closeWindow(hostID)
    }

    /// Closes all windows.
    public func revokeAllWindows() {
        for hostID in Array(windows.keys) { closeWindow(hostID) }
    }

    private func openWindow(hostID: UUID, hostName: String) -> AllowWindow {
        let now = clock.now
        let window = AllowWindow(hostID: hostID, hostName: hostName, grantedAt: now,
                                 expiresAt: now.addingTimeInterval(windowLength.timeInterval))
        windows[hostID] = window
        windowTimers[hostID]?.cancel()
        let clock = clock
        windowTimers[hostID] = Task { [weak self] in
            do {
                try await clock.sleep(until: window.expiresAt)
            } catch {
                return
            }
            await self?.expireWindow(hostID, at: window.expiresAt)
        }
        publish()
        return window
    }

    private func expireWindow(_ hostID: UUID, at expiry: Date) {
        guard windows[hostID]?.expiresAt == expiry else { return }
        closeWindow(hostID)
    }

    private func closeWindow(_ hostID: UUID) {
        windowTimers.removeValue(forKey: hostID)?.cancel()
        guard windows.removeValue(forKey: hostID) != nil else { return }
        publish()
    }

    private func publish() {
        broadcaster.yield(snapshot())
    }
}

extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
