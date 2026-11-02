#if os(iOS) || DEBUG
import AeroCore
import Collectors
import Foundation
import SSHKit

/// Canned Docker and Kubernetes answers, in the formats the real commands print, for the iOS app's
/// "Try Sample Servers", `-AeroOpsDemo` and previews, and the Mac's `-AeroSelfTest workloads`. Stop,
/// Restart and Delete change the sample state. Nothing runs anywhere.
actor DemoWorkloadRunner: RemoteCommandRunning {
    private var containers = DemoWorkloads.containers
    private var pods = DemoWorkloads.pods

    func run(_ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration, outputLimit: Int) async throws -> SSHResult {
        let output = stdin != nil ? probe(host) : dockerAnswer(command, on: host) ?? kubernetesAnswer(command) ?? ""
        return SSHResult(exitCode: 0, signal: nil, stdout: Data(output.utf8), stderr: Data(), stdoutTruncated: false, stderrTruncated: false)
    }

    func stream(
        _ command: String, on host: RemoteHost, stdin: Data?, timeout: Duration?, maxBufferedLines: Int
    ) async throws -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for line in DemoWorkloads.logLines() { continuation.yield(line) }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    continuation.yield(DemoWorkloads.logLine(DemoWorkloads.messages.randomElement() ?? "", at: .now))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func probe(_ host: RemoteHost) -> String {
        if host.name == DemoWorkloads.kubernetesHost { return "kubectl\nk3s\nkube-ok\n" }
        return containers[host.name] == nil ? "" : "docker\ndocker-ok\n"
    }

    private func dockerAnswer(_ command: String, on host: RemoteHost) -> String? {
        let target = Self.lastWord(of: command)
        if command.contains("docker ps") { return dockerList(on: host) }
        if command.contains("docker inspect") { return containers[host.name]?.first { $0.answers(to: target) }?.inspectJSON }
        if command.contains("docker logs") { return DemoWorkloads.logLines().joined(separator: "\n") }
        guard command.contains("docker ") else { return nil }
        containers[host.name] = DemoContainer.apply(command, to: target, in: containers[host.name] ?? [])
        return ""
    }

    private func dockerList(on host: RemoteHost) -> String {
        let list = containers[host.name] ?? []
        let ps = list.map(\.psLine).joined(separator: "\n")
        let stats = list.compactMap(\.statsLine).joined(separator: "\n")
        return "\(ps)\n\(DockerCommands.statsMarker)\n\(stats)\n"
    }

    private func kubernetesAnswer(_ command: String) -> String? {
        if command.contains(" get pods") {
            return "\(DemoPod.listJSON(pods))\n\(KubectlCommands.metricsMarker)\n\(DemoPod.metricsJSON(pods))\n"
        }
        if command.contains(" logs") { return DemoWorkloads.logLines().joined(separator: "\n") }
        if command.contains(" describe pod") { return DemoWorkloads.describe }
        if command.contains(" get events") { return DemoWorkloads.eventsJSON }
        if command.contains(" delete pod") { pods.removeAll { command.contains("'\($0.name)'") } }
        return nil
    }

    /// The target of a command, whose last word is its quoted name.
    private static func lastWord(of command: String) -> String {
        (command.split(separator: " ").last.map(String.init) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }
}

struct DemoContainer {
    let name: String
    let image: String
    var state: String
    var status: String
    var ports = ""
    var cpu = "0.42%"
    var memory = "84.5MiB / 1.94GiB"

    private var id: String {
        let hex = name.utf8.map { String(format: "%02x", $0) }.joined()
        return String((hex + String(repeating: "0", count: 64)).prefix(64))
    }

    /// Docker takes either; the app inspects by name and acts by ID.
    func answers(to target: String) -> Bool {
        target == name || target == id
    }

    var psLine: String {
        DemoJSON.text([
            "ID": id, "Names": name, "Image": image, "State": state, "Status": status, "Ports": ports,
            "RunningFor": "3 days ago", "CreatedAt": "2026-10-28 09:12:04 +0000 UTC",
        ])
    }

    var statsLine: String? {
        guard state == "running" else { return nil }
        return DemoJSON.text(["Container": id, "ID": String(id.prefix(12)), "Name": name, "CPUPerc": cpu, "MemUsage": memory])
    }

    var inspectJSON: String {
        DemoJSON.text([[
            "Id": id, "Name": "/\(name)", "RestartCount": 0,
            "Config": ["Image": image, "Env": ["PATH=/usr/local/bin:/usr/bin:/bin", "APP_ENV=sample"]],
            "HostConfig": ["RestartPolicy": ["Name": "unless-stopped"]],
            "State": ["Status": state, "ExitCode": state == "running" ? 0 : 137, "StartedAt": "2026-10-28T09:12:05Z"],
        ]])
    }

    /// `list` after `docker stop`, `restart` or `rm -f` on the container `target` names.
    static func apply(_ command: String, to target: String, in list: [DemoContainer]) -> [DemoContainer] {
        if command.contains(" rm ") { return list.filter { !$0.answers(to: target) } }
        let isStop = command.contains(" stop ")
        return list.map { container in
            guard container.answers(to: target) else { return container }
            var changed = container
            changed.state = isStop ? "exited" : "running"
            changed.status = isStop ? "Exited (137) 1 second ago" : "Up 1 second"
            return changed
        }
    }
}

struct DemoPod {
    let name: String
    let namespace: String
    let owner: String
    var phase = "Running"
    var ready = true
    var restarts = 0
    var waiting: String?

    private var container: String { String(owner.prefix { $0 != "-" }) }

    private var json: [String: Any] {
        [
            "metadata": [
                "name": name, "namespace": namespace, "creationTimestamp": "2026-10-28T09:12:04Z",
                "ownerReferences": [["kind": "ReplicaSet", "name": owner, "controller": true]],
            ],
            "spec": ["nodeName": "k3s-node", "containers": [["name": container]]],
            "status": ["phase": phase, "containerStatuses": [containerStatus]],
        ]
    }

    private var containerStatus: [String: Any] {
        let state: [String: Any] = waiting.map { ["waiting": ["reason": $0]] } ?? ["running": ["startedAt": "2026-10-28T09:12:10Z"]]
        return ["name": container, "ready": ready, "restartCount": restarts, "state": state]
    }

    private var metrics: [String: Any] {
        [
            "metadata": ["name": name, "namespace": namespace],
            "containers": [["name": container, "usage": ["cpu": "12m", "memory": "48Mi"]]],
        ]
    }

    static func listJSON(_ pods: [DemoPod]) -> String {
        DemoJSON.text(["kind": "PodList", "items": pods.map(\.json)])
    }

    static func metricsJSON(_ pods: [DemoPod]) -> String {
        DemoJSON.text(["kind": "PodMetricsList", "items": pods.filter(\.ready).map(\.metrics)])
    }
}

/// One-line JSON for the sample answers.
private enum DemoJSON {
    static func text(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The sample workloads, by the names in ``SampleData``. No real data or secrets.
enum DemoWorkloads {
    static let kubernetesHost = "k3s-node"

    static let containers: [String: [DemoContainer]] = [
        "web-01": [
            DemoContainer(name: "nginx", image: "nginx:1.29-alpine", state: "running", status: "Up 3 days", ports: "0.0.0.0:443->443/tcp"),
            DemoContainer(name: "api", image: "ghcr.io/example/api:4.2.0", state: "running", status: "Up 3 days (healthy)", ports: "127.0.0.1:8080->8080/tcp", cpu: "6.18%", memory: "312MiB / 1.94GiB"),
            DemoContainer(name: "worker", image: "ghcr.io/example/worker:4.2.0", state: "restarting", status: "Restarting (1) 12 seconds ago"),
            DemoContainer(name: "migrate", image: "ghcr.io/example/api:4.2.0", state: "exited", status: "Exited (0) 3 days ago"),
        ],
        "db-primary": [
            DemoContainer(name: "postgres", image: "postgres:17", state: "running", status: "Up 12 days (healthy)", ports: "127.0.0.1:5432->5432/tcp", cpu: "11.40%", memory: "1.21GiB / 7.75GiB"),
            DemoContainer(name: "pgbouncer", image: "edoburu/pgbouncer:1.24", state: "running", status: "Up 12 days"),
        ],
        "nas": [
            DemoContainer(name: "syncthing", image: "syncthing/syncthing:2.0", state: "running", status: "Up 5 days", ports: "0.0.0.0:22000->22000/tcp"),
        ],
    ]

    static let pods = [
        DemoPod(name: "web-7b56d94874-b8t9q", namespace: "shop", owner: "web-7b56d94874"),
        DemoPod(name: "web-7b56d94874-kx2lm", namespace: "shop", owner: "web-7b56d94874"),
        DemoPod(name: "checkout-89b4b56b4-djl5b", namespace: "shop", owner: "checkout-89b4b56b4", ready: false, restarts: 14, waiting: "CrashLoopBackOff"),
        DemoPod(name: "reports-596c667b4-wgmpr", namespace: "batch", owner: "reports-596c667b4", phase: "Pending", ready: false, waiting: "ImagePullBackOff"),
        DemoPod(name: "coredns-6799fbcd5-4xq8r", namespace: "kube-system", owner: "coredns-6799fbcd5"),
    ]

    static let messages = [
        "GET /healthz 200 1ms",
        "GET /api/orders?page=2 200 18ms",
        "POST /api/orders 201 42ms",
        "cache refreshed: 1204 entries",
        "WARN slow query took 812ms",
        "ERROR upstream timed out, retrying",
    ]

    static func logLine(_ message: String, at date: Date) -> String {
        "\(date.ISO8601Format()) \(message)"
    }

    static func logLines() -> [String] {
        (0..<40).map { index in
            logLine(messages[index % messages.count], at: Date.now.addingTimeInterval(Double(index - 40) * 7))
        }
    }

    static let describe = """
    Name:             checkout-89b4b56b4-djl5b
    Namespace:        shop
    Node:             k3s-node/10.0.4.21
    Status:           Running
    Controlled By:    ReplicaSet/checkout-89b4b56b4
    Containers:
      checkout:
        Image:          ghcr.io/example/checkout:2.8.1
        State:          Waiting
          Reason:       CrashLoopBackOff
        Last State:     Terminated
          Reason:       Error
          Exit Code:    1
        Ready:          False
        Restart Count:  14
    """

    static var eventsJSON: String {
        DemoJSON.text(["kind": "EventList", "items": [
            [
                "type": "Warning", "reason": "BackOff", "count": 62,
                "message": "Back-off restarting failed container checkout",
                "lastTimestamp": "2026-11-01T08:40:00Z", "firstTimestamp": "2026-11-01T07:10:00Z",
                "metadata": ["name": "checkout.backoff", "uid": "sample-1"],
            ],
            [
                "type": "Normal", "reason": "Pulled", "count": 1,
                "message": "Container image already present on machine",
                "lastTimestamp": "2026-11-01T07:09:40Z", "firstTimestamp": "2026-11-01T07:09:40Z",
                "metadata": ["name": "checkout.pulled", "uid": "sample-2"],
            ],
        ]])
    }
}
#endif
