// Who is on the other end of the agent socket?
import Darwin
import Foundation
import Security

struct PeerInfo: CustomStringConvertible {
    var pid: pid_t = -1
    var uid: uid_t = .max
    var path = "?"
    var ppid: pid_t = -1
    var parentPath = "?"
    var signingID = "?"
    var teamID = "-"
    var isAppleSSH = false

    var description: String {
        "pid=\(pid) uid=\(uid) exe=\(path) ppid=\(ppid) parent=\(parentPath) codesign=\(signingID) team=\(teamID) appleSSH=\(isAppleSSH)"
    }
}

func executablePath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "?(errno \(errno))"
}

func parentPID(_ pid: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : -1
}

func peerInfo(fd: Int32) -> PeerInfo {
    var p = PeerInfo()

    var len = socklen_t(MemoryLayout<pid_t>.size)
    if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &p.pid, &len) != 0 { return p }

    var cred = xucred()
    len = socklen_t(MemoryLayout<xucred>.size)
    if getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) == 0 { p.uid = cred.cr_uid }

    p.path = executablePath(p.pid)
    p.ppid = parentPID(p.pid)
    if p.ppid > 0 { p.parentPath = executablePath(p.ppid) }

    // The audit token pins the exact process instance (immune to PID reuse),
    // so code-signing checks should use it rather than the PID.
    var token = audit_token_t()
    len = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return p }
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }

    var code: SecCode?
    let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return p }

    var req: SecRequirement?
    if SecRequirementCreateWithString(#"identifier "com.apple.ssh" and anchor apple"# as CFString, [], &req) == errSecSuccess {
        p.isAppleSSH = SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return p }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [CFString: Any] else { return p }
    p.signingID = dict[kSecCodeInfoIdentifier] as? String ?? "?"
    p.teamID = dict[kSecCodeInfoTeamIdentifier] as? String ?? "-"
    return p
}
