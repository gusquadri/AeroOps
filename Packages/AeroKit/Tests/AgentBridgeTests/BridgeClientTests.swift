import BridgeProtocol
import Darwin
import Foundation
import Synchronization
import Testing
@testable import AgentBridge

/// `aeroops-mcp`'s side of the socket (BridgeProtocol's ``BridgeClient``) against the real server.
@Suite("Bridge client (CLI side)")
struct BridgeClientTests {
    /// A server on `<temp>/bridge.sock`, started or not.
    final class Fixture: Sendable {
        let dir: TempDirectory
        let handler = ScriptedRequestHandler()
        let server: BridgeServer

        init(validator: any BridgePeerValidator = AcceptAllPeers(), start: Bool = true) throws {
            dir = try TempDirectory()
            server = BridgeServer(socketURL: dir.appending("bridge.sock"), handler: handler, validator: validator)
            if start { try server.start() }
        }

        var path: String { server.socketURL.path(percentEncoded: false) }

        func client(launch bundle: String? = nil, launcher: @escaping BridgeClientConfiguration.Launcher = { _ in "no launcher" },
                    timeout: Duration = .seconds(2)) -> BridgeClient {
            BridgeClient(configuration: BridgeClientConfiguration(socketPath: path, launchBundleIdentifier: bundle,
                                                                  retryInterval: .milliseconds(50), launchTimeout: timeout),
                         launcher: launcher)
        }

        deinit {
            server.stop()
            dir.remove()
        }
    }

    /// Counts launcher calls.
    final class LaunchRecorder: Sendable {
        private let calls = Mutex<[String]>([])
        var bundles: [String] { calls.withLock { $0 } }
        func record(_ bundle: String) { calls.withLock { $0.append(bundle) } }
    }

