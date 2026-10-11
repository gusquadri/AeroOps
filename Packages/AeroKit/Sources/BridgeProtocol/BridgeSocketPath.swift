import Foundation

/// Where the bridge socket lives: `<root>/bridge.sock`, default root `~/.aeroops`.
///
/// `sun_path` on macOS holds 104 bytes including the terminating NUL, so the path may be at most
/// 103 bytes. Both the app and the CLI use this rule; the root is a parameter because
/// `AeroPaths` decides it.
public enum BridgeSocketPath {
    /// The socket's file name inside the root.
    public static let fileName = "bridge.sock"
    /// Size of `sockaddr_un.sun_path` on macOS.
    public static let sunPathCapacity = 104
    /// Longest usable path in bytes (one byte is the NUL).
    public static var maxPathBytes: Int { sunPathCapacity - 1 }

    /// Environment variable that points the CLI at another socket (tests and the dev harness).
    /// Client-side only: the app still checks the peer, so it grants nothing.
    public static let environmentVariable = "AEROOPS_BRIDGE_SOCKET"

    /// Why a socket path is unusable.
    public enum PathError: Error, Sendable, Hashable, CustomStringConvertible {
        case notAbsolute(String)
        case tooLong(path: String, bytes: Int)
        case containsNUL

        public var description: String {
            switch self {
            case .notAbsolute(let path): "Bridge socket path must be absolute: \(path)"
            case .tooLong(let path, let bytes):
                "Bridge socket path is \(bytes) bytes; macOS allows at most \(BridgeSocketPath.maxPathBytes): \(path)"
            case .containsNUL: "Bridge socket path contains a NUL byte"
            }
        }
    }

    /// `~/.aeroops` for the given home directory.
    public static func defaultRoot(home: URL) -> URL {
        home.appending(path: ".aeroops", directoryHint: .isDirectory)
    }

    /// `<root>/bridge.sock`, validated.
    public static func socketURL(root: URL) throws(PathError) -> URL {
        let url = root.appending(path: fileName, directoryHint: .notDirectory)
        try validate(url.path(percentEncoded: false))
        return url
    }

    /// Checks that `path` is absolute, has no NUL and fits `sun_path`.
    public static func validate(_ path: String) throws(PathError) {
        guard path.hasPrefix("/") else { throw .notAbsolute(path) }
        guard !path.utf8.contains(0) else { throw .containsNUL }
        let bytes = path.utf8.count
        guard bytes <= maxPathBytes else { throw .tooLong(path: path, bytes: bytes) }
    }

    /// A resolved socket location.
    public struct Resolved: Sendable, Hashable {
        public var path: String
        /// `true` when it came from ``environmentVariable``.
        public var isOverride: Bool
    }

    /// The socket the CLI should use: ``environmentVariable`` when set and non-empty, else
    /// `~/.aeroops/bridge.sock` under `home`.
    public static func resolve(environment: [String: String], home: URL) throws(PathError) -> Resolved {
        if let override = environment[environmentVariable], !override.isEmpty {
            try validate(override)
            return Resolved(path: override, isOverride: true)
        }
        let url = try socketURL(root: defaultRoot(home: home))
        return Resolved(path: url.path(percentEncoded: false), isOverride: false)
    }
}
