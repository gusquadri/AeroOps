import AeroCore
import AeroTestSupport
import Foundation
import SSHKit
import Synchronization
import Testing
@testable import Collectors

@Suite("Probe script")
struct ProbeScriptTests {
    @Test("Embedded probe.sh is byte-identical to Scripts/remote/probe.sh")
    func byteIdentity() throws {
        let url = try Fixtures.repoRoot().appending(path: "Scripts/remote/probe.sh")
        let onDisk = try Data(contentsOf: url)
        #expect(Data(RemoteScripts.probe.utf8) == onDisk, "Re-embed Scripts/remote/probe.sh in RemoteScripts+Probe.swift")
    }

    @Test("Runs as LC_ALL=C sh -s with the script on stdin")
    func command() {
        #expect(RemoteScripts.shellCommand == "LC_ALL=C sh -s")
    }

    @Test("Embedded script passes sh -n")
    func syntax() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-n", "-c", RemoteScripts.probe]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

@Suite("CapabilityCache")
struct ProbeCapabilityCacheTests {
    @Test("Probes once, sends probe.sh on stdin, parses the tokens")
    func probesOnce() async throws {
        let output = try Fixtures.string("probe/vm-dev.txt")
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(output))
        let cache = CapabilityCache(runner: runner)
        let host = ProbeTestData.host()

        #expect(await cache.cached(for: host) == nil)
        let first = try await cache.capabilities(for: host)
        let second = try await cache.capabilities(for: host)

        #expect(first == second)
        #expect(first.contains([.docker, .kubectl, .k3s, .dockerOK]))
        #expect(!first.contains(.kubeOK))
        #expect(first.suggestedKubectlPrefix == "sudo -n k3s kubectl")
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.command == "LC_ALL=C sh -s")
        #expect(runner.calls.first?.stdin == Data(RemoteScripts.probe.utf8))
        #expect(runner.calls.first?.hostID == host.id)
        #expect(await cache.cached(for: host) == first)
    }

    @Test("refresh probes again and replaces the cached value")
    func refresh() async throws {
        let outputs = [try Fixtures.string("probe/vm-dev.txt"), try Fixtures.string("probe/vm-nodocker.txt")]
        let counter = Mutex(0)
        let runner = ProbeScriptedRunner(run: { _ in
            let index = counter.withLock { value in
                defer { value += 1 }
                return value
            }
            return ProbeTestData.ok(outputs[min(index, outputs.count - 1)])
        })
        let cache = CapabilityCache(runner: runner)
        let host = ProbeTestData.host()

        let before = try await cache.capabilities(for: host)
        #expect(before.contains(.dockerOK))
        let after = try await cache.refresh(host)
        #expect(!after.contains(.dockerOK))
        #expect(after.dockerNeedsSetup)
        #expect(try await cache.capabilities(for: host) == after)
        #expect(runner.calls.count == 2)
    }

    @Test("Concurrent callers share one probe")
    func sharesInFlightProbe() async throws {
        let output = try Fixtures.string("probe/vm-dev.txt")
        let runner = ProbeScriptedRunner(run: { _ in
            try await Task.sleep(for: .milliseconds(200))
            return ProbeTestData.ok(output)
        })
        let cache = CapabilityCache(runner: runner)
        let host = ProbeTestData.host()

        async let a = cache.capabilities(for: host)
        async let b = cache.capabilities(for: host)
        async let c = cache.capabilities(for: host)
        let results = try await [a, b, c]

        #expect(Set(results).count == 1)
        #expect(runner.calls.count == 1)
    }

    @Test("Failures are not cached")
    func failuresNotCached() async throws {
        let output = try Fixtures.string("probe/vm-dev.txt")
        let counter = Mutex(0)
        let runner = ProbeScriptedRunner(run: { _ in
            let attempt = counter.withLock { value in
                value += 1
                return value
            }
            return attempt == 1 ? ProbeTestData.failure(exitCode: 2, stderr: "sh: syntax error") : ProbeTestData.ok(output)
        })
        let cache = CapabilityCache(runner: runner)
        let host = ProbeTestData.host()

        await #expect(throws: SSHError.remoteCommandFailed(exitCode: 2, stderr: "sh: syntax error")) {
            try await cache.capabilities(for: host)
        }
        #expect(await cache.cached(for: host) == nil)
        #expect(try await cache.capabilities(for: host).contains(.docker))
        #expect(runner.calls.count == 2)
    }

    @Test("Transport failures surface as SSHError")
    func transportFailure() async throws {
        let runner = ProbeScriptedRunner(result: ProbeTestData.failure(exitCode: 255, stderr: "dev@vm: Permission denied (publickey)."))
        let cache = CapabilityCache(runner: runner)
        await #expect(throws: SSHError.authFailed) {
            try await cache.capabilities(for: ProbeTestData.host())
        }
    }

    @Test("Editing a host's address, port or user re-probes; invalidate forgets")
    func endpointChangeReprobes() async throws {
        let output = try Fixtures.string("probe/vm-dev.txt")
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(output))
        let cache = CapabilityCache(runner: runner)
        var host = ProbeTestData.host()

        _ = try await cache.capabilities(for: host)
        host.name = "renamed"
        _ = try await cache.capabilities(for: host)
        #expect(runner.calls.count == 1)

        host.user = "nodocker"
        #expect(await cache.cached(for: host) == nil)
        _ = try await cache.capabilities(for: host)
        #expect(runner.calls.count == 2)

        await cache.invalidate(host.id)
        #expect(await cache.cached(for: host) == nil)
        _ = try await cache.capabilities(for: host)
        #expect(runner.calls.count == 3)

        let other = ProbeTestData.host(address: "other.local")
        _ = try await cache.capabilities(for: other)
        await cache.invalidateAll()
        #expect(await cache.cached(for: host) == nil)
        #expect(await cache.cached(for: other) == nil)
    }

    @Test("A refresh supersedes a slower probe that is still running")
    func refreshSupersedesInFlight() async throws {
        let dev = try Fixtures.string("probe/vm-dev.txt")
        let nodocker = try Fixtures.string("probe/vm-nodocker.txt")
        let counter = Mutex(0)
        let runner = ProbeScriptedRunner(run: { _ in
            let attempt = counter.withLock { value in
                value += 1
                return value
            }
            if attempt == 1 {
                try await Task.sleep(for: .milliseconds(300))
                return ProbeTestData.ok(dev)
            }
            return ProbeTestData.ok(nodocker)
        })
        let cache = CapabilityCache(runner: runner)
        let host = ProbeTestData.host()

        async let slow = cache.capabilities(for: host)
        try await Task.sleep(for: .milliseconds(50))
        let fresh = try await cache.refresh(host)
        _ = try await slow

        #expect(!fresh.contains(.dockerOK))
        #expect(await cache.cached(for: host) == fresh)
    }
}
