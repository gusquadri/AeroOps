import Foundation
import Testing
@testable import SSHKit

/// stderr captured from OpenSSH_10.3p1 (macOS) against OpenSSH_10.3 (dev container) and
/// unreachable addresses, with ssh's `\r\n` line ends kept.
@Suite("SSHError classification")
struct SSHErrorTests {
    static let changedBanner = """
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r
    @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r
    IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!\r
    Someone could be eavesdropping on you right now (man-in-the-middle attack)!\r
    It is also possible that a host key has just been changed.\r
    The fingerprint for the ED25519 key sent by the remote host is
    SHA256:koNW6caWP9qADQ1kYhXgl2kfMSyJ2dLyxE1SOhdE8lg.\r
    Please contact your system administrator.\r
    Add correct host key in /tmp/aeroprobe/kh-changed to get rid of this message.\r
    Offending ED25519 key in /tmp/aeroprobe/kh-changed:1\r
    Host key for [localhost]:2222 has changed and you have requested strict checking.\r
    Host key verification failed.\r

    """

    @Test("real OpenSSH 10.3 messages", arguments: [
        (changedBanner, SSHError.hostKeyChanged),
        ("No ED25519 host key is known for [localhost]:2222 and you have requested strict checking.\r\nHost key verification failed.\r\n", .hostKeyUnknown),
        ("Host key verification failed.\r\n", .hostKeyUnknown),
        ("dev@localhost: Permission denied (publickey,keyboard-interactive).\r\n", .authFailed),
        ("ssh: connect to host localhost port 1: Connection refused\r\n", .connectionRefused),
        ("ssh: Could not resolve hostname nonexistent-host.invalid: nodename nor servname provided, or not known\r\n", .nameResolutionFailed),
        ("ssh: connect to host 10.255.255.1 port 22: Operation timed out\r\n", .timeout),
        ("Connection timed out during banner exchange\r\n", .timeout),
        ("ssh: connect to host 0.0.0.1 port 22: No route to host\r\n", .hostUnreachable),
        ("Connection closed by 127.0.0.1 port 2299\r\n", .connectionClosed),
        ("kex_exchange_identification: read: Connection reset by peer\r\n", .connectionClosed),
        ("ssh_dispatch_run_fatal: Connection to 127.0.0.1 port 2297: Broken pipe\r\n", .connectionClosed),
        ("", .other("")),
        ("  something odd happened\r\n", .other("something odd happened")),
    ] as [(String, SSHError)])
    func classify(stderr: String, expected: SSHError) {
        #expect(SSHError.classify(stderr: stderr) == expected)
    }

    @Test("other() is trimmed and capped")
    func capped() {
        guard case .other(let text) = SSHError.classify(stderr: String(repeating: "x", count: 10_000)) else {
            Issue.record("expected other")
            return
        }
        #expect(text.count == SSHError.messageLimit + 1)
    }

    @Test("every case has a description")
    func descriptions() {
        let all: [SSHError] = [
            .hostKeyUnknown, .hostKeyChanged, .authFailed, .connectionRefused, .timeout, .hostUnreachable,
            .nameResolutionFailed, .connectionClosed, .launchFailed("x"), .remoteCommandFailed(exitCode: 1, stderr: ""),
            .invalidRequest("x"), .other(""),
        ]
        for error in all { #expect(error.errorDescription?.isEmpty == false) }
    }
}
