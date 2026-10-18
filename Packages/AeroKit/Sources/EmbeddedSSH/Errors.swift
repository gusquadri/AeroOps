import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SSHKit

/// Turns NIO's and NIOSSH's errors into the ``SSHError`` cases the collectors and views already
/// handle for `/usr/bin/ssh`, so neither needs to know which client ran the command.
enum EmbeddedSSHErrors {
    static let unsupportedAlgorithms = SSHError.other(
        "The server offers no SSH algorithms this device supports (it needs curve25519 or ECDH key exchange, "
            + "AES-GCM, and an Ed25519 or ECDSA host key)."
    )

    /// `SSHError` and `CancellationError` pass through; everything else is classified.
    static func classify(_ error: any Error) -> any Error {
        switch error {
        case is SSHError, is CancellationError:
            return error
        case let error as NIOConnectionError:
            if error.connectionErrors.isEmpty, error.dnsAError != nil || error.dnsAAAAError != nil {
                return SSHError.nameResolutionFailed
            }
            if let first = error.connectionErrors.first { return classify(first.error) }
            return SSHError.hostUnreachable
        case is SocketAddressError:
            return SSHError.nameResolutionFailed
        case let error as IOError:
            return classify(errno: error.errnoCode) ?? SSHError.other(String(describing: error))
        case let error as ChannelError:
            switch error {
            case .connectTimeout: return SSHError.timeout
            case .eof, .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed: return SSHError.connectionClosed
            default: return SSHError.other(String(describing: error))
            }
        case let error as NIOSSHError:
            switch error.type {
            case .keyExchangeNegotiationFailure: return unsupportedAlgorithms
            case .tcpShutdown, .creatingChannelAfterClosure: return SSHError.connectionClosed
            case .channelSetupRejected: return SSHError.other("The server refused to open a session (\(error)).")
            default: return SSHError.other(String(describing: error))
            }
        case let error as any LocalizedError:
            // KeyStore's errors (a missing or unsupported key) and HostKeyStore's.
            return SSHError.other(error.errorDescription ?? String(describing: error))
        default:
            return SSHError.other(String(describing: error))
        }
    }

    static func classify(errno code: CInt) -> SSHError? {
        switch code {
        case ECONNREFUSED: .connectionRefused
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: .hostUnreachable
        case ETIMEDOUT: .timeout
        case ECONNRESET, EPIPE, ECONNABORTED: .connectionClosed
        default: nil
        }
    }

    /// The exit code a shell reports for a command killed by signal `name`: `128 + signo` for the
    /// signals whose numbers Linux and the BSDs share, 255 (what `ssh` exits with) for the rest.
    static func exitCode(forSignal name: String) -> Int32 {
        let numbers: [String: Int32] = [
            "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "ABRT": 6, "FPE": 8, "KILL": 9, "SEGV": 11,
            "PIPE": 13, "ALRM": 14, "TERM": 15,
        ]
        return numbers[name].map { 128 + $0 } ?? 255
    }
}
