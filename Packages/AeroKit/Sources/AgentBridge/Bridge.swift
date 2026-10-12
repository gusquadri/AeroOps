import AeroCore
import BridgeProtocol
import Foundation
import os

/// The app's MCP bridge: the socket server plus the request pipeline
///
/// ```text
/// socket → peer check → tool lookup → argument validation → host lookup → PolicyEngine
///        → ApprovalCenter (run_command) → BridgeToolHandler / CommandExecutor → AuditLog → reply
/// ```
///
/// Every call is audited, including invalid and refused ones. While an approval is pending the
/// CLI gets progress lines ("Waiting for approval in AeroOps"), which it forwards as MCP
/// progress notifications.
///
/// ```swift
/// let bridge = Bridge(handler: AppBridgeHandler(store: hostStore, collectors: collectors))
/// try bridge.start()
/// for await snapshot in await bridge.approvals.updates() { panel.show(snapshot.pending) }
/// ```
public final class Bridge: Sendable {
    public let socketURL: URL
    public let approvals: ApprovalCenter
    public let audit: AuditLog
    public let executor: CommandExecutor
    private let pipeline: BridgePipeline
    private let server: BridgeServer

    /// - Parameters:
    ///   - socketURL: defaults to `~/.aeroops/bridge.sock`.
    ///   - handler: the app's data for the read tools.
    ///   - executor: runs approved commands; defaults to SSHKit.
    ///   - peerValidator: defaults to ``CodeSignaturePeerValidator/forApp(allowUnsignedPeersInDebug:)``
    ///     (same team as the app; Release builds have no way around it).
    ///   - progressInterval: how often a pending approval repeats its progress line.
    public init(
        socketURL: URL = AeroPaths.standard.bridgeSocket,
        handler: any BridgeToolHandler,
        executor: CommandExecutor = CommandExecutor(runner: SSHCommandRunner()),
        approvals: ApprovalCenter = ApprovalCenter(),
        audit: AuditLog = AuditLog(),
        peerValidator: any BridgePeerValidator = CodeSignaturePeerValidator.forApp(),
        policy: PolicyEngine = PolicyEngine(),
        clock: any BridgeClock = SystemBridgeClock(),
        progressInterval: Duration = .seconds(5)
    ) {
        self.socketURL = socketURL
        self.approvals = approvals
        self.audit = audit
        self.executor = executor
        pipeline = BridgePipeline(handler: handler, executor: executor, approvals: approvals, audit: audit,
                                  policy: policy, clock: clock, progressInterval: progressInterval)
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

    /// Closes the socket and every connection. In-flight calls are cancelled: pending approvals
    /// disappear and running commands are killed.
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
    let approvals: ApprovalCenter
    let audit: AuditLog
    let policy: PolicyEngine
    let clock: any BridgeClock
    let progressInterval: Duration

    private static let logger = Logger(subsystem: "app.aeroops", category: "bridge")

    /// The audit facts gathered while a call goes through the pipeline.
    private struct Record {
        let request: BridgeRequest
        let started = ContinuousClock.now
        let time: Date
        var host: String?
        var hostId: UUID?
        var decision: AuditDecision = .allowed

        init(request: BridgeRequest, time: Date) {
            self.request = request
            self.time = time
            host = request.arguments["host"]?.stringValue.map { DisplayText.sanitized($0, maxLength: 256) }
        }

        func entry(_ outcome: AuditOutcome, error: BridgeErrorCode? = nil, exitCode: Int32? = nil, reply: BridgeReply? = nil) -> AuditEntry {
            AuditEntry(
                time: time,
                client: request.client.map { DisplayText.sanitized($0.displayName, maxLength: 100) },
                toolUseId: request.toolUseId.map { DisplayText.sanitized($0, maxLength: 128) },
                tool: DisplayText.sanitized(request.tool, maxLength: 64),
                host: host,
                hostId: hostId,
                arguments: request.arguments,
                decision: decision,
                outcome: outcome,
                error: error?.rawValue,
                exitCode: exitCode,
                durationMs: max(0, (ContinuousClock.now - started).milliseconds),
                outputBytes: reply.map { reply in (reply.content ?? []).reduce(0) { $0 + $1.text.utf8.count } })
        }
    }

    func handle(_ request: BridgeRequest, from peer: BridgePeer,
                progress: @escaping @Sendable (String) -> Void) async -> BridgeReply? {
        var record = Record(request: request, time: clock.now)

        // 1. Tool and arguments.
        guard let tool = BridgeTool(rawValue: request.tool) else {
            record.decision = .invalid
            return await refuse(record, BridgeError(code: .unknownTool, message: "Unknown tool \(String(reflecting: DisplayText.sanitized(request.tool, maxLength: 64)))."))
        }
        let call: ToolCall
        do {
            call = try ToolCall.parse(tool: tool, arguments: request.arguments)
        } catch {
            record.decision = .invalid
            return await refuse(record, BridgeError(code: .invalidArguments, message: error.message))
        }

        // 2. Host and policy.
        let states = await handler.hosts()
        var host: RemoteHost?
        if let query = call.hostQuery {
            switch HostResolver.resolve(query, in: states.map(\.host)) {
            case .success(let resolved):
                host = resolved
                record.host = resolved.name
                record.hostId = resolved.id
            case .failure(let failure):
                record.decision = .rejected
                return await refuse(record, failure.bridgeError)
            }
        }
        if let host {
            switch policy.evaluate(tool: tool, host: host, command: call.command) {
            case .allow:
                record.decision = .allowed
            case .reject(let error):
                record.decision = .rejected
                return await refuse(record, error)
            case .requireApproval(let alwaysAsk):
                guard case .runCommand(let arguments) = call else {
                    record.decision = .rejected
                    return await refuse(record, BridgeError(code: .internalError, message: "Only run_command can be approved."))
                }
                let ask = ApprovalAsk(client: request.client, host: host, command: arguments.command, reason: arguments.reason,
                                      alwaysAskReasons: alwaysAsk, toolUseId: request.toolUseId)
                let outcome = await waitForApproval(ask, progress: progress)
                switch outcome {
                case .allowedOnce: record.decision = .approvedOnce
                case .allowedHost: record.decision = .approvedHostWindow
                case .allowedByWindow: record.decision = .allowedByWindow
                case .denied:
                    record.decision = .denied
                    return await refuse(record, BridgeError(code: .denied, message: "The user denied this command in AeroOps. Do not retry it unchanged."))
                case .timedOut:
                    record.decision = .approvalTimedOut
                    return await refuse(record, BridgeError(
                        code: .approvalTimedOut,
                        message: "Nobody approved the command in AeroOps within \(Int(approvals.timeout.timeInterval)) seconds, so it was denied."))
                case .cancelled:
                    record.decision = .cancelled
                    await audit.record(record.entry(.cancelledByAgent))
                    return nil
                }
            }
        }
        if Task.isCancelled {
            await audit.record(record.entry(.cancelledByAgent))
            return nil
        }

        // 3. Run it.
        do {
            let reply: BridgeReply
            var exitCode: Int32?
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
                exitCode = result.exitCode
                reply = ToolResults.reply(id: request.id, structured: ToolResults.command(result, host: host))
            }
            try Task.checkCancellation()
            await audit.record(record.entry(.succeeded, exitCode: exitCode, reply: reply))
            return reply
        } catch {
            if error is CancellationError || Task.isCancelled {
                await audit.record(record.entry(.cancelledByAgent))
                return nil
            }
            let bridgeError = Self.bridgeError(for: error, tool: tool)
            let outcome: AuditOutcome = if case CommandExecutionError.cancelledByUser = error { .cancelledByUser } else { .failed }
            await audit.record(record.entry(outcome, error: bridgeError.code))
            return .failure(id: request.id, bridgeError.code, bridgeError.message)
        }
    }

    /// Asks through the ``ApprovalCenter``, sending a progress line now and then while it waits.
    private func waitForApproval(_ ask: ApprovalAsk, progress: @escaping @Sendable (String) -> Void) async -> ApprovalOutcome {
        let interval = progressInterval
        let deadline = ContinuousClock.now + approvals.timeout
        progress("Waiting for approval in AeroOps")
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                let left = max(0, Int((deadline - ContinuousClock.now).timeInterval.rounded()))
                progress("Waiting for approval in AeroOps (\(left) s left)")
            }
        }
        let outcome = await approvals.authorize(ask)
        // Cancelling alone is not enough: a heartbeat whose sleep had already ended could still
        // send a stale "Waiting for approval" line after the caller's next progress line
        // ("Running on <host>"), which happened under load. Wait until it has stopped.
        heartbeat.cancel()
        await heartbeat.value
        return outcome
    }

    private func refuse(_ record: Record, _ error: BridgeError) async -> BridgeReply {
        await audit.record(record.entry(.notRun, error: error.code))
        return .failure(id: record.request.id, error.code, error.message)
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

extension ToolCall {
    /// The `run_command` command, if any.
    var command: String? {
        if case .runCommand(let arguments) = self { return arguments.command }
        return nil
    }
}