    @Test func roundTripWithClientInfoAndToolUseId() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        let echo = try await client.call(tool: "echo", arguments: ["text": "hi"])
        #expect(echo.ok && echo.text == "hi")
        await client.setClientInfo(BridgeClientInfo(name: "claude-code", version: "2.1.296"))
        let who = try await client.call(tool: "whoami", arguments: [:], toolUseId: "toolu_42")
        #expect(who.text == "claude-code 2.1.296 toolu_42")
        let unknown = try await client.call(tool: "nope", arguments: [:])
        #expect(!unknown.ok && unknown.error?.code == .unknownTool)
        #expect(fixture.handler.started == [1, 2, 3], "ids start at 1 and go up")
        #expect(await client.inFlightCount == 0)
    }

    @Test func concurrentCallsAndProgress() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        let progress = Mutex<[String]>([])
        async let slow = client.call(tool: "sleep", arguments: ["ms": 300])
        async let fast = client.call(tool: "echo", arguments: ["text": "fast"])
        let waiting = Task { try await client.call(tool: "wait", arguments: [:]) { line in progress.withLock { $0.append(line) } } }
        #expect(try await fast.text == "fast")
        #expect(try await slow.text == "slept")
        #expect(await eventually { progress.withLock { $0 } == ["waiting"] })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func cancelSendsACancelLineAndKeepsTheConnection() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        let call = Task { try await client.call(tool: "wait", arguments: [:]) }
        #expect(await eventually { fixture.handler.started == [1] })
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(await eventually { fixture.handler.cancelled == [1] }, "the app stopped working on it")
        #expect(await client.inFlightCount == 0)
        #expect(try await client.call(tool: "echo", arguments: ["text": "again"]).text == "again")
        #expect(fixture.server.connectionCount == 1, "same connection")
    }

    @Test func callCancelledBeforeItIsSentIsNeverSent() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        _ = try await client.call(tool: "echo", arguments: ["text": "connect first"])
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.call(tool: "echo", arguments: ["text": "too late"])
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.handler.started == [1])
    }

    @Test func appQuitFailsCallsInFlightAndTheNextCallReconnects() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        let call = Task { try await client.call(tool: "wait", arguments: [:]) }
        #expect(await eventually { fixture.handler.started == [1] })
        fixture.server.stop()
        await #expect(throws: BridgeCallError.appQuit) { try await call.value }
        #expect(BridgeCallError.appQuit.description == "AeroOps quit while handling the request.")

        await #expect(throws: BridgeCallError.appNotRunning(detail: nil)) {
            try await client.call(tool: "echo", arguments: ["text": "anyone?"])
        }
        try fixture.server.start()
        #expect(try await client.call(tool: "echo", arguments: ["text": "back"]).text == "back")
    }

    @Test func notRunningWithoutLaunchingNeverCallsTheLauncher() async throws {
        let fixture = try Fixture(start: false)
        let launches = LaunchRecorder()
        let client = fixture.client(launch: nil) { bundle in
            launches.record(bundle)
            return nil
        }
        let start = ContinuousClock.now
        do {
            _ = try await client.call(tool: "echo", arguments: [:])
            Issue.record("expected appNotRunning")
        } catch let error as BridgeCallError {
            #expect(error == .appNotRunning(detail: nil))
            #expect(error.description.hasPrefix("AeroOps is not running"))
        }
        #expect(ContinuousClock.now - start < .seconds(1), "no retry loop without a launch")
        #expect(launches.bundles.isEmpty)
    }

    @Test func failedLaunchIsReportedAtOnce() async throws {
        let fixture = try Fixture(start: false)
        let launches = LaunchRecorder()
        let client = fixture.client(launch: "app.aeroops.Missing") { bundle in
            launches.record(bundle)
            return "Unable to find application with identifier \(bundle)"
        }
        do {
            _ = try await client.call(tool: "echo", arguments: [:])
            Issue.record("expected appNotRunning")
        } catch let error as BridgeCallError {
            #expect(error.description == "AeroOps is not running. Open AeroOps and try again. (could not start it: Unable to find application with identifier app.aeroops.Missing)")
        }
        #expect(launches.bundles == ["app.aeroops.Missing"])
    }

    @Test func launchThenRetryUntilTheSocketAppears() async throws {
        let fixture = try Fixture(start: false)
        let launches = LaunchRecorder()
        let server = fixture.server
        let client = fixture.client(launch: "app.aeroops.AeroOps") { bundle in
            launches.record(bundle)
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                try? server.start()
            }
            return nil
        }
        async let first = client.call(tool: "echo", arguments: ["text": "one"])
        async let second = client.call(tool: "echo", arguments: ["text": "two"])
        #expect(try await first.text == "one")
        #expect(try await second.text == "two")
        #expect(launches.bundles == ["app.aeroops.AeroOps"], "concurrent calls share one launch")
    }

    @Test func launchedAppThatNeverListensTimesOut() async throws {
        let fixture = try Fixture(start: false)
        let client = fixture.client(launch: "app.aeroops.AeroOps", launcher: { _ in nil }, timeout: .milliseconds(400))
        let start = ContinuousClock.now
        await #expect(throws: BridgeCallError.appNotRunning(detail: "it did not start within 0.4 seconds")) {
            try await client.call(tool: "echo", arguments: [:])
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(400) && elapsed < .seconds(2))
    }

    @Test func refusedPeerGetsTheAppsMessage() async throws {
        let fixture = try Fixture(validator: RejectAllPeers())
        try await withThrowingTaskGroup { group in
            for _ in 0..<20 {
                let client = fixture.client()
                group.addTask {
                    await #expect(throws: BridgeCallError.refused("AeroOps refused the connection: test says no.")) {
                        try await client.call(tool: "echo", arguments: [:])
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(fixture.handler.started.isEmpty)
    }

    @Test func socketThatIsNotASocketIsATransportError() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let file = dir.appending("bridge.sock")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data())
        let client = BridgeClient(configuration: BridgeClientConfiguration(socketPath: file.path(percentEncoded: false),
                                                                           launchBundleIdentifier: "app.aeroops.AeroOps"),
                                  launcher: { _ in Issue.record("must not launch"); return nil })
        do {
            _ = try await client.call(tool: "echo", arguments: [:])
            Issue.record("expected a transport error")
        } catch let error as BridgeCallError {
            guard case .transport = error else {
                Issue.record("expected a transport error, got \(error)")
                return
            }
        }
    }

    @Test func configurationFromTheEnvironment() throws {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let standard = try BridgeClientConfiguration.resolve(environment: [:], home: home)
        #expect(standard.socketPath == "/Users/someone/.aeroops/bridge.sock")
        #expect(standard.launchBundleIdentifier == "app.aeroops.AeroOps")

        let override = try BridgeClientConfiguration.resolve(environment: ["AEROOPS_BRIDGE_SOCKET": "/tmp/x/bridge.sock"], home: home)
        #expect(override.socketPath == "/tmp/x/bridge.sock")
        #expect(override.launchBundleIdentifier == nil, "an override never launches the installed app")

        let explicit = try BridgeClientConfiguration.resolve(
            environment: ["AEROOPS_BRIDGE_SOCKET": "/tmp/x/bridge.sock", "AEROOPS_APP_BUNDLE_ID": "app.aeroops.Dev"], home: home)
        #expect(explicit.launchBundleIdentifier == "app.aeroops.Dev")

        let disabled = try BridgeClientConfiguration.resolve(environment: ["AEROOPS_APP_BUNDLE_ID": ""], home: home)
        #expect(disabled.socketPath == "/Users/someone/.aeroops/bridge.sock")
        #expect(disabled.launchBundleIdentifier == nil)

        #expect(throws: BridgeSocketPath.PathError.notAbsolute("bridge.sock")) {
            try BridgeClientConfiguration.resolve(environment: ["AEROOPS_BRIDGE_SOCKET": "bridge.sock"], home: home)
        }
    }
}
