import BridgeProtocol
import Foundation
import Logging
import MCP

/// Serves the MCP tool methods.
///
/// Error mapping: an unknown tool is a JSON-RPC error
/// (`-32602`); everything else that goes wrong (bad arguments, Off or Read host, timeout, ssh,
/// app not running) is a normal result with `isError: true`, so the model can read the reason.
/// A cancelled call throws `CancellationError`, and the SDK sends no response.
struct ToolForwarder: Sendable {
    /// The bridge client, or why there is none (an unusable socket path).
    let bridge: Result<BridgeClient, BridgeSocketPath.PathError>
    let server: Server
    let logger: Logger

    /// The catalog as MCP tools. Needs no app.
    static let tools: [Tool] = ToolCatalog.all.map { descriptor in
        Tool(
            name: descriptor.name,
            title: descriptor.title,
            description: descriptor.description,
            inputSchema: MCP.Value(bridging: descriptor.inputSchema),
            annotations: .init(
                title: descriptor.title,
                readOnlyHint: descriptor.hints.readOnly,
                destructiveHint: descriptor.hints.destructive,
                idempotentHint: descriptor.hints.idempotent,
                openWorldHint: descriptor.hints.openWorld))
    }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let tool = BridgeTool(rawValue: params.name) else {
            throw MCPError.invalidParams("Unknown tool \(String(reflecting: String(params.name.prefix(64)))). Call tools/list for the available tools.")
        }
        let arguments: [String: JSONValue]
        do {
            arguments = try Self.validated(tool, (params.arguments ?? [:]).mapValues(JSONValue.init(bridging:)))
        } catch {
            return Self.failure(error.message)
        }
        switch bridge {
        case .success(let client):
            return try result(await forward(tool, arguments, params, client), tool: tool)
        case .failure(let error):
            return Self.failure("AeroOps is not reachable: \(error.description)")
        }
    }

    static func validated(_ tool: BridgeTool, _ arguments: [String: JSONValue]) throws(ToolArgumentError) -> [String: JSONValue] {
        guard case .files(let call) = try ToolCall.parse(tool: tool, arguments: arguments),
              let localPath = try LocalFileAccess.authorize(call, workingDirectory: FileManager.default.currentDirectoryPath)
        else { return arguments }
        var resolved = arguments
        resolved["localPath"] = .string(localPath)
        return resolved
    }

    private func forward(_ tool: BridgeTool, _ arguments: [String: JSONValue], _ params: CallTool.Parameters,
                         _ client: BridgeClient) async -> Result<BridgeReply, any Error> {
        let token = params._meta?.progressToken
        let (updates, sink) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let server = self.server
        let logger = self.logger
        let forwarding = Task {
            var step = 0.0
            for await message in updates {
                logger.debug("progress: \(message)")
                guard let token else { continue }
                step += 1
                try? await server.notify(ProgressNotification.message(
                    .init(progressToken: token, progress: step, message: message)))
            }
        }
        let outcome: Result<BridgeReply, any Error>
        do {
            outcome = .success(try await client.call(
                tool: tool.rawValue, arguments: arguments,
                toolUseId: params._meta?["claudecode/toolUseId"]?.stringValue,
                progress: { sink.yield($0) }))
        } catch {
            outcome = .failure(error)
        }
        sink.finish()
        await forwarding.value
        return outcome
    }

    private func result(_ outcome: Result<BridgeReply, any Error>, tool: BridgeTool) throws -> CallTool.Result {
        switch outcome {
        case .success(let reply):
            return try result(reply, tool: tool)
        case .failure(let error) where error is CancellationError:
            logger.info("\(tool.rawValue) cancelled by the client")
            throw CancellationError()
        case .failure(let error as BridgeCallError):
            logger.notice("\(tool.rawValue): \(error.description)")
            return Self.failure(error.description)
        case .failure(let error):
            logger.error("\(tool.rawValue): unexpected \(String(describing: type(of: error)))")
            return Self.failure("Could not talk to AeroOps.")
        }
    }

    private func result(_ reply: BridgeReply, tool: BridgeTool) throws -> CallTool.Result {
        guard !reply.ok else {
            return CallTool.Result(
                content: (reply.content ?? []).map { .text(text: $0.text, annotations: nil, _meta: nil) },
                structuredContent: reply.structuredContent.map(MCP.Value.init(bridging:)),
                isError: false)
        }
        let error = reply.error ?? BridgeError(code: .internalError, message: "AeroOps could not complete \(tool.rawValue).")
        if error.code == .unknownTool { throw MCPError.invalidParams(error.message) }
        logger.info("\(tool.rawValue) failed in the app: \(error.code)")
        return Self.failure(error.message)
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

extension JSONValue {
    /// The bridge form of an SDK value. The SDK turns strings that look like data URLs into
    /// `.data`; they go back to the same data URL text.
    init(bridging value: MCP.Value) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .int(int)
        case .double(let double): self = .double(double)
        case .string(let string): self = .string(string)
        case .data(let mimeType, let data): self = .string(data.dataURLEncoded(mimeType: mimeType))
        case .array(let array): self = .array(array.map(JSONValue.init(bridging:)))
        case .object(let object): self = .object(object.mapValues(JSONValue.init(bridging:)))
        }
    }
}

extension MCP.Value {
    /// The SDK form of a bridge value.
    init(bridging value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .int(int)
        case .double(let double): self = .double(double)
        case .string(let string): self = .string(string)
        case .array(let array): self = .array(array.map(MCP.Value.init(bridging:)))
        case .object(let object): self = .object(object.mapValues(MCP.Value.init(bridging:)))
        }
    }
}
