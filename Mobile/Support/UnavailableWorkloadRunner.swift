import AeroCore
import Collectors
import Foundation
import SSHKit

/// Fails every command: what the Containers tab runs when the keys could not be opened.
struct UnavailableWorkloadRunner: RemoteCommandRunning {
    let reason: String?

    func run(_ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration, outputLimit: Int) async throws -> SSHResult {
        throw MobileModelError.keyStoreUnavailable(reason)
    }

    func stream(
        _ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration?, maxBufferedLines: Int
    ) async throws -> AsyncThrowingStream<String, any Error> {
        throw MobileModelError.keyStoreUnavailable(reason)
    }
}
