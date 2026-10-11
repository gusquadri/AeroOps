import Darwin
import Foundation
import os
import Security

/// The process on the other end of a bridge connection.
public struct BridgePeer: Sendable, Hashable {
    /// How the peer was let in.
    public enum Trust: String, Sendable, Hashable {
        /// Its code signature satisfies the requirement (same team as the app, the CLI's identifier).
        case codeSignature
        /// DEBUG builds only: an unsigned development build explicitly allowed unchecked peers.
        case unsignedDevelopmentOverride
        /// A custom validator accepted it (tests).
        case custom
    }

    public var pid: pid_t
    public var uid: uid_t
    public var executablePath: String?
    public var signingIdentifier: String?
    public var teamIdentifier: String?
    public var trust: Trust

    public init(pid: pid_t, uid: uid_t, executablePath: String? = nil, signingIdentifier: String? = nil,
                teamIdentifier: String? = nil, trust: Trust) {
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.trust = trust
    }

    /// For logs: `pid 123 /…/aeroops-mcp (app.aeroops.mcp, team ABCDE12345)`.
    public var summary: String {
        var details: [String] = []
        if let signingIdentifier { details.append(signingIdentifier) }
        if let teamIdentifier { details.append("team \(teamIdentifier)") }
        if trust == .unsignedDevelopmentOverride { details.append("UNCHECKED development override") }
        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "pid \(pid) \(executablePath ?? "<unknown executable>")\(suffix)"
    }
}

/// The verdict on a connection's peer.
public enum PeerValidation: Sendable, Hashable {
    case accepted(BridgePeer)
    case rejected(String)
}

/// Decides whether the process behind a connected Unix socket may use the bridge. Called on the
/// connection's thread before any request is read.
public protocol BridgePeerValidator: Sendable {
    func validate(socket fd: Int32) -> PeerValidation
}

/// The production check: the peer must run as this user and its code signature, looked up by
/// audit token (not PID, which can be reused), must satisfy
///
/// ```text
/// anchor apple generic and certificate leaf[subject.OU] = "<team>" and identifier "app.aeroops.mcp"
/// ```
///
/// where `<team>` is the running app's own team ID (``TeamSource/ownSignature``). An app without
/// a team ID (unsigned or ad-hoc) rejects every peer.
public struct CodeSignaturePeerValidator: BridgePeerValidator {
    public enum TeamSource: Sendable, Hashable {
        /// The team ID in this process's own code signature.
        case ownSignature
        /// A fixed team ID (tests, tools).
        case explicit(String)
    }

    /// The `aeroops-mcp` signing identifier.
    public static let cliIdentifier = "app.aeroops.mcp"

    /// The team every peer must be signed by; `nil` when unknown (then all peers are rejected).
    public let teamIdentifier: String?
    /// The signing identifier peers must have; `nil` accepts any identifier of the team.
    public let requiredIdentifier: String?
    private let requirementText: String?

    public init(team: TeamSource = .ownSignature, requiredIdentifier: String? = CodeSignaturePeerValidator.cliIdentifier) {
        let candidate: String? = switch team {
        case .ownSignature: Self.ownTeamIdentifier()
        case .explicit(let value): value
        }
        // Only a well-formed team ID goes into the requirement string.
        teamIdentifier = candidate.flatMap { $0.wholeMatch(of: /[A-Z0-9]{10}/) != nil ? $0 : nil }
        let identifier = requiredIdentifier.flatMap { $0.wholeMatch(of: /[A-Za-z0-9.\-]+/) != nil ? $0 : nil }
        self.requiredIdentifier = identifier
        if let teamIdentifier {
            var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            if let identifier { text += " and identifier \"\(identifier)\"" }
            requirementText = text
        } else {
            requirementText = nil
        }
    }

    /// The code requirement peers must satisfy, or `nil` when the team is unknown.
    public var requirement: String? { requirementText }

