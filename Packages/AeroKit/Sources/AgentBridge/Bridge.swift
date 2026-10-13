import AeroCore
import BridgeProtocol
import Foundation
import os

/// The app's MCP bridge: the socket server plus the request pipeline
///
/// ```text
/// socket → peer check → tool lookup → argument validation → host lookup → PolicyEngine
///        → BridgeToolHandler / CommandExecutor → reply
/// ```
///
/// AeroOps does not ask the user before `run_command`: the host's tier decides, and the agent
/// is told to confirm with the user in its own conversation. The CLI gets progress lines
/// ("Running on <host>"), which it forwards as MCP progress notifications.
///
/// ```swift
/// let bridge = Bridge(handler: AppBridgeHandler(store: hostStore, collectors: collectors))
/// try bridge.start()
/// for await activity in bridge.executor.activity() { activityTab.apply(activity) }
/// ```
public final class Bridge: Sendable {
    public let socketURL: URL
    public let executor: CommandExecutor
    private let pipeline: BridgePipeline
    private let server: BridgeServer

    /// - Parameters:
    ///   - socketURL: defaults to `~/.aeroops/bridge.sock`.
    ///   - handler: the app's data for the read tools.
    ///   - executor: runs `run_command` commands; defaults to SSHKit.
    ///   - peerValidator: defaults to ``CodeSignaturePeerValidator/forApp(allowUnsignedPeersInDebug:)``
    ///     (same team as the app; Release builds have no way around it).
    public init(
        socketURL: URL = AeroPaths.standard.bridgeSocket,
        handler: any BridgeToolHandler,
        executor: CommandExecutor = CommandExecutor(runner: SSHCommandRunner()),
        peerValidator: any BridgePeerValidator = CodeSignaturePeerValidator.forApp(),
        policy: PolicyEngine = PolicyEngine(),
        clock: any BridgeClock = SystemBridgeClock()
    ) {
        self.socketURL = socketURL
        self.executor = executor
        pipeline = BridgePipeline(handler: handler, executor: executor, policy: policy, clock: clock)
        server = BridgeServer(socketURL: socketURL, handler: pipeline, validator: peerValidator)
    }

    public var isRunning: Bool { server.isRunning }

    /// Connection events (connected peers, rejections, protocol errors).
    public func events() -> AsyncStream<BridgeServerEvent> {
        server.events()
    }

    /// Opens the socket. Throws ``BridgeServerError/alreadyRunning(_:)`` when another AeroOps
    /// serves it.
    public func start() throws(BridgeServerError) {
        try server.start()
    }

    /// Closes the socket and every connection. In-flight calls are cancelled and running
    /// commands are killed.
    public func stop() {
        server.stop()
    }

    /// Runs one request through the pipeline without a socket (tests, harness). Returns `nil`
    /// when the agent cancelled it.
    public func process(_ request: BridgeRequest, peer: BridgePeer,
                        progress: @escaping @Sendable (String) -> Void = { _ in }) async -> BridgeReply? {
        await pipeline.handle(request, from: peer, progress: progress)
    }
}

/// The request pipeline behind ``Bridge``.
struct BridgePipeline: BridgeRequestHandler {
    let handler: any BridgeToolHandler
    let executor: CommandExecutor
    let policy: PolicyEngine
    let clock: any BridgeClock

    private static let logger = Logger(subsystem: "app.aeroops", category: "bridge")

    func handle(_ request: BridgeRequest, from peer: BridgePeer,
                progress: @escaping @Sendable (String) -> Void) async -> BridgeReply? {
        // 1. Tool and arguments.
        guard let tool = BridgeTool(rawValue: request.tool) else {
            return refuse(request, BridgeError(code: .unknownTool, message: "Unknown tool \(String(reflecting: DisplayText.sanitized(request.tool, maxLength: 64)))."))
        }
        let call: ToolCall
        do {
            call = try ToolCall.parse(tool: tool, arguments: request.arguments)
        } catch {
            return refuse(request, BridgeError(code: .invalidArguments, message: error.message))
        }

        // 2. Host and policy.
        let states = await handler.hosts()
        var host: RemoteHost?
        if let query = call.hostQuery {
            switch HostResolver.resolve(query, in: states.map(\.host)) {
            case .success(let resolved):
                host = resolved
            case .failure(let failure):
                return refuse(request, failure.bridgeError)
            }
        }
        if let host, case .reject(let error) = policy.evaluate(tool: tool, host: host) {
            return refuse(request, error)
        }
        if Task.isCancelled { return nil }

        // 3. Run it.
        do {
            let reply: BridgeReply
            switch call {
            case .listHosts(let arguments):
                reply = ToolResults.reply(id: request.id, structured: ToolResults.hosts(states, tag: arguments.tag))
            case .getHostMetrics:
                let host = try requireHost(host)
                let metrics = try await handler.metrics(for: host)
                reply = ToolResults.reply(id: request.id, structured: ToolResults.metrics(metrics, host: host, now: clock.now))
            case .listContainers(let arguments):
                let host = try requireHost(host)
                let containers = try await handler.containers(on: host, includeStopped: arguments.all)
                reply = ToolResults.reply(id: request.id, structured: ToolResults.containers(containers, host: host))
            case .listPods(let arguments):
                let host = try requireHost(host)
                let pods = try await handler.pods(on: host, namespace: arguments.namespace)
                reply = ToolResults.reply(id: request.id, structured: ToolResults.pods(pods, host: host, now: clock.now))
            case .getLogs(let arguments):
                let host = try requireHost(host)
                let text = try await handler.logs(arguments.logRequest(hostId: host.id), on: host)
                reply = .success(id: request.id, content: [.text(ToolResults.logs(text, arguments: arguments, host: host))])
            case .runCommand(let arguments):
                let host = try requireHost(host)
                progress("Running on \(host.name)")
                let result = try await executor.execute(arguments.command, on: host, timeoutSeconds: arguments.timeoutSeconds)
                reply = ToolResults.reply(id: request.id, structured: ToolResults.command(result, host: host))
            }
            try Task.checkCancellation()
            return reply
        } catch {
            if error is CancellationError || Task.isCancelled { return nil }
            let bridgeError = Self.bridgeError(for: error, tool: tool)
            return .failure(id: request.id, bridgeError.code, bridgeError.message)
        }
    }

    private func refuse(_ request: BridgeRequest, _ error: BridgeError) -> BridgeReply {
        .failure(id: request.id, error.code, error.message)
    }

    private func requireHost(_ host: RemoteHost?) throws -> RemoteHost {
        guard let host else { throw BridgeError(code: .internalError, message: "The host was not resolved.") }
        return host
    }

    /// The agent-facing error for a failure while running a tool. Unexpected errors are logged
    /// here and reported generically, so remote output never leaks through error text.
    static func bridgeError(for error: any Error, tool: BridgeTool) -> BridgeError {
        switch error {
        case let error as BridgeError:
            return error
        case let error as BridgeHandlerError:
            return error.bridgeError
        case let error as CommandExecutionError:
            switch error {
            case .cancelledByUser: return BridgeError(code: .cancelled, message: error.description)
            case .timedOut: return BridgeError(code: .timedOut, message: error.description)
            case .sshFailed: return BridgeError(code: .sshFailed, message: error.description)
            }
        default:
            logger.error("Bridge \(tool.rawValue, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
            return BridgeError(code: .internalError, message: "AeroOps could not complete \(tool.rawValue).")
        }
    }
}
