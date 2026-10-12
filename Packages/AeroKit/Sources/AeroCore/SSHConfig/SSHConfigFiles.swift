import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where an OpenSSH client config lives, and how its `Include` paths resolve.
public struct SSHConfigLocations: Sendable, Hashable {
    /// Absolute path of the top-level file, normally `~/.ssh/config`.
    public var configFile: String
    /// Base for relative `Include` paths. OpenSSH uses `~/.ssh` for user configs, whichever
    /// file the `Include` is in.
    public var sshDirectory: String
    /// What `~` expands to in `Include` paths.
    public var homeDirectory: String

    public init(configFile: String, sshDirectory: String, homeDirectory: String) {
        self.configFile = configFile
        self.sshDirectory = sshDirectory
        self.homeDirectory = homeDirectory
    }

    /// `~/.ssh/config` for the given home directory.
    public static func user(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SSHConfigLocations {
        let home = home.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlashes()
        return SSHConfigLocations(configFile: home + "/.ssh/config", sshDirectory: home + "/.ssh", homeDirectory: home)
    }

    /// A config file somewhere else (a test fixture): relative includes resolve next to it, and
    /// `~` is its directory's parent, so nothing under the real `~/.ssh` is read.
    public static func standalone(configFile: URL) -> SSHConfigLocations {
        let file = configFile.standardizedFileURL
        let directory = file.deletingLastPathComponent()
        return SSHConfigLocations(
            configFile: file.path(percentEncoded: false),
            sshDirectory: directory.path(percentEncoded: false).trimmingTrailingSlashes(),
            homeDirectory: directory.deletingLastPathComponent().path(percentEncoded: false).trimmingTrailingSlashes()
        )
    }
}

/// Why a config file could not be read.
public enum SSHConfigFileError: Error, Sendable, Hashable {
    /// The file exists but could not be opened or read.
    case unreadable(reason: String)
    /// The file is larger than ``LocalSSHConfigFiles/maxFileSize``.
    case tooLarge
    /// The path is a directory, FIFO, device or socket rather than a regular file.
    case notARegularFile

    /// A short explanation for the import sheet.
    public var reason: String {
        switch self {
        case .unreadable(let reason): reason
        case .tooLarge: "it is larger than 1 MB"
        case .notARegularFile: "it is not a regular file"
        }
    }
}

/// Read-only access to config files, so the parser can run against fixtures in tests.
public protocol SSHConfigFileReading: Sendable {
    /// The text of the file at the absolute `path`, or `nil` if nothing exists there.
    func contents(ofFile path: String) throws(SSHConfigFileError) -> String?
    /// Absolute paths matching the glob `pattern` (`*`, `?`, `[…]`), sorted. Empty when nothing
    /// matches.
    func paths(matching pattern: String) -> [String]
}

/// The real file system, read-only: `open(2)` + `read(2)` for regular files up to
/// ``maxFileSize``, and `glob(3)` for `Include` patterns. It never writes anything.
public struct LocalSSHConfigFiles: SSHConfigFileReading {
    /// Larger files are refused. Real configs are a few kilobytes.
    public static let maxFileSize = 1 << 20

    public init() {}

    public func contents(ofFile path: String) throws(SSHConfigFileError) -> String? {
        // O_NONBLOCK: opening a FIFO must not hang; it is refused below as not a regular file.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw .unreadable(reason: String(cString: strerror(code)))
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(reason: String(cString: strerror(errno))) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notARegularFile }
        guard info.st_size <= off_t(Self.maxFileSize) else { throw .tooLarge }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(reason: String(cString: strerror(errno)))
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[..<count])
            // The file may have grown since fstat.
            guard data.count <= Self.maxFileSize else { throw .tooLarge }
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func paths(matching pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }
}

extension String {
    /// `"/a/b/"` → `"/a/b"`; `"/"` stays `"/"`.
    func trimmingTrailingSlashes() -> String {
        var result = self
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
