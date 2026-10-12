import Darwin
import Foundation

/// Why the helper has no password for ssh. The message is safe to print: it never holds a secret.
public struct AskpassFailure: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The helper's side of ``Askpass``: one request, one reply, then the connection closes.
public enum AskpassClient {
    /// Asks the app for the password ssh prompts for.
    ///
    /// - Parameters:
    ///   - prompt: ssh's prompt (the helper's first argument).
    ///   - environment: The helper's environment: the ``Askpass/Environment`` variables and
    ///     `SSH_ASKPASS_PROMPT`.
    public static func password(prompt: String, environment: [String: String]) throws(AskpassFailure) -> String {
        guard Askpass.isPasswordPrompt(prompt, kind: environment[Askpass.Environment.promptKind]) else {
            throw AskpassFailure("not a password prompt; AeroOps only answers password prompts")
        }
        guard let socketPath = environment[Askpass.Environment.socket], socketPath.hasPrefix("/") else {
            throw AskpassFailure("\(Askpass.Environment.socket) is not set; AeroOps starts this helper itself")
        }
        guard let hostText = environment[Askpass.Environment.host], let host = UUID(uuidString: hostText) else {
            throw AskpassFailure("\(Askpass.Environment.host) is missing or not a host id")
        }
        let token = environment[Askpass.Environment.token].flatMap { $0.isEmpty ? nil : $0 }
        if let token, !Askpass.isValidToken(token) {
            throw AskpassFailure("\(Askpass.Environment.token) is malformed")
        }

        let fd = try connect(socketPath)
        defer { close(fd) }
        AskpassWire.configure(fd, timeoutSeconds: Askpass.timeoutSeconds)
        let request = AskpassRequest(host: host, token: token, prompt: prompt)
        guard AskpassWire.writeAll(fd, AskpassWire.line(request)) else {
            throw AskpassFailure("could not send the request to AeroOps")
        }
        guard let line = AskpassWire.readLine(fd), let reply = AskpassWire.decode(AskpassReply.self, from: line) else {
            throw AskpassFailure("AeroOps did not answer")
        }
        if let password = reply.password, Askpass.passwordProblem(password) == nil {
            return password
        }
        throw AskpassFailure(reply.refusal ?? "AeroOps sent no usable password")
    }

    private static func connect(_ path: String) throws(AskpassFailure) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AskpassFailure("socket(): \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw AskpassFailure("socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw AskpassFailure("AeroOps is not answering on \(path): \(reason)")
        }
        return fd
    }
}
