import Foundation

/// Why a call through ``BridgeClient`` got no reply from the app.
public enum BridgeCallError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Nothing listens on the socket, and launching AeroOps did not help (or is off).
    case appNotRunning(detail: String?)
    /// The app closed the connection while the call was in flight.
    case appQuit
    /// The app refused the connection (an id-0 reply), e.g. the code-signature check.
    case refused(String)
    /// The socket could not be used, or the app sent something unreadable.
    case transport(String)

    public var description: String {
        switch self {
        case .appNotRunning(let detail):
            "AeroOps is not running. Open AeroOps and try again." + (detail.map { " (\($0))" } ?? "")
        case .appQuit:
            "AeroOps quit while handling the request."
        case .refused(let message):
            message
        case .transport(let message):
            "Could not talk to AeroOps: \(message)"
        }
    }
}

/// Where the CLI connects and whether it may start AeroOps.
public struct BridgeClientConfiguration: Sendable {
    /// Environment variable with the bundle identifier to `open` when nothing listens. Empty
    /// disables launching. Without it, launching is on (`app.aeroops.AeroOps`) for the default
    /// socket and off for an ``BridgeSocketPath/environmentVariable`` override, so tests and the
    /// dev harness never start an installed app.
    public static let launchEnvironmentVariable = "AEROOPS_APP_BUNDLE_ID"
    /// The app's bundle identifier.
    public static let appBundleIdentifier = "app.aeroops.AeroOps"

    /// Starts the app in the background; returns a failure message, or `nil` once it was asked
    /// to start.
    public typealias Launcher = @Sendable (_ bundleIdentifier: String) async -> String?

    public var socketPath: String
    /// The app to launch when nothing listens; `nil` never launches.
    public var launchBundleIdentifier: String?
    /// How often to retry the socket after a launch.
    public var retryInterval: Duration
    /// How long to wait for the socket after a launch.
    public var launchTimeout: Duration

    public init(socketPath: String, launchBundleIdentifier: String? = nil,
                retryInterval: Duration = .milliseconds(250), launchTimeout: Duration = .seconds(10)) {
        self.socketPath = socketPath
        self.launchBundleIdentifier = launchBundleIdentifier
        self.retryInterval = retryInterval
        self.launchTimeout = launchTimeout
    }

    /// The configuration for this process's environment (see ``launchEnvironmentVariable`` and
    /// ``BridgeSocketPath/environmentVariable``).
    public static func resolve(environment: [String: String], home: URL) throws(BridgeSocketPath.PathError) -> BridgeClientConfiguration {
        let socket = try BridgeSocketPath.resolve(environment: environment, home: home)
        let bundle: String? = switch environment[launchEnvironmentVariable] {
        case .some(let value): value.isEmpty ? nil : value
        case .none: socket.isOverride ? nil : appBundleIdentifier
        }
        return BridgeClientConfiguration(socketPath: socket.path, launchBundleIdentifier: bundle)
    }
}

