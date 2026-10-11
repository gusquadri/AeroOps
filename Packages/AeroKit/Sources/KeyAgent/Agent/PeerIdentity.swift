import Darwin
import Foundation
import Security

/// Who is on the other end of an agent connection.
public struct PeerIdentity: Sendable, Hashable {
    public var pid: pid_t
    public var uid: uid_t
    /// From `proc_pidpath`; `nil` if the process is already gone.
    public var executablePath: String?
    /// The code-signing identifier (e.g. `com.apple.ssh`), read via the audit token.
    public var codeSigningIdentifier: String?
    public var teamIdentifier: String?
    /// The peer satisfies `identifier "com.apple.ssh" and anchor apple` (checked via the audit
    /// token, so a recycled PID cannot fake it).
    public var isAppleSSH: Bool
    public var parentPID: pid_t?
    /// Parent, grandparent, … up to (not including) launchd.
    public var ancestorPIDs: [pid_t]
    /// The app's process is among ``ancestorPIDs``.
    public var startedByApp: Bool

    public init(
        pid: pid_t, uid: uid_t, executablePath: String?, codeSigningIdentifier: String?, teamIdentifier: String?,
        isAppleSSH: Bool, parentPID: pid_t?, ancestorPIDs: [pid_t], startedByApp: Bool
    ) {
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
        self.codeSigningIdentifier = codeSigningIdentifier
        self.teamIdentifier = teamIdentifier
        self.isAppleSSH = isAppleSSH
        self.parentPID = parentPID
        self.ancestorPIDs = ancestorPIDs
        self.startedByApp = startedByApp
    }

    /// Apple's `/usr/bin/ssh`, started (directly or indirectly) by AeroOps. Only such peers may
    /// sign without Touch ID, and only when the key's policy allows it.
    public var isTrustedAppSSH: Bool {
        executablePath == "/usr/bin/ssh" && isAppleSSH && startedByApp
    }

    /// For logs: `pid 123 /usr/bin/ssh (com.apple.ssh, started by AeroOps)`.
    public var summary: String {
        var parts = ["pid \(pid)", executablePath ?? "<unknown executable>"]
        var details: [String] = []
        if let codeSigningIdentifier { details.append(codeSigningIdentifier) }
        details.append(startedByApp ? "started by AeroOps" : "not started by AeroOps")
        parts.append("(\(details.joined(separator: ", ")))")
        return parts.joined(separator: " ")
    }
}

/// Reads a connected Unix socket's peer: credentials, audit token, code signature and ancestry.
enum PeerInspector {
    /// The connected process's uid, or `nil` if the kernel does not say.
    static func peerUID(_ fd: Int32) -> uid_t? {
        var cred = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &length) == 0, cred.cr_version == XUCRED_VERSION else { return nil }
        return cred.cr_uid
    }

    static func inspect(_ fd: Int32, appProcessID: pid_t) -> PeerIdentity? {
        guard let uid = peerUID(fd) else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }

        var identifier: String?
        var team: String?
        var isAppleSSH = false
        var token = audit_token_t()
        length = socklen_t(MemoryLayout<audit_token_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0, let code = Self.code(for: token) {
            (identifier, team) = Self.signingInfo(code)
            isAppleSSH = SecCodeCheckValidity(code, [], Self.appleSSHRequirement) == errSecSuccess
        }
        let ancestors = Self.ancestors(of: pid)
        return PeerIdentity(
            pid: pid, uid: uid, executablePath: Self.executablePath(pid), codeSigningIdentifier: identifier,
            teamIdentifier: team, isAppleSSH: isAppleSSH, parentPID: ancestors.first, ancestorPIDs: ancestors,
            startedByApp: ancestors.contains(appProcessID))
    }

    // `SecRequirement` is immutable once created.
    nonisolated(unsafe) private static let appleSSHRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        SecRequirementCreateWithString("identifier \"com.apple.ssh\" and anchor apple" as CFString, [], &requirement)
        return requirement
    }()

    private static func code(for token: audit_token_t) -> SecCode? {
        var token = token
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func signingInfo(_ code: SecCode) -> (identifier: String?, team: String?) {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, nil) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return (nil, nil) }
        return (info[kSecCodeInfoIdentifier as String] as? String, info[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The parent chain of `pid`, nearest first, stopping before launchd (pid 1).
    /// Bounded, so a PID-reuse cycle cannot loop forever.
    static func ancestors(of pid: pid_t, maxDepth: Int = 64) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while chain.count < maxDepth, let parent = parentPID(of: current), parent > 1, parent != current, !chain.contains(parent) {
            chain.append(parent)
            current = parent
        }
        return chain
    }
}
