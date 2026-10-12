import AskpassProtocol
import Foundation
import Testing

@Suite("Askpass protocol")
struct AskpassProtocolTests {
    @Test("answers ssh's and PAM's login password prompts", arguments: [
        "dev@localhost's password: ",
        "deploy@10.0.0.12's password:",
        "Password:",
        "password: ",
        "(dev@localhost) Password: ",
        "(dev@[::1]) Password for dev: ",
        "Password for deploy@EXAMPLE.COM: ",
        "  PASSWORD:  ",
    ])
    func passwordPrompts(_ prompt: String) {
        #expect(Askpass.isPasswordPrompt(prompt))
    }

    @Test("refuses everything that is not the login password", arguments: [
        "",
        "Enter passphrase for key '/Users/me/.ssh/id_ed25519': ",
        "(current) UNIX password: ",
        "(dev@localhost) (current) UNIX password: ",
        "New password: ",
        "Retype new password: ",
        "(dev@localhost) Verification code: ",
        "One-time password (OATH) for `dev': ",
        "Allow use of key /x?\nKey fingerprint SHA256:abc.",
        "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
        "Old password:",
        "Password expired. Change your password now.",
    ])
    func otherPrompts(_ prompt: String) {
        #expect(!Askpass.isPasswordPrompt(prompt))
    }

    @Test("a non-empty SSH_ASKPASS_PROMPT is never a secret prompt")
    func promptKind() {
        #expect(Askpass.isPasswordPrompt("Password:", kind: ""))
        #expect(!Askpass.isPasswordPrompt("Password:", kind: "confirm"))
        #expect(!Askpass.isPasswordPrompt("Password:", kind: "none"))
        #expect(!Askpass.isPasswordPrompt(String(repeating: "a", count: 2000) + "'s password:"))
    }

    @Test("passwords ssh cannot read back are refused")
    func passwordProblems() {
        #expect(Askpass.passwordProblem("hunter2") == nil)
        #expect(Askpass.passwordProblem("späce and ünïcode 🔑") == nil)
        #expect(Askpass.passwordProblem("") == .empty)
        #expect(Askpass.passwordProblem("a\nb") == .lineBreak)
        #expect(Askpass.passwordProblem("a\rb") == .lineBreak)
        #expect(Askpass.passwordProblem("a\0b") == .lineBreak)
        #expect(Askpass.passwordProblem(String(repeating: "x", count: Askpass.maxPasswordBytes)) == nil)
        #expect(Askpass.passwordProblem(String(repeating: "x", count: Askpass.maxPasswordBytes + 1)) == .tooLong)
    }

    @Test("tokens are 32 random lower-case hex digits")
    func tokens() {
        let first = Askpass.makeToken()
        #expect(first.count == 32)
        #expect(Askpass.isValidToken(first))
        #expect(first != Askpass.makeToken())
        #expect(!Askpass.isValidToken("ABCDEF0123456789ABCDEF0123456789"))
        #expect(!Askpass.isValidToken("abc"))
        #expect(!Askpass.isValidToken("0123456789abcdef; rm -rf /"))
    }

    @Test("requests and replies round-trip as one JSON line")
    func wire() throws {
        let request = AskpassRequest(host: UUID(), token: Askpass.makeToken(), prompt: "dev@h's password: ")
        let line = AskpassWire.line(request)
        #expect(line.last == UInt8(ascii: "\n"))
        #expect(!line.dropLast().contains(UInt8(ascii: "\n")))
        #expect(AskpassWire.decode(AskpassRequest.self, from: line.dropLast()) == request)
        #expect(String(decoding: line, as: UTF8.self).contains(#""v":1"#))

        let reply = AskpassReply.password("a \"quoted\" pass\\word")
        #expect(AskpassWire.decode(AskpassReply.self, from: AskpassWire.line(reply).dropLast()) == reply)
        #expect(AskpassWire.decode(AskpassReply.self, from: Data("not json".utf8)) == nil)
    }

    @Test("readLine stops at the newline and enforces the limit")
    func readLine() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        AskpassWire.configure(fds[0], timeoutSeconds: 2)
        #expect(AskpassWire.writeAll(fds[1], Data("hello\n".utf8)))
        #expect(AskpassWire.readLine(fds[0]) == Data("hello".utf8))
        #expect(AskpassWire.writeAll(fds[1], Data(repeating: UInt8(ascii: "x"), count: 50) + Data("\n".utf8)))
        #expect(AskpassWire.readLine(fds[0], limit: 10) == nil)
    }

    @Test("the client refuses before connecting when the environment is wrong")
    func clientPreflight() {
        let host = UUID().uuidString
        func failure(_ prompt: String, _ environment: [String: String]) -> String? {
            do {
                _ = try AskpassClient.password(prompt: prompt, environment: environment)
                return nil
            } catch {
                return error.message
            }
        }
        #expect(failure("New password:", [:])?.contains("not a password prompt") == true)
        #expect(failure("Password:", ["SSH_ASKPASS_PROMPT": "confirm"])?.contains("not a password prompt") == true)
        #expect(failure("Password:", [:])?.contains("AEROOPS_ASKPASS_SOCKET") == true)
        #expect(failure("Password:", ["AEROOPS_ASKPASS_SOCKET": "/tmp/x.sock"])?.contains("AEROOPS_ASKPASS_HOST") == true)
        #expect(failure("Password:", [
            "AEROOPS_ASKPASS_SOCKET": "/tmp/x.sock", "AEROOPS_ASKPASS_HOST": host, "AEROOPS_ASKPASS_TOKEN": "nope",
        ])?.contains("malformed") == true)
        #expect(failure("Password:", [
            "AEROOPS_ASKPASS_SOCKET": "/tmp/aeroops-no-such-\(UUID().uuidString.prefix(8)).sock", "AEROOPS_ASKPASS_HOST": host,
        ])?.contains("not answering") == true)
    }
}
