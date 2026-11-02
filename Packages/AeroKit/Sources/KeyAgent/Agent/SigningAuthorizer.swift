import Foundation
import LocalAuthentication

/// Everything known about one `SIGN_REQUEST`, for the authorizer and the Touch ID prompt.
public struct SignRequest: Sendable {
    public var connectionID: UInt64
    public var key: SSHKeyRecord
    public var peer: PeerIdentity
    /// The remote user, when the data is an SSH userauth request.
    public var user: String?
    /// `SHA256:` fingerprint of the server host key, from the hostbound userauth data or, failing
    /// that, from `session-bind@openssh.com`. Not verified by the agent: informational only.
    public var hostKeyFingerprint: String?
    /// The data parses as an SSH `publickey` userauth request for this key.
    public var isUserAuthentication: Bool
    /// ssh said the connection is a forwarded agent (`session-bind` with `is_forwarding`).
    public var isForwarded: Bool

    public init(
        connectionID: UInt64, key: SSHKeyRecord, peer: PeerIdentity, user: String?, hostKeyFingerprint: String?,
        isUserAuthentication: Bool, isForwarded: Bool
    ) {
        self.connectionID = connectionID
        self.key = key
        self.peer = peer
        self.user = user
        self.hostKeyFingerprint = hostKeyFingerprint
        self.isUserAuthentication = isUserAuthentication
        self.isForwarded = isForwarded
    }
}

public enum SigningDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

/// Decides whether the agent may sign. Must answer in bounded time: ssh waits for the agent with
/// no timeout of its own.
public protocol SigningAuthorizer: Sendable {
    func authorize(_ request: SignRequest) async -> SigningDecision
}

/// How much user presence a request needs.
public enum UserPresenceRequirement: Sendable, Equatable {
    case none
    /// Touch ID once per key per app session.
    case oncePerSession
    /// Touch ID for this signature.
    case everySignature
}

/// The signing rules, with no I/O.
public enum SigningPolicyEvaluator {
    /// - A peer that is not `/usr/bin/ssh` started by AeroOps always needs Touch ID, whatever the
    ///   key's policy, and never for longer than one signature.
    /// - So do forwarded-agent connections and data that is not an SSH userauth request.
    /// - Otherwise the key's ``SigningPolicy`` decides.
    public static func requirement(for request: SignRequest) -> UserPresenceRequirement {
        guard request.peer.isTrustedAppSSH, request.isUserAuthentication, !request.isForwarded else { return .everySignature }
        switch request.key.policy {
        case .always: return .none
        case .oncePerSession: return .oncePerSession
        case .everySignature: return .everySignature
        }
    }

    /// The Touch ID prompt text; LocalAuthentication shows it after "AeroOps is trying to".
    public static func reason(for request: SignRequest) -> String {
        var text = "sign in with the key “\(request.key.name)”"
        if let user = request.user { text += " as \(user)" }
        if let host = request.hostKeyFingerprint { text += " on the server with host key \(host)" }
        if !request.isUserAuthentication { text = "sign data with the key “\(request.key.name)”" }
        if !request.peer.isTrustedAppSSH {
            let program = request.peer.executablePath.map { ($0 as NSString).lastPathComponent } ?? "pid \(request.peer.pid)"
            text += " for \(program)"
        }
        return text
    }
}

/// Asks the user to prove presence (Touch ID, Apple Watch or the login password).
public protocol UserPresenceVerifier: Sendable {
    /// `true` only if the user approved. Must return within a bounded time.
    func verifyUserPresence(reason: String) async -> Bool
}

