// Phase 0 spike: stdio MCP server on the official MCP Swift SDK (0.12.1).
// Throwaway.
//
// stdout carries JSON-RPC only; everything human-readable goes to stderr.

import Foundation
import MCP

@main
struct MCPPing {
    static func main() async throws {
        let bridge = FakeBridge()

        let server = Server(
            name: "aerospike",
            version: "0.0.1",
            instructions: "Phase 0 spike for AeroOps. Tools: ping, bridge_echo.",
            capabilities: .init(tools: .init(listChanged: false)),
            // --strict rejects everything before initialize, including Claude Code's server/discover probe.
            configuration: CommandLine.arguments.contains("--strict") ? .strict : .default
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Tools.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await Tools.call(params, bridge: bridge)
        }

        let transport: any Transport =
            CommandLine.arguments.contains("--blocking-stdio") ? BlockingStdioTransport() : StdioTransport()
        try await server.start(transport: transport) { client, _ in
            log("initialize from \(client.name) \(client.version)")
        }
        // Returns when stdin hits EOF (the client closed the pipe).
        await server.waitUntilCompleted()
        log("stdin closed, exiting")
    }
}

// MARK: - Tools

enum Tools {
    static let ping = Tool(
        name: "ping",
        title: "Ping",
        description: "Returns 'pong: <message> @ <ISO-8601 time>'. Use it to check the AeroOps MCP server is reachable.",
        inputSchema: [
            "type": "object",
            "properties": [
                "message": ["type": "string", "description": "Text to echo back. Optional."],
            ],
            "additionalProperties": false,
        ],
        annotations: .init(readOnlyHint: true, openWorldHint: false)
    )

    static let bridgeEcho = Tool(
        name: "bridge_echo",
        title: "Bridge echo",
        description: """
            Forwards the message to the (simulated) AeroOps app over the bridge and returns its reply. \
            Waits delayMs (default 200) to stand in for the socket round trip. \
            Set fail=true to get a tool-level error (isError).
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "message": ["type": "string", "description": "Text to send."],
                "delayMs": ["type": "integer", "minimum": 0, "maximum": 10_000, "description": "Simulated app latency."],
                "fail": ["type": "boolean", "description": "Simulate the app refusing the call."],
            ],
            "required": ["message"],
            "additionalProperties": false,
        ],
        annotations: .init(readOnlyHint: true, openWorldHint: false)
    )

    static let all = [ping, bridgeEcho]

    static func call(_ params: CallTool.Parameters, bridge: FakeBridge) async throws -> CallTool.Result {
        let args = params.arguments ?? [:]
        switch params.name {
        case ping.name:
            let message = args["message"]?.stringValue ?? ""
            return .init(content: [text("pong: \(message) @ \(Date.now.ISO8601Format())")], isError: false)

        case bridgeEcho.name:
            // Spec 2025-11-25: bad arguments are a tool execution error (isError) so the model can retry.
            guard let message = args["message"]?.stringValue else {
                return .init(content: [text("Missing required argument 'message' (string).")], isError: true)
            }
            let delayMs = min(max(args["delayMs"]?.intValue ?? 200, 0), 10_000)
            let fail = args["fail"]?.boolValue ?? false

            let started = ContinuousClock.now
            do {
                let reply = try await bridge.call(
                    tool: params.name, message: message, fail: fail, latency: .milliseconds(delayMs))
                let elapsed = ContinuousClock.now - started
                return .init(
                    content: [text("\(reply.text) (round trip \(elapsed.formatted(.units(allowed: [.milliseconds]))))")],
                    isError: !reply.ok
                )
            } catch is CancellationError {
                // Client sent notifications/cancelled. Rethrow: the SDK then sends no response, per spec.
                log("bridge_echo cancelled by client")
                throw CancellationError()
            } catch let error as FakeBridge.BridgeError {
                return .init(content: [text(error.description)], isError: true)
            }

        default:
            // Unknown tool is a protocol error (JSON-RPC -32602), not isError.
            throw MCPError.invalidParams("Unknown tool: \(params.name)")
        }
    }
}

// MARK: - Bridge stand-in

/// Stand-in for the real bridge client in `aeroops-mcp`: each call gets an id, the pending
/// continuation is parked in a dictionary, and a reader resolves it when the app's reply line
/// with that id arrives. Here the "app" is a Task that sleeps for `latency`.
actor FakeBridge {
    struct Reply: Sendable {
        let ok: Bool
        let text: String
    }

    enum BridgeError: Error, CustomStringConvertible {
        case appNotRunning
        var description: String {
            switch self {
            case .appNotRunning: "AeroOps is not running"
            }
        }
    }

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Reply, any Error>] = [:]

    func call(tool: String, message: String, fail: Bool, latency: Duration) async throws -> Reply {
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Runs synchronously on this actor (SE-0420 isolation inheritance).
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                log("bridge -> {\"id\":\(id),\"tool\":\"\(tool)\"}")
                // Simulated app: replies after `latency`.
                Task {
                    try? await Task.sleep(for: latency)
                    let reply =
                        fail
                        ? Reply(ok: false, text: "denied by app: \(message)")
                        : Reply(ok: true, text: "app echoed: \(message)")
                    self.resolve(id: id, with: .success(reply))
                }
            }
        } onCancel: {
            // Real client: also write {"id":id,"cancel":true} so the app stops work (e.g. kills ssh).
            Task { await self.resolve(id: id, with: .failure(CancellationError())) }
        }
    }

    private func resolve(id: Int, with result: Result<Reply, any Error>) {
        guard let continuation = pending.removeValue(forKey: id) else {
            log("bridge <- late reply for id \(id) dropped")
            return
        }
        log("bridge <- id \(id) \(result)")
        continuation.resume(with: result)
    }
}

// MARK: - Helpers

func text(_ string: String) -> Tool.Content {
    .text(text: string, annotations: nil, _meta: nil)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[mcp-ping] \(message)\n".utf8))
}
