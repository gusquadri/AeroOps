import Foundation

public enum LocalFileAccess {
    public static func authorize(_ call: FileCall, workingDirectory: String) throws(ToolArgumentError) -> String? {
        switch call {
        case .list:
            nil
        case .upload(let a):
            try readableFile(absolute(a.localPath, from: workingDirectory))
        case .download(let a):
            try writableFile(absolute(a.localPath, from: workingDirectory), overwrite: a.overwrite)
        }
    }

    static func absolute(_ path: String, from workingDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : (workingDirectory as NSString).appendingPathComponent(expanded)
    }

    static func readableFile(_ path: String) throws(ToolArgumentError) -> String {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure(path, errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ToolArgumentError("localPath \(String(reflecting: path)) is not a regular file.")
        }
        return try canonical(path)
    }

    static func writableFile(_ path: String, overwrite: Bool) throws(ToolArgumentError) -> String {
        let directory = try canonical((path as NSString).deletingLastPathComponent)
        guard access(directory, W_OK) == 0 else { throw failure(directory, errno) }
        let target = (directory as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        var info = stat()
        guard lstat(target, &info) == 0 else { return target }
        guard overwrite else {
            throw ToolArgumentError("localPath \(String(reflecting: target)) already exists. Pass overwrite: true to replace it.")
        }
        guard info.st_mode & S_IFMT == S_IFREG, access(target, W_OK) == 0 else {
            throw ToolArgumentError("localPath \(String(reflecting: target)) exists and is not a writable regular file.")
        }
        return target
    }

    static func canonical(_ path: String) throws(ToolArgumentError) -> String {
        guard let resolved = realpath(path, nil) else { throw failure(path, errno) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func failure(_ path: String, _ code: Int32) -> ToolArgumentError {
        ToolArgumentError("Cannot use local path \(String(reflecting: path)): \(String(cString: strerror(code))).")
    }
}
