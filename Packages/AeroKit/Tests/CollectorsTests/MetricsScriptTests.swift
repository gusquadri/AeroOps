import AeroCore
import AeroTestSupport
import Foundation
import Testing
@testable import Collectors

@Suite("Embedded metrics script")
struct MetricsScriptTests {
    @Test("RemoteScripts.metrics is byte-identical to Scripts/remote/metrics.sh")
    func matchesRepoScript() throws {
        let url = try Fixtures.repoRoot().appending(path: "Scripts/remote/metrics.sh")
        let onDisk = try Data(contentsOf: url)
        let embedded = Data(RemoteScripts.metrics.utf8)
        #expect(embedded == onDisk, "Re-embed Scripts/remote/metrics.sh in RemoteScripts+Metrics.swift")
    }

    @Test("Scripts run as LC_ALL=C sh -s with nothing interpolated")
    func shellCommand() {
        #expect(RemoteScripts.shellCommand == "LC_ALL=C sh -s")
        #expect(RemoteScripts.metrics.hasPrefix("#!/bin/sh"))
        #expect(RemoteScripts.metrics.hasSuffix("echo \"@@end\"\n"))
    }

    @Test("The monitor sends the script on stdin")
    func monitorSendsScript() async throws {
        let host = MonitorTestHosts.make(name: "script")
        let runner = MonitorTestRunner()
        runner.enqueue(.output(try Fixtures.string("metrics/devcontainer-1.txt")), for: host)
        let monitor = HostMonitor(host: host, runner: runner, clock: MonitorTestClock())
        await monitor.start()
        try await runner.waitForCalls(1)
        let call = try #require(runner.calls.first)
        #expect(call.command == RemoteScripts.shellCommand)
        #expect(call.stdin == Data(RemoteScripts.metrics.utf8))
        #expect(call.timeout == .seconds(8))
        #expect(call.hostID == host.id)
        await monitor.stop()
    }
}