    public func validate(socket fd: Int32) -> PeerValidation {
        guard let uid = PeerCredentials.uid(fd) else { return .rejected("peer credentials unavailable") }
        guard uid == getuid() else { return .rejected("peer belongs to uid \(uid)") }
        let pid = PeerCredentials.pid(fd) ?? 0
        guard let requirementText else {
            return .rejected("AeroOps has no team ID in its code signature, so no agent CLI can be verified")
        }
        guard let token = PeerCredentials.auditToken(fd) else { return .rejected("peer audit token unavailable") }
        guard let code = PeerCredentials.guestCode(token) else { return .rejected("peer code signature unavailable") }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return .rejected("invalid code requirement")
        }
        let info = PeerCredentials.signingInfo(code)
        let status = SecCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else {
            let who = [info.identifier, info.team.map { "team \($0)" }].compactMap { $0 }.joined(separator: ", ")
            return .rejected("peer pid \(pid) (\(who.isEmpty ? "unsigned" : who)) does not satisfy the requirement (OSStatus \(status))")
        }
        return .accepted(BridgePeer(pid: pid, uid: uid, executablePath: PeerCredentials.executablePath(pid),
                                    signingIdentifier: info.identifier, teamIdentifier: info.team, trust: .codeSignature))
    }

    /// The team ID of the running process's code signature, or `nil` when unsigned or ad-hoc.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return PeerCredentials.signingInfo(code).team
    }
}

#if DEBUG
/// DEBUG builds only: accepts any peer of the same user without checking its signature, for
/// unsigned development builds where ``CodeSignaturePeerValidator`` cannot work. Every accepted
/// connection is logged as a fault. This type does not exist in Release builds.
public struct UnsignedDevelopmentPeerValidator: BridgePeerValidator {
    private static let logger = Logger(subsystem: "app.aeroops", category: "bridge")
    public let reason: String

    /// - Parameter reason: why the override is on, logged with every connection.
    public init(reason: String) {
        self.reason = reason
        Self.logger.fault("Bridge peer check DISABLED for this development build: \(reason, privacy: .public)")
    }

    public func validate(socket fd: Int32) -> PeerValidation {
        guard let uid = PeerCredentials.uid(fd), uid == getuid() else { return .rejected("peer belongs to another user") }
        let pid = PeerCredentials.pid(fd) ?? 0
        var identifier: String?
        var team: String?
        if let token = PeerCredentials.auditToken(fd), let code = PeerCredentials.guestCode(token) {
            (identifier, team) = PeerCredentials.signingInfo(code)
        }
        let peer = BridgePeer(pid: pid, uid: uid, executablePath: PeerCredentials.executablePath(pid),
                              signingIdentifier: identifier, teamIdentifier: team, trust: .unsignedDevelopmentOverride)
        Self.logger.fault("Bridge accepted UNCHECKED peer \(peer.summary, privacy: .public) (development override: \(reason, privacy: .public))")
        return .accepted(peer)
    }
}
#endif

extension CodeSignaturePeerValidator {
    /// The validator the app should use.
    ///
    /// - Release: always ``CodeSignaturePeerValidator`` with the app's own team.
    /// - DEBUG: the same when the app has a team ID. When it has none (unsigned build) and
    ///   `allowUnsignedPeersInDebug` is `true`, an ``UnsignedDevelopmentPeerValidator`` that logs
    ///   every connection; otherwise the strict validator, which rejects everyone.
    public static func forApp(allowUnsignedPeersInDebug: Bool = false) -> any BridgePeerValidator {
        let strict = CodeSignaturePeerValidator()
        #if DEBUG
        if strict.teamIdentifier == nil && allowUnsignedPeersInDebug {
            return UnsignedDevelopmentPeerValidator(reason: "app has no team ID and allowUnsignedPeersInDebug is set")
        }
        #endif
        return strict
    }
}

/// Socket peer facts from the kernel.
enum PeerCredentials {
    static func uid(_ fd: Int32) -> uid_t? {
        var cred = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &length) == 0, cred.cr_version == XUCRED_VERSION else { return nil }
        return cred.cr_uid
    }

    static func pid(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    static func auditToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        return token
    }

    static func guestCode(_ token: audit_token_t) -> SecCode? {
        var token = token
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    static func signingInfo(_ code: SecCode) -> (identifier: String?, team: String?) {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, nil) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return (nil, nil) }
        return (info[kSecCodeInfoIdentifier as String] as? String, info[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
