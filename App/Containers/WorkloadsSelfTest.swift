#if DEBUG
import AeroCore
import AppKit
import Collectors
import Foundation
import SSHKit

/// `-AeroSelfTest workloads`: drives the Containers models both apps share through
/// ``DemoWorkloadRunner``'s canned Docker and Kubernetes answers, so it needs no server.
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest workloads -AeroSelfTestOutput /tmp/aeroops-workloads.json
/// ```
///
/// Writes a JSON report (`"ok": true` on success) and quits. The real commands against real
/// servers are ``Phase5SelfTest``'s job.
@MainActor
struct WorkloadsSelfTest {
    private struct Report: Encodable {
        var ok = true
        var failures: [String] = []
    }

    private struct Failure: LocalizedError {
        var errorDescription: String?
    }

    private let docker = RemoteHost(name: "web-01", address: "192.0.2.1", user: "selftest")
    private let kubernetes = RemoteHost(name: DemoWorkloads.kubernetesHost, address: "192.0.2.2", user: "selftest")
    private let empty = RemoteHost(name: "AeroOps workloads self-test", address: "192.0.2.3", user: "selftest")

    func runAndQuit() async {
        let report = await run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: url, options: .atomic)
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED \(report.failures)")")
        NSApp.terminate(nil)
    }

    private func run() async -> Report {
        let runner = DemoWorkloadRunner()
        let hosts = [docker, kubernetes, empty]
        let service = ContainerService(runner: { runner }, host: { id in hosts.first { $0.id == id } })
        var report = Report()
        do {
            try classifiesErrors()
            try await dockerActions(service.model(for: docker.id))
            try await inspects(service.model(for: docker.id))
            try await followsLogs(service.model(for: docker.id))
            try await podActions(service.model(for: kubernetes.id))
            try await nothingInstalled(service.model(for: empty.id))
        } catch {
            report.ok = false
            report.failures.append(error.localizedDescription)
        }
        return report
    }

    private func classifiesErrors() throws {
        let expected: [(any Error, WorkloadIssue.Kind)] = [
            (DockerError.permissionDenied(socket: nil), .setup),
            (DockerError.daemonNotRunning, .unavailable),
            (KubectlError.kubeconfigUnreadable(path: nil), .setup),
            (KubectlError.connectionRefused(server: nil), .unavailable),
            (CollectorInputError.invalidKubectlPrefix("x", reason: "y"), .setup),
            (SSHError.authFailed, .access),
        ]
        for (error, kind) in expected {
            try Self.expect(WorkloadIssue.from(error, host: docker)?.kind == kind, "\(error) should be \(kind)")
        }
        try Self.expect(WorkloadIssue.from(CancellationError()) == nil, "a cancelled refresh is not an issue")
    }

    private func dockerActions(_ model: HostContainersModel) async throws {
        await model.refresh(fresh: true)
        try Self.expect(model.showsDocker && !model.showsKubernetes, "web-01 should have Docker only")
        let api = try Self.container("api", in: model)
        try Self.expect(api.state == .running && api.hasUsage, "api should run and have CPU and memory")
        model.request(.stop, on: api)
        try await Self.waitUntil("api to stop") { model.containers.first { $0.name == "api" }?.state == .exited }
        try Self.expect(!model.filteredContainers.contains { $0.name == "api" }, "a stopped container should be hidden")
        model.showStopped = true
        try Self.expect(model.filteredContainers.contains { $0.name == "api" }, "Show Stopped should list it")
        model.showStopped = false
        model.request(.restart, on: try Self.container("api", in: model))
        try await Self.waitUntil("api to run again") { model.containers.first { $0.name == "api" }?.state == .running }
        model.request(.delete, on: try Self.container("api", in: model))
        let confirmation = try Self.unwrap(model.confirmation, "Delete should ask first")
        try Self.expect(model.containers.contains { $0.name == "api" }, "Delete should not run before the confirmation")
        model.perform(confirmation)
        try await Self.waitUntil("api to go") { !model.containers.contains { $0.name == "api" } }
    }

    private func inspects(_ model: HostContainersModel) async throws {
        model.inspect(try Self.container("nginx", in: model))
        let inspection = try Self.unwrap(model.inspection, "Inspect should open")
        try await Self.waitUntil("the inspection") { !inspection.isLoading }
        try Self.expect(inspection.summary != nil && inspection.json.contains("RestartPolicy"), "Inspect should have a summary and JSON")
        model.stopPresentations()
    }

    private func followsLogs(_ model: HostContainersModel) async throws {
        model.showLogs(try Self.container("nginx", in: model))
        let logs = try Self.unwrap(model.logs, "Logs should open")
        logs.start()
        try await Self.waitUntil("log lines") { logs.lineCount > 0 }
        logs.search("ERROR")
        try await Self.waitUntil("search matches") { logs.matchCount > 0 }
        model.stopPresentations()
        try Self.expect(model.logs == nil, "closing should end the logs")
    }

    private func podActions(_ model: HostContainersModel) async throws {
        await model.refresh(fresh: true)
        try Self.expect(model.showsKubernetes && !model.showsDocker, "k3s-node should have Kubernetes only")
        let crashing = try Self.unwrap(model.pods.first { $0.name.hasPrefix("checkout") }, "the checkout pod is missing")
        try Self.expect(crashing.containers.contains { $0.waitingReason == "CrashLoopBackOff" }, "checkout should crash-loop")
        model.namespace = "batch"
        try Self.expect(model.filteredPods.allSatisfy { $0.namespace == "batch" }, "the namespace filter should apply")
        model.namespace = nil
        try await describes(crashing, in: model)
        model.request(.delete, on: crashing)
        model.perform(try Self.unwrap(model.confirmation, "Delete should ask first"))
        try await Self.waitUntil("the pod to go") { !model.pods.contains { $0.id == crashing.id } }
    }

    private func describes(_ pod: PodInfo, in model: HostContainersModel) async throws {
        model.showDetail(pod)
        let detail = try Self.unwrap(model.podDetail, "the pod detail should open")
        try await Self.waitUntil("the pod detail") { !detail.isLoading }
        try Self.expect(!detail.describe.isEmpty && !detail.events.isEmpty, "the detail should have describe and events")
        model.stopPresentations()
    }

    private func nothingInstalled(_ model: HostContainersModel) async throws {
        await model.refresh(fresh: true)
        try Self.expect(model.capabilities != nil && model.availableSections.isEmpty, "this host has neither")
    }

    private static func container(_ name: String, in model: HostContainersModel) throws -> ContainerInfo {
        try unwrap(model.containers.first { $0.name == name }, "\(name) is not listed")
    }

    private static func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            try expect(ContinuousClock.now < deadline, "timed out waiting for \(what)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func unwrap<Value>(_ value: Value?, _ failure: String) throws -> Value {
        guard let value else { throw Failure(errorDescription: failure) }
        return value
    }

    private static func expect(_ condition: Bool, _ failure: String) throws {
        if !condition { throw Failure(errorDescription: failure) }
    }
}
#endif
