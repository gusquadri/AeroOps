// Minimal ssh-agent server: REQUEST_IDENTITIES and SIGN_REQUEST only.
import CryptoKit
import Darwin
import Foundation
import Synchronization

func log(_ s: String) {
    let ts = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
    FileHandle.standardError.write(Data("[\(ts)] \(s)\n".utf8))
}

struct ServerError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String, errno e: Int32 = errno) { description = "\(what): \(String(cString: strerror(e))) (errno \(e))" }
    init(message: String) { description = message }
}

final class AgentServer: @unchecked Sendable {
    let keys: [any AgentKey]
    let socketPath: String
    private var listenFD: Int32 = -1
    private let counter = Mutex(0)

    init(keys: [any AgentKey], socketPath: String) {
        self.keys = keys
        self.socketPath = socketPath
    }

    func bindAndListen() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        var st = stat()
        if stat(dir, &st) != 0 {
            guard mkdir(dir, 0o700) == 0 else { throw ServerError("mkdir \(dir)") }
        } else if st.st_mode & 0o077 != 0 {
            log("tightening \(dir) from \(String(st.st_mode & 0o777, radix: 8)) to 700")
            chmod(dir, 0o700)
        }

        var addr = sockaddr_un()
        let pathBytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path) // 104 on Darwin, incl. NUL
        guard pathBytes.count < cap else {
            throw ServerError(message: "socket path is \(pathBytes.count) bytes; macOS limit is \(cap - 1)")
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError("socket") }

        // Remove a stale socket left by a crashed run (only if it is a socket).
        if lstat(socketPath, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK else { throw ServerError(message: "\(socketPath) exists and is not a socket") }
            unlink(socketPath)
        }

        // umask makes bind() create the node 0600 atomically: no window where it is wider.
        let oldMask = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard rc == 0 else { throw ServerError("bind \(socketPath)") }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else { throw ServerError("listen") }
        listenFD = fd
        log("listening on \(socketPath) (\(pathBytes.count) bytes)")
    }

    func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                log("accept: \(String(cString: strerror(errno)))")
                return
            }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let id = counter.withLock { $0 += 1; return $0 }
            DispatchQueue.global().async { self.serve(fd: c, id: id) }
        }
    }

    func shutdown() {
        if listenFD >= 0 { close(listenFD) }
        unlink(socketPath)
    }

    private func serve(fd: Int32, id: Int) {
        defer { close(fd) }
        log("conn#\(id) peer \(peerInfo(fd: fd))")
        while true {
            guard let header = readExactly(fd, 4) else { break }
            let len = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            // OpenSSH caps agent messages at 256 KiB (AGENT_MAX_LEN).
            guard len > 0, len <= 256 * 1024 else { log("conn#\(id) bad length \(len), closing"); break }
            guard let msg = readExactly(fd, len) else { log("conn#\(id) short read"); break }
            let reply = handle(msg, conn: id)
            guard writeAll(fd, WireWriter.frame(reply)) else { log("conn#\(id) write failed"); break }
        }
        log("conn#\(id) closed")
    }

    func handle(_ msg: [UInt8], conn id: Int) -> [UInt8] {
        var r = WireReader(msg)
        do {
            let type = try r.u8("type")
            switch type {
            case AgentMsg.requestIdentities:
                var w = WireWriter()
                w.u8(AgentMsg.identitiesAnswer)
                w.u32(UInt32(keys.count))
                for k in keys {
                    w.string(k.publicKeyBlob)
                    w.string(k.comment)
                }
                log("conn#\(id) REQUEST_IDENTITIES -> \(keys.count) keys")
                return w.bytes

            case AgentMsg.signRequest:
                let blob = try r.string("key blob")
                let data = try r.string("data")
                let flags = try r.u32("flags")
                guard let key = keys.first(where: { $0.publicKeyBlob == blob }) else {
                    log("conn#\(id) SIGN_REQUEST for unknown key -> FAILURE")
                    return [AgentMsg.failure]
                }
                let sig = try key.sign(data, flags: flags)
                var sr = WireReader(sig)
                let alg = String(decoding: try sr.string(), as: UTF8.self)
                log("conn#\(id) SIGN_REQUEST key=\(key.comment) flags=\(flags) \(describeUserAuth(data)) -> \(alg)")
                var w = WireWriter()
                w.u8(AgentMsg.signResponse)
                w.string(sig)
                return w.bytes

            case AgentMsg.extensionRequest:
                let name = String(decoding: try r.string("extension name"), as: UTF8.self)
                var detail = ""
                if name == "session-bind@openssh.com", let hostKey = try? r.string("hostkey") {
                    let fp = Data(SHA256.hash(data: Data(hostKey))).base64EncodedString().replacingOccurrences(of: "=", with: "")
                    var hk = WireReader(hostKey)
                    let hkType = (try? hk.string()).map { String(decoding: $0, as: UTF8.self) } ?? "?"
                    _ = try? r.string("session id")
                    _ = try? r.string("signature")
                    let fwd = (try? r.u8("is_forwarding")) ?? 0
                    detail = " hostkey=\(hkType) SHA256:\(fp) forwarding=\(fwd != 0)"
                }
                log("conn#\(id) EXTENSION \(name)\(detail) -> FAILURE (unsupported)")
                return [AgentMsg.failure]

            default:
                log("conn#\(id) \(AgentMsg.name(type)) -> FAILURE (refused)")
                return [AgentMsg.failure]
            }
        } catch {
            log("conn#\(id) error: \(error) -> FAILURE")
            return [AgentMsg.failure]
        }
    }
}

/// Best-effort decode of the data ssh asks us to sign (RFC 4252 §7):
/// string session_id, byte 50, string user, string service, string "publickey",
/// bool TRUE, string algorithm, string key blob; with OpenSSH's
/// "publickey-hostbound-v00@openssh.com" method a final string carries the
/// server host key. Note: no host *name* anywhere in here.
func describeUserAuth(_ data: [UInt8]) -> String {
    var r = WireReader(data)
    guard let sid = try? r.string(), (try? r.u8()) == 50,
          let user = try? r.string(), let service = try? r.string(), let method = try? r.string(),
          (try? r.u8()) != nil, let alg = try? r.string(), (try? r.string()) != nil
    else { return "data=\(data.count)B (not a userauth request)" }
    let s = { (b: [UInt8]) in String(decoding: b, as: UTF8.self) }
    var out = "userauth user=\(s(user)) service=\(s(service)) method=\(s(method)) alg=\(s(alg)) sid=\(sid.count)B"
    if s(method) == "publickey-hostbound-v00@openssh.com", let hostKey = try? r.string() {
        out += " hostkey=SHA256:" + Data(SHA256.hash(data: Data(hostKey))).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    return out
}

func readExactly(_ fd: Int32, _ n: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
        let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
        if r < 0, errno == EINTR { continue }
        if r <= 0 { return nil }
        got += r
    }
    return buf
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var sent = 0
    while sent < bytes.count {
        let r = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
        if r < 0, errno == EINTR { continue }
        if r <= 0 { return false }
        sent += r
    }
    return true
}
