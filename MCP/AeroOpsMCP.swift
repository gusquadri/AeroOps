// aeroops-mcp: the stdio MCP server bundled at AeroOps.app/Contents/MacOS/aeroops-mcp.
//
// It serves the static tool catalog itself and forwards every tool call to the running app over
// ~/.aeroops/bridge.sock. The app does all the work and all the
// checks: peer signature and host policy. stdout carries JSON-RPC only; logs go
// to stderr.
//
// Environment:
//   AEROOPS_BRIDGE_SOCKET   Connect to this socket instead of ~/.aeroops/bridge.sock (tests and
//                           the dev harness). The app still checks this process's signature.
//   AEROOPS_APP_BUNDLE_ID   App to start with `open -g -b` when nothing listens. Empty: never
//                           start anything. Default: app.aeroops.AeroOps, but nothing when
//                           AEROOPS_BRIDGE_SOCKET is set.
//   AEROOPS_MCP_LOG         stderr log level: trace, debug, info, notice (default), warning, error.

import BridgeProtocol
import Darwin
import Foundation
import Logging
import MCP

@main
enum AeroOpsMCP {
    static let usage = """
        usage: aeroops-mcp [--help | --version]

        Stdio MCP server for AeroOps. It forwards tool calls to the AeroOps app, which must be
        running (it is started in the background when needed). Register it with an MCP client:

          claude mcp add --scope user aeroops -- /Applications/AeroOps.app/Contents/MacOS/aeroops-mcp

        Environment:
          AEROOPS_BRIDGE_SOCKET   use this socket instead of ~/.aeroops/bridge.sock
          AEROOPS_APP_BUNDLE_ID   app to start when it is not running; empty disables starting
                                  (default app.aeroops.AeroOps; off when AEROOPS_BRIDGE_SOCKET is set)
          AEROOPS_MCP_LOG         stderr log level (default notice)
        """

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func main() async {
        // A closed stdout or socket must surface as EPIPE, not kill the process.
        signal(SIGPIPE, SIG_IGN)

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }
        if arguments.contains("--version") {
            print("aeroops-mcp \(version)")
            return
        }
        if let unknown = arguments.first {
            FileHandle.standardError.write(Data("aeroops-mcp: unknown argument \(unknown)\n\n\(usage)\n".utf8))
            exit(64)
        }

        let environment = ProcessInfo.processInfo.environment
        let level = environment["AEROOPS_MCP_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .notice
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
        let logger = Logger(label: "aeroops-mcp")

        let bridge: Result<BridgeClient, BridgeSocketPath.PathError>
        do {
            let configuration = try BridgeClientConfiguration.resolve(environment: environment, home: homeDirectory())
            logger.info("bridge socket \(configuration.socketPath), launch \(configuration.launchBundleIdentifier ?? "off")")
            bridge = .success(BridgeClient(configuration: configuration, launcher: AppLauncher.open,
                                           log: { logger.notice("\($0)") }))
        } catch {
            logger.error("\(error.description)")
            bridge = .failure(error)
        }

        let server = Server(
            name: "aeroops",
            version: version,
            title: "AeroOps",
            instructions: ToolCatalog.serverInstructions,
            capabilities: .init(tools: .init(listChanged: false)),
            // Not strict: strict mode leaves Claude Code's server/discover probe unanswered.
            configuration: .default)
        let forwarder = ToolForwarder(bridge: bridge, server: server, logger: logger)
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolForwarder.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await forwarder.call(params)
        }

        let transport = StdioLineTransport(logger: logger)
        do {
            try await server.start(transport: transport) { client, _ in
                logger.info("initialize from \(client.name) \(client.version)")
                if case .success(let bridge) = bridge {
                    await bridge.setClientInfo(BridgeClientInfo(name: client.name, version: client.version))
                }
            }
        } catch {
            logger.critical("could not start: \(error)")
            exit(1)
        }
        // Returns when stdin hits EOF (the client closed the pipe). Requests read before that
        // still get their responses for a short while (a piped script reads them); then closing
        // the bridge connection makes the app cancel whatever this session still had in flight,
        // such as a running command nobody would see the result of.
        await server.waitUntilCompleted()
        let unanswered = await transport.drain(timeout: .seconds(2))
        if case .success(let bridge) = bridge { await bridge.close() }
        if unanswered > 0 {
            logger.notice("stdin closed, exiting with \(unanswered) request(s) unanswered")
        } else {
            logger.info("stdin closed, exiting")
        }
    }

    /// The user's home from the password database, not `$HOME`, like the app's paths.
    static func homeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Starts AeroOps in the background with `open -g -b <bundle id>`.
enum AppLauncher {
    /// Returns `nil` when `open` succeeded, else its error output.
    @Sendable static func open(_ bundleIdentifier: String) async -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-g", "-b", bundleIdentifier]
        // Never inherit stdout: it carries JSON-RPC.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
        guard status != 0 else { return nil }
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "open exited with status \(status)" : output
    }
}
