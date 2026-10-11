import Darwin
import Foundation

/// Small POSIX file helpers shared by the config writer and the known_hosts store.
enum FileSystem {
    /// A failed system call, with the path it was about.
    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let path: String
        let code: Int32

        var description: String { "\(operation) \(path): \(String(cString: strerror(code)))" }
    }

    /// Writes `data` to `url` atomically: a temporary file in the same directory, created with
    /// `permissions` (never wider), then `rename(2)` over the target. Readers see either the old or
    /// the new contents, never a partial file.
    static func writeAtomically(_ data: Data, to url: URL, permissions: mode_t) throws(Failure) {
        let path = url.filePath
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))").filePath
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions)
        guard fd >= 0 else { throw Failure(operation: "open", path: temp, code: errno) }
        var failure: Failure?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    failure = Failure(operation: "write", path: temp, code: n < 0 ? errno : EIO)
                    return
                }
            }
        }
        if failure == nil, fchmod(fd, permissions) != 0 {
            failure = Failure(operation: "chmod", path: temp, code: errno)
        }
        if failure == nil, fsync(fd) != 0 {
            failure = Failure(operation: "fsync", path: temp, code: errno)
        }
        close(fd)
        if failure == nil, rename(temp, path) != 0 {
            failure = Failure(operation: "rename", path: path, code: errno)
        }
        if let failure {
            unlink(temp)
            throw failure
        }
    }

    /// Creates `url` (one level) if missing and forces its mode to `permissions`.
    /// Fails if the path exists but is not a directory (including a symlink to one).
    static func ensureDirectory(_ url: URL, permissions: mode_t) throws(Failure) {
        let path = url.filePath
        if mkdir(path, permissions) != 0 && errno != EEXIST {
            throw Failure(operation: "mkdir", path: path, code: errno)
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failure(operation: "stat", path: path, code: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure(operation: "mkdir", path: path, code: ENOTDIR) }
        if info.st_mode & 0o7777 != permissions, chmod(path, permissions) != 0 {
            throw Failure(operation: "chmod", path: path, code: errno)
        }
    }

    /// Reads a UTF-8 text file; a missing file reads as `nil`.
    static func readText(_ url: URL) throws(Failure) -> String? {
        let path = url.filePath
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Failure(operation: "open", path: path, code: errno)
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                break
            } else if errno != EINTR {
                throw Failure(operation: "read", path: path, code: errno)
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
