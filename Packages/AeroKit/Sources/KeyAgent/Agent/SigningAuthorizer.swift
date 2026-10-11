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
public actor PolicySigningAuthorizer: SigningAuthorizer {
    private let verifier: any UserPresenceVerifier
    private var approvedKeys: Set<UUID> = []
    private var pendingApprovals: [UUID: Task<Bool, Never>] = [:]

    public init(verifier: any UserPresenceVerifier) {
        self.verifier = verifier
    }

    /// Touch ID via LocalAuthentication; no answer within `timeout` means deny.
    public static func localAuthentication(timeout: Duration = .seconds(60)) -> PolicySigningAuthorizer {
        PolicySigningAuthorizer(verifier: LocalAuthenticationVerifier(timeout: timeout))
    }

    public func authorize(_ request: SignRequest) async -> SigningDecision {
        switch SigningPolicyEvaluator.requirement(for: request) {
        case .none:
            return .allow
        case .everySignature:
            let approved = await verifier.verifyUserPresence(reason: SigningPolicyEvaluator.reason(for: request))
            return approved ? .allow : .deny(reason: "user presence not confirmed")
        case .oncePerSession:
            let keyID = request.key.id
            if approvedKeys.contains(keyID) { return .allow }
            let pending: Task<Bool, Never>
            if let existing = pendingApprovals[keyID] {
                pending = existing
            } else {
                let verifier = verifier
                let reason = SigningPolicyEvaluator.reason(for: request)
                pending = Task { await verifier.verifyUserPresence(reason: reason) }
                pendingApprovals[keyID] = pending
            }
            let approved = await pending.value
            if pendingApprovals[keyID] == pending { pendingApprovals[keyID] = nil }
            if approved { approvedKeys.insert(keyID) }
            return approved ? .allow : .deny(reason: "user presence not confirmed")
        }
    }

    /// Forgets every "once per session" approval.
    public func endSession() {
        approvedKeys.removeAll()
    }

    /// Forgets one key's "once per session" approval (e.g. after its policy changed).
    public func forgetSessionApproval(for keyID: UUID) {
        approvedKeys.remove(keyID)
    }

    /// Whether a key currently has a session approval.
    public func hasSessionApproval(for keyID: UUID) -> Bool {
        approvedKeys.contains(keyID)
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
        let box = ContextBox()
        var error: NSError?
        guard box.context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let timeout = timeout
        // invalidate() makes a pending evaluatePolicy fail with LAError.appCancel.
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { box.context.invalidate() }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                box.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                    continuation.resume(returning: success)
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
