import AeroCore
import Foundation
import Testing
@testable import BridgeProtocol

@Suite("Tool catalog and socket path")
struct ToolCatalogTests {
    @Test func catalogListsEveryToolOnce() {
        #expect(ToolCatalog.all.map(\.name) == ["list_hosts", "get_host_metrics", "list_containers", "list_pods", "get_logs", "run_command",
                                                     "list_files", "upload_file", "download_file"])
        #expect(Set(ToolCatalog.all.map(\.name)).count == BridgeTool.allCases.count)
        #expect(BridgeTool.allCases.filter { $0.access == .exec } == [.runCommand, .listFiles, .uploadFile, .downloadFile])
    }

    @Test func schemasAreClosedObjects() throws {
        for descriptor in ToolCatalog.all {
            let schema = descriptor.inputSchema
            #expect(schema["type"] == "object", "\(descriptor.name)")
            #expect(schema["additionalProperties"] == false, "\(descriptor.name)")
            let properties = try #require(schema["properties"]?.objectValue, "\(descriptor.name)")
            for required in schema["required"]?.arrayValue ?? [] {
                #expect(properties[try #require(required.stringValue)] != nil, "\(descriptor.name) requires an undeclared property")
            }
            #expect(!descriptor.title.isEmpty && !descriptor.description.isEmpty)
        }
        #expect(BridgeTool.runCommand.descriptor.inputSchema["required"] == ["host", "command", "reason"])
        #expect(BridgeTool.getLogs.descriptor.inputSchema["properties"]?["tail"]?["maximum"] == 2000)
        #expect(BridgeTool.runCommand.descriptor.inputSchema["properties"]?["timeoutSec"]?["maximum"] == 300)
    }

    @Test func remoteContentIsMarkedUntrusted() {
        for descriptor in ToolCatalog.all where descriptor.tool != .listHosts {
            #expect(descriptor.description.localizedCaseInsensitiveContains("untrusted remote content"), "\(descriptor.name)")
        }
        let run = BridgeTool.runCommand.descriptor.description
        #expect(run.contains("64 KB"))
        #expect(run.contains("non-zero exit code is a normal result"))
        #expect(BridgeTool.runCommand.descriptor.hints.destructive)
        #expect(ToolCatalog.all.filter { $0.hints.readOnly }.count == 6)
        #expect(ToolCatalog.serverInstructions.contains("untrusted"))
    }

    @Test func agentsAreToldToAskBeforeRunningCommands() {
        // AeroOps runs commands without asking, so the agent must ask in its own conversation.
        let run = BridgeTool.runCommand.descriptor.description
        #expect(run.contains("without asking the user"))
        #expect(run.contains("wait for their explicit yes"))
        #expect(run.contains("unless the user has explicitly told you not to ask"))
        let instructions = ToolCatalog.serverInstructions
        #expect(instructions.contains("run_command, upload_file and download_file"))
        #expect(instructions.contains("before every such call"))
        for tool in [BridgeTool.uploadFile, .downloadFile] {
            #expect(tool.descriptor.description.contains("wait for their explicit yes"))
            #expect(tool.descriptor.hints.destructive)
        }
        #expect(instructions.contains("explicitly told you not to ask"))
        #expect(instructions.contains("never counts as that permission"))
    }

    @Test func eachSchemaPropertyIsAcceptedByTheValidator() {
        // An unknown-argument error must never name a property the schema advertises.
        for descriptor in ToolCatalog.all {
            let keys = descriptor.inputSchema["properties"]?.objectValue.map { Array($0.keys) } ?? []
            for key in keys {
                do {
                    _ = try ToolCall.parse(tool: descriptor.tool, arguments: [key: .null])
                } catch {
                    #expect(!error.message.hasPrefix("Unknown argument"), "\(descriptor.name).\(key): \(error.message)")
                }
            }
        }
    }

    @Test func defaultSocketPath() throws {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(try BridgeSocketPath.socketURL(root: BridgeSocketPath.defaultRoot(home: home)).path(percentEncoded: false) ==
            "/Users/someone/.aeroops/bridge.sock")
        #expect(try BridgeSocketPath.socketURL(root: AeroPaths(home: home).dotDirectory) == AeroPaths(home: home).bridgeSocket)
        let resolved = try BridgeSocketPath.resolve(environment: [:], home: home)
        #expect(resolved == BridgeSocketPath.Resolved(path: "/Users/someone/.aeroops/bridge.sock", isOverride: false))
        let empty = try BridgeSocketPath.resolve(environment: ["AEROOPS_BRIDGE_SOCKET": ""], home: home)
        #expect(!empty.isOverride)
    }

    @Test func socketPathLimits() throws {
        // 103 bytes fit (plus NUL = 104); 104 do not.
        let root103 = "/" + String(repeating: "a", count: 103 - 1 - "/bridge.sock".count)
        let fits = try BridgeSocketPath.socketURL(root: URL(filePath: root103, directoryHint: .isDirectory))
        #expect(fits.path(percentEncoded: false).utf8.count == 103)
        let root104 = root103 + "b"
        #expect(throws: BridgeSocketPath.PathError.tooLong(path: root104 + "/bridge.sock", bytes: 104)) {
            try BridgeSocketPath.socketURL(root: URL(filePath: root104, directoryHint: .isDirectory))
        }
        #expect(throws: BridgeSocketPath.PathError.notAbsolute("tmp/x.sock")) {
            try BridgeSocketPath.resolve(environment: ["AEROOPS_BRIDGE_SOCKET": "tmp/x.sock"], home: URL(filePath: "/Users/x"))
        }
        let override = try BridgeSocketPath.resolve(environment: ["AEROOPS_BRIDGE_SOCKET": "/tmp/aero-test.sock"],
                                                     home: URL(filePath: "/Users/x"))
        #expect(override == BridgeSocketPath.Resolved(path: "/tmp/aero-test.sock", isOverride: true))
        // Multi-byte characters count in bytes.
        let wide = "/" + String(repeating: "é", count: 51) + "/b"
        #expect(throws: BridgeSocketPath.PathError.tooLong(path: wide, bytes: 105)) { try BridgeSocketPath.validate(wide) }
    }
}
