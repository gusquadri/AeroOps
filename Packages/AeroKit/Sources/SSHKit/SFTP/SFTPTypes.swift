import Darwin
import Foundation

/// A path on the remote side, as raw bytes.
///
/// SFTP paths are byte strings. Names that are not valid UTF-8 still work: ``string`` is only
/// for display (invalid bytes become U+FFFD), while operations always send ``bytes``.
public struct SFTPPath: Sendable, Hashable, CustomStringConvertible {
    /// The path as sent to the server.
    public let bytes: Data

    /// A path from raw bytes.
    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// A path from a string, sent as UTF-8.
    public init(_ string: String) {
        bytes = Data(string.utf8)
    }

    /// The root directory, `/`.
    public static let root = SFTPPath("/")

    /// The path for display.
    public var string: String { String(decoding: bytes, as: UTF8.self) }

    public var description: String { string }

    /// Starts with `/`.
    public var isAbsolute: Bool { bytes.first == UInt8(ascii: "/") }

    /// The last component (`file.txt` for `/srv/file.txt`), or the path itself for `/`.
    public var lastComponent: Data {
        let trimmed = trimmingTrailingSlashes
        guard let slash = trimmed.lastIndex(of: UInt8(ascii: "/")) else { return trimmed }
        let name = trimmed[trimmed.index(after: slash)...]
        return name.isEmpty ? trimmed : Data(name)
    }

    /// The last component for display.
    public var name: String { String(decoding: lastComponent, as: UTF8.self) }

    /// The containing directory, or `nil` for `/` and for relative paths without a slash.
    public var parent: SFTPPath? {
        let trimmed = trimmingTrailingSlashes
        guard trimmed != Data("/".utf8), let slash = trimmed.lastIndex(of: UInt8(ascii: "/")) else { return nil }
        if slash == trimmed.startIndex { return .root }
        return SFTPPath(bytes: Data(trimmed[trimmed.startIndex..<slash]))
    }

    /// This path with `name` (one component, as raw bytes) appended.
    public func appending(component name: Data) -> SFTPPath {
        var result = bytes
        if result.last != UInt8(ascii: "/") { result.append(UInt8(ascii: "/")) }
        result.append(name)
        return SFTPPath(bytes: result)
    }

    /// This path with `name` (one component) appended.
    public func appending(component name: String) -> SFTPPath {
        appending(component: Data(name.utf8))
    }

    private var trimmingTrailingSlashes: Data {
        var end = bytes.endIndex
        while end > bytes.startIndex + 1, bytes[end - 1] == UInt8(ascii: "/") { end -= 1 }
        return Data(bytes[bytes.startIndex..<end])
    }
}

/// File attributes as the server reports them. Every field is optional in SFTP.
public struct SFTPAttributes: Sendable, Hashable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    /// `st_mode`: file type and permission bits.
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?

    public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil,
                accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    /// What kind of file the permissions say this is.
    public var kind: SFTPFileKind {
        guard let permissions else { return .unknown }
        switch permissions & UInt32(S_IFMT) {
        case UInt32(S_IFREG): return .regular
        case UInt32(S_IFDIR): return .directory
        case UInt32(S_IFLNK): return .symlink
        default: return .other
        }
    }

    /// The permission bits (`0o7777`), if known.
    public var mode: UInt32? { permissions.map { $0 & 0o7777 } }

    /// The modification time, if known.
    public var modificationDate: Date? {
        modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// A file's type, from its mode.
public enum SFTPFileKind: Sendable, Hashable {
    case regular, directory, symlink, other, unknown
}

/// One directory entry from ``SFTPClient/list(_:)``. Attributes are the entry's own (symlinks
/// are not followed).
public struct SFTPEntry: Sendable, Hashable {
    /// The name as raw bytes (one path component).
    public let name: Data
    public let attributes: SFTPAttributes
    /// The full path (the listed directory plus ``name``).
    public let path: SFTPPath

    public init(name: Data, attributes: SFTPAttributes, path: SFTPPath) {
        self.name = name
        self.attributes = attributes
        self.path = path
    }

    /// The name for display (invalid UTF-8 becomes U+FFFD).
    public var displayName: String { String(decoding: name, as: UTF8.self) }
}

/// An open remote file or directory handle (opaque to the client).
public struct SFTPFileHandle: Sendable, Hashable {
    let raw: Data
}

/// An SFTP status code (draft-ietf-secsh-filexfer-02, section 7).
public struct SFTPStatusCode: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let ok = SFTPStatusCode(rawValue: 0)
    public static let eof = SFTPStatusCode(rawValue: 1)
    public static let noSuchFile = SFTPStatusCode(rawValue: 2)
    public static let permissionDenied = SFTPStatusCode(rawValue: 3)
    public static let failure = SFTPStatusCode(rawValue: 4)
    public static let badMessage = SFTPStatusCode(rawValue: 5)
    public static let noConnection = SFTPStatusCode(rawValue: 6)
    public static let connectionLost = SFTPStatusCode(rawValue: 7)
    public static let operationUnsupported = SFTPStatusCode(rawValue: 8)

    public var description: String {
        switch self {
        case .ok: "OK"
        case .eof: "End of file"
        case .noSuchFile: "No such file or directory"
        case .permissionDenied: "Permission denied"
        case .failure: "Failure"
        case .badMessage: "Bad message"
        case .noConnection: "No connection"
        case .connectionLost: "Connection lost"
        case .operationUnsupported: "Operation not supported"
        default: "Status \(rawValue)"
        }
    }
}

/// Why an SFTP operation failed.
public enum SFTPError: Error, Sendable, Hashable, LocalizedError {
    /// The server refused the request.
    case status(SFTPStatusCode, message: String)
    /// The session ended: ssh failed to connect (see ``SSHError``) or the connection dropped.
    case disconnected(SSHError)
    /// The server sent something that is not valid SFTP, or a version this client does not speak.
    case protocolError(String)
    /// A name that cannot be used as a path component (empty, `.`, `..`, or with `/` or NUL).
    case invalidName(String)
    /// A local file operation failed.
    case local(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .status(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == code.description ? code.description : "\(code.description): \(trimmed)"
        case .disconnected(let error):
            return error.errorDescription ?? "The SFTP session ended."
        case .protocolError(let message):
            return "SFTP protocol error: \(message)"
        case .invalidName(let name):
            return "“\(name)” can’t be used as a file name."
        case .local(let path, let message):
            return "\(path): \(message)"
        }
    }

    /// The server reported that the file does not exist.
    public var isNoSuchFile: Bool {
        if case .status(.noSuchFile, _) = self { true } else { false }
    }

    /// A local error from `errno`.
    static func local(_ path: String, errno code: Int32) -> SFTPError {
        .local(path: path, message: String(cString: strerror(code)))
    }
}

/// Checks a single path component that came from the other side before it is used to build a
/// path, so a hostile listing cannot escape the destination directory.
public enum PathComponent {
    /// `true` for a non-empty name other than `.` and `..` with no `/` or NUL.
    public static func isSafe(_ name: Data) -> Bool {
        !name.isEmpty
            && name != Data(".".utf8)
            && name != Data("..".utf8)
            && !name.contains(UInt8(ascii: "/"))
            && !name.contains(0)
    }

    /// `true` for a non-empty name other than `.` and `..` with no `/` or NUL.
    public static func isSafe(_ name: String) -> Bool {
        isSafe(Data(name.utf8))
    }
}
