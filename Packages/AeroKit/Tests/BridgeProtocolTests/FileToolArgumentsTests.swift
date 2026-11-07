import AeroCore
import Foundation
import Testing
@testable import BridgeProtocol

@Suite("File tool arguments and local paths")
final class FileToolArgumentsTests {
    let dir: String

    init() throws {
        var template = Array("/tmp/aero-f-XXXXXX".utf8CString)
        dir = try #require(mkdtemp(&template).map { String(cString: $0) })
        try Data("x".utf8).write(to: URL(filePath: dir + "/in.txt"))
    }

    deinit { try? FileManager.default.removeItem(atPath: dir) }

    func authorize(_ tool: String, _ arguments: [String: JSONValue]) throws(ToolArgumentError) -> String? {
        guard case .files(let call) = try ToolCall.parse(toolName: tool, arguments: arguments) else { return nil }
        return try LocalFileAccess.authorize(call, workingDirectory: dir)
    }

    func message(_ tool: String, _ arguments: [String: JSONValue]) -> String? {
        do {
            _ = try authorize(tool, arguments)
            return nil
        } catch {
            return error.message
        }
    }

    @Test func parsesWithDefaults() throws {
        #expect(try ToolCall.parse(toolName: "list_files", arguments: ["host": "web"]) ==
            .files(.list(ListFilesArguments(host: "web"))))
        #expect(try ToolCall.parse(toolName: "upload_file", arguments: ["host": "web", "localPath": "a", "remotePath": "/b"]) ==
            .files(.upload(UploadFileArguments(host: "web", localPath: "a", remotePath: "/b"))))
        #expect(message("list_files", ["host": "web", "path": ""]) == "Argument 'path' must not be empty.")
        #expect(message("upload_file", ["host": "web", "localPath": "a\nb", "remotePath": "b"]) != nil)
        #expect(message("download_file", ["host": "web", "remotePath": "b"]) == "Missing required argument 'localPath'.")
    }

    @Test func resolvesLocalPathsFromTheWorkingDirectory() throws {
        let canonical = try #require(realpath(dir, nil).map { String(cString: $0) })
        #expect(try authorize("upload_file", ["host": "web", "localPath": "in.txt", "remotePath": "b"]) == canonical + "/in.txt")
        #expect(try authorize("download_file", ["host": "web", "remotePath": "b", "localPath": "out.txt"]) == canonical + "/out.txt")
        #expect(try authorize("list_files", ["host": "web"]) == nil)
    }

    @Test func refusesUnusableLocalPaths() {
        #expect(message("upload_file", ["host": "web", "localPath": "missing", "remotePath": "b"])?.contains("No such file") == true)
        #expect(message("upload_file", ["host": "web", "localPath": ".", "remotePath": "b"])?.contains("not a regular file") == true)
        #expect(message("download_file", ["host": "web", "remotePath": "b", "localPath": "in.txt"])?.contains("already exists") == true)
        #expect(message("download_file", ["host": "web", "remotePath": "b", "localPath": "in.txt", "overwrite": true]) == nil)
        #expect(message("download_file", ["host": "web", "remotePath": "b", "localPath": "nope/out.txt"])?.contains("No such file") == true)
    }
}
