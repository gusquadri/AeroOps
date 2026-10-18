import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SSHKit
import Synchronization

/// ``SSHKit/HostKeyScanning`` for iOS, which has no `ssh-keyscan`: one connection that stops
/// after the key exchange. It returns the one key the server proves it holds in that exchange,
/// which is also the key ``EmbeddedSSHClient`` checks on every later connection.
public struct EmbeddedHostKeyScanner: HostKeyScanning {
    private let group: any EventLoopGroup

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
    }

    public func scan(address: String, port: Int) async throws -> [HostKey] {
        guard HostValidation.isValidAddress(address) else { throw HostKeyError.invalidHost("“\(address)” is not a valid address") }
        guard (1...65535).contains(port) else { throw HostKeyError.invalidHost("port \(port) is outside 1–65535") }
        try Task.checkCancellation()
        let received = Received()
        let connection: SSHConnection
        do {
            connection = try await SSHConnection.connect(address: address, port: port, group: group) {
                (
                    NoUserAuth(),
                    HostKeyDelegate { key in
                        received.key = key
                        throw ScanFinished()
                    }
                )
            }
        } catch {
            if let key = received.key { return [key] }
            throw EmbeddedSSHErrors.classify(error)
        }
        // Not reached: the host-key check always ends the connection.
        connection.close()
        if let key = received.key { return [key] }
        throw SSHError.other("The server did not send a host key.")
    }

    private struct ScanFinished: Error {}

    private final class Received: Sendable {
        private let state = Mutex<HostKey?>(nil)

        var key: HostKey? {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    /// Never reached: the scan ends at the host key.
    private final class NoUserAuth: NIOSSHClientUserAuthenticationDelegate {
        func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            nextChallengePromise.fail(ScanFinished())
        }
    }
}