/// The app's authorizer: ``SigningPolicyEvaluator`` rules plus a ``UserPresenceVerifier``.
///
/// "Once per session" approvals are remembered per key until ``endSession()`` (call it when the
/// Mac locks or sleeps) or ``forgetSessionApproval(for:)``. Concurrent first requests for the same
/// key share one prompt. Requests from untrusted peers never use or create session approvals.
/// `sessionApproved` starts a session whose user has already authenticated (the iOS app's unlock):
/// its "once per session" keys sign without a prompt of their own until ``endSession()``.
public actor PolicySigningAuthorizer: SigningAuthorizer {
    private let verifier: any UserPresenceVerifier
    private var sessionApproved: Bool
    private var approvedKeys: Set<UUID> = []
    private var pendingApprovals: [UUID: Task<Bool, Never>] = [:]

    public init(verifier: any UserPresenceVerifier, sessionApproved: Bool = false) {
        self.verifier = verifier
        self.sessionApproved = sessionApproved
    }

    /// Touch ID via LocalAuthentication; no answer within `timeout` means deny.
    public static func localAuthentication(
        timeout: Duration = .seconds(60), sessionApproved: Bool = false
    ) -> PolicySigningAuthorizer {
        PolicySigningAuthorizer(verifier: LocalAuthenticationVerifier(timeout: timeout), sessionApproved: sessionApproved)
    }

    public func authorize(_ request: SignRequest) async -> SigningDecision {
        await authorize(
            SigningPolicyEvaluator.requirement(for: request), keyID: request.key.id,
            reason: SigningPolicyEvaluator.reason(for: request))
    }

    /// For AeroKit's in-process SSH client (iOS, EmbeddedSSH): the app itself signs its own
    /// userauth request, so no other process can be asking and the key's policy alone decides.
    public func authorizeClientSignature(key: SSHKeyRecord, user: String, host: String) async -> SigningDecision {
        let requirement: UserPresenceRequirement = switch key.policy {
        case .always: .none
        case .oncePerSession: .oncePerSession
        case .everySignature: .everySignature
        }
        return await authorize(requirement, keyID: key.id, reason: "sign in with the key “\(key.name)” as \(user) on \(host)")
    }

    private func authorize(_ requirement: UserPresenceRequirement, keyID: UUID, reason: String) async -> SigningDecision {
        let approved: Bool
        switch requirement {
        case .none: approved = true
        case .everySignature: approved = await verifier.verifyUserPresence(reason: reason)
        case .oncePerSession: approved = await approveOnce(keyID: keyID, reason: reason)
        }
        return approved ? .allow : .deny(reason: "user presence not confirmed")
    }

    private func approveOnce(keyID: UUID, reason: String) async -> Bool {
        if hasSessionApproval(for: keyID) { return true }
        let pending = pendingApprovals[keyID] ?? askOnce(keyID: keyID, reason: reason)
        let approved = await pending.value
        if pendingApprovals[keyID] == pending { pendingApprovals[keyID] = nil }
        if approved { approvedKeys.insert(keyID) }
        return approved
    }

    private func askOnce(keyID: UUID, reason: String) -> Task<Bool, Never> {
        let verifier = verifier
        let pending = Task { await verifier.verifyUserPresence(reason: reason) }
        pendingApprovals[keyID] = pending
        return pending
    }

    /// Forgets every "once per session" approval.
    public func endSession() {
        sessionApproved = false
        approvedKeys.removeAll()
    }

    /// Forgets one key's "once per session" approval (e.g. after its policy changed).
    public func forgetSessionApproval(for keyID: UUID) {
        approvedKeys.remove(keyID)
    }

    /// Whether a key currently has a session approval.
    public func hasSessionApproval(for keyID: UUID) -> Bool {
        sessionApproved || approvedKeys.contains(keyID)
    }
}

/// `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` with a timeout: Touch ID, Apple Watch,
/// or the login password on Macs without a sensor. Not unit-testable: nobody can touch the sensor.
public struct LocalAuthenticationVerifier: UserPresenceVerifier {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    public func verifyUserPresence(reason: String) async -> Bool {
        await authenticate(reason: reason) == .success
    }

    /// The prompt and how it ended, for callers that tell a missing passcode from a failure.
    public func authenticate(reason: String) async -> AppLock.Outcome {
        let box = ContextBox()
        var error: NSError?
        guard box.context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return AppLock.Outcome(failure: error)
        }
        let timeout = timeout
        // invalidate() makes a pending evaluatePolicy fail with LAError.appCancel.
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { box.context.invalidate() }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AppLock.Outcome, Never>) in
                box.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                    continuation.resume(returning: success ? .success : AppLock.Outcome(failure: error))
                }
            }
        } onCancel: {
            box.context.invalidate()
        }
    }

    /// `LAContext` is documented as usable from any thread, but is not annotated `Sendable`.
    private final class ContextBox: @unchecked Sendable {
        let context = LAContext()
    }
}