/// The CLI side of `bridge.sock`.
///
/// - Connects lazily on the first call and reuses the connection; after the app quits, the next
///   call connects again.
/// - When nothing listens, asks the launcher to start AeroOps once and retries every
///   ``BridgeClientConfiguration/retryInterval`` up to ``BridgeClientConfiguration/launchTimeout``.
/// - Each call gets a fresh id; replies are matched by id, so calls run concurrently.
/// - Cancelling the calling task sends `{"id":…,"cancel":true}` (the app dismisses the approval
///   or kills the command) and throws `CancellationError`. A call cancelled before it was sent
///   is never sent.
public actor BridgeClient {
    private struct Pending {
        var continuation: CheckedContinuation<BridgeReply, any Error>
        var progress: @Sendable (String) -> Void
        var connection: ObjectIdentifier
    }

    public let configuration: BridgeClientConfiguration
    private let launcher: BridgeClientConfiguration.Launcher
    private let log: @Sendable (String) -> Void

    private var clientInfo: BridgeClientInfo?
    private var connection: BridgeSocketConnection?
    private var connecting: Task<BridgeSocketConnection, any Error>?
    private var pending: [Int: Pending] = [:]
    private var nextID = 1

    /// - Parameters:
    ///   - launcher: starts the app (the CLI runs `open -g -b`); only used when the configuration
    ///     names a bundle.
    ///   - log: diagnostics (the CLI sends them to stderr). Never gets request contents.
    public init(configuration: BridgeClientConfiguration,
                launcher: @escaping BridgeClientConfiguration.Launcher = { _ in "launching is not supported here" },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.launcher = launcher
        self.log = log
    }

    /// The MCP client from `initialize`, sent with every request.
    public func setClientInfo(_ info: BridgeClientInfo?) {
        clientInfo = info
    }

    /// Number of calls waiting for a reply.
    public var inFlightCount: Int { pending.count }

    /// Forwards one tool call and waits for the app's reply (which may itself be a failure).
    ///
    /// - Throws: ``BridgeCallError`` when there is no reply, `CancellationError` when the calling
    ///   task was cancelled.
    public func call(tool: String, arguments: [String: JSONValue], toolUseId: String? = nil,
                     progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> BridgeReply {
        let connection = try await connected()
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        let line: Data
        do {
            line = try BridgeWire.line(.request(BridgeRequest(id: id, tool: tool, arguments: arguments,
                                                              client: clientInfo, toolUseId: toolUseId)))
        } catch {
            throw BridgeCallError.transport("could not encode the request")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BridgeReply, any Error>) in
                // Runs synchronously on this actor, so no reply can arrive before `pending` is set.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard self.connection === connection else {
                    // It closed while this call waited for the connection.
                    continuation.resume(throwing: connection.endError)
                    return
                }
                pending[id] = Pending(continuation: continuation, progress: progress, connection: ObjectIdentifier(connection))
                do {
                    try connection.send(line)
                } catch {
                    // The app closed its end. The reader still has to report why (a refusal may
                    // be waiting in the buffer); its `closed` event fails this call.
                    connection.close()
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Closes the connection; calls in flight fail with ``BridgeCallError/appQuit``.
    public func close() {
        connection?.close()
    }

    // MARK: Connecting

    private func connected() async throws -> BridgeSocketConnection {
        if let connection { return connection }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.establish() }
        connecting = task
        defer { connecting = nil }
        let connection = try await task.value
        return connection
    }

    private func establish() async throws -> BridgeSocketConnection {
        let path = configuration.socketPath
        do {
            return adopt(try BridgeSocketConnection.connect(path: path))
        } catch .failed(let reason) {
            throw BridgeCallError.transport(reason)
        } catch .noListener(let reason) {
            guard let bundle = configuration.launchBundleIdentifier else {
                log("no app on \(path) (\(reason)); launching is off")
                throw BridgeCallError.appNotRunning(detail: nil)
            }
            log("no app on \(path) (\(reason)); launching \(bundle)")
            if let failure = await launcher(bundle) {
                log("could not launch \(bundle): \(failure)")
                throw BridgeCallError.appNotRunning(detail: "could not start it: \(failure)")
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.launchTimeout
        var lastReason = ""
        while clock.now < deadline {
            try await Task.sleep(for: configuration.retryInterval)
            do {
                let connection = try BridgeSocketConnection.connect(path: path)
                log("connected to \(path) after launching the app")
                return adopt(connection)
            } catch .failed(let reason) {
                throw BridgeCallError.transport(reason)
            } catch .noListener(let reason) {
                lastReason = reason
            }
        }
        log("app did not open \(path) within \(configuration.launchTimeout): \(lastReason)")
        let (seconds, attoseconds) = configuration.launchTimeout.components
        let limit = String(format: "%g", Double(seconds) + Double(attoseconds) / 1e18)
        throw BridgeCallError.appNotRunning(detail: "it did not start within \(limit) seconds")
    }

    private func adopt(_ connection: BridgeSocketConnection) -> BridgeSocketConnection {
        self.connection = connection
        let events = connection.events
        Task {
            for await event in events {
                self.receive(event, on: connection)
            }
        }
        return connection
    }

    // MARK: Replies

    private func receive(_ event: BridgeSocketConnection.Event, on source: BridgeSocketConnection) {
        switch event {
        case .message(.progress(let progress)):
            pending[progress.id]?.progress(progress.message)
        case .message(.reply(let reply)):
            if reply.id == BridgeReply.connectionErrorID {
                log("app refused the connection: \(reply.error?.message ?? BridgeSocketConnection.defaultRefusal)")
                failAll(on: source, with: source.endError)
                source.close()
            } else if let call = pending.removeValue(forKey: reply.id) {
                call.continuation.resume(returning: reply)
            }
        case .malformed(let id, let reason):
            log("unreadable line from the app: \(reason)")
            if let id, let call = pending.removeValue(forKey: id) {
                call.continuation.resume(throwing: BridgeCallError.transport("AeroOps sent an unreadable reply"))
            }
        case .oversized(let bytes):
            log("reply line over \(BridgeLimits.maxReplyLineBytes) bytes (\(bytes)); dropping the connection")
            failAll(on: source, with: .transport("AeroOps sent a reply that is too large"))
            source.close()
        case .closed(let failure):
            if let failure { log("connection to \(source.path) failed: \(failure)") }
            failAll(on: source, with: source.endError)
            if connection === source { connection = nil }
        }
    }

    private func failAll(on source: BridgeSocketConnection, with error: BridgeCallError) {
        let id = ObjectIdentifier(source)
        for (key, call) in pending where call.connection == id {
            pending[key] = nil
            call.continuation.resume(throwing: error)
        }
    }

    private func cancel(_ id: Int) {
        guard let call = pending.removeValue(forKey: id) else { return }
        if let connection, ObjectIdentifier(connection) == call.connection,
           let line = try? BridgeWire.line(.cancel(id: id)) {
            try? connection.send(line)
        }
        call.continuation.resume(throwing: CancellationError())
    }
}
