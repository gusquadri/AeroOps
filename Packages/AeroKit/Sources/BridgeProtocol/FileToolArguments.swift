import Foundation

public struct ListFilesArguments: Sendable, Hashable {
    public var host: String
    public var path: String

    public init(host: String, path: String = ".") {
        self.host = host
        self.path = path
    }
}

public struct UploadFileArguments: Sendable, Hashable {
    public var host: String
    public var localPath: String
    public var remotePath: String
    public var overwrite: Bool

    public init(host: String, localPath: String, remotePath: String, overwrite: Bool = false) {
        self.host = host
        self.localPath = localPath
        self.remotePath = remotePath
        self.overwrite = overwrite
    }
}

public struct DownloadFileArguments: Sendable, Hashable {
    public var host: String
    public var remotePath: String
    public var localPath: String
    public var overwrite: Bool

    public init(host: String, remotePath: String, localPath: String, overwrite: Bool = false) {
        self.host = host
        self.remotePath = remotePath
        self.localPath = localPath
        self.overwrite = overwrite
    }
}

public enum FileCall: Sendable, Hashable {
    case list(ListFilesArguments)
    case upload(UploadFileArguments)
    case download(DownloadFileArguments)

    public var host: String {
        switch self {
        case .list(let a): a.host
        case .upload(let a): a.host
        case .download(let a): a.host
        }
    }

    static func parse(_ tool: BridgeTool, _ arguments: [String: JSONValue]) throws(ToolArgumentError) -> FileCall {
        switch tool {
        case .listFiles:
            let r = try ArgumentReader(tool, arguments, allowed: ["host", "path"])
            return .list(ListFilesArguments(host: try r.host(), path: try r.path("path") ?? "."))
        case .uploadFile:
            let r = try ArgumentReader(tool, arguments, allowed: ["host", "localPath", "remotePath", "overwrite"])
            return .upload(UploadFileArguments(host: try r.host(), localPath: try r.requiredPath("localPath"),
                                               remotePath: try r.requiredPath("remotePath"), overwrite: try r.bool("overwrite") ?? false))
        case .downloadFile:
            let r = try ArgumentReader(tool, arguments, allowed: ["host", "remotePath", "localPath", "overwrite"])
            return .download(DownloadFileArguments(host: try r.host(), remotePath: try r.requiredPath("remotePath"),
                                                   localPath: try r.requiredPath("localPath"), overwrite: try r.bool("overwrite") ?? false))
        default:
            throw ToolArgumentError("Unknown tool '\(tool.rawValue)'.")
        }
    }
}

extension ArgumentReader {
    func path(_ key: String) throws(ToolArgumentError) -> String? {
        guard let path = try string(key) else { return nil }
        if path.isEmpty { throw ToolArgumentError("Argument '\(key)' must not be empty.") }
        if path.utf8.count > BridgeLimits.maxPathBytes {
            throw ToolArgumentError("Argument '\(key)' is \(path.utf8.count) bytes long; the limit is \(BridgeLimits.maxPathBytes).")
        }
        try Self.checkCharacters(path, key: key, allowNewlines: false)
        return path
    }

    func requiredPath(_ key: String) throws(ToolArgumentError) -> String {
        guard let path = try path(key) else { throw ToolArgumentError("Missing required argument '\(key)'.") }
        return path
    }
}
