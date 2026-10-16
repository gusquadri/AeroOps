import AeroCore
import AeroTestSupport
import Foundation
import SSHKit
import Testing
@testable import Collectors

@Suite("Kubectl prefix")
struct KubernetesPrefixTests {
    @Test("Accepted prefixes, normalized", arguments: [
        (nil, "kubectl"),
        ("", "kubectl"),
        ("  \t ", "kubectl"),
        ("kubectl", "kubectl"),
        ("k3s kubectl", "k3s kubectl"),
        ("sudo -n k3s kubectl", "sudo -n k3s kubectl"),
        ("  sudo  -n\tk3s   kubectl ", "sudo -n k3s kubectl"),
        ("microk8s kubectl", "microk8s kubectl"),
        ("/usr/local/bin/kubectl", "/usr/local/bin/kubectl"),
        ("KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl", "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl"),
        ("A=1 _B=x,y kubectl", "A=1 _B=x,y kubectl"),
        ("kubectl --context=prod@eu-1 --kubeconfig=/home/dev/.kube/config", "kubectl --context=prod@eu-1 --kubeconfig=/home/dev/.kube/config"),
        ("sudo -n -u ops kubectl", "sudo -n -u ops kubectl"),
    ] as [(String?, String)])
    func accepted(prefix: String?, expected: String) throws {
        #expect(try KubectlPrefix.normalized(prefix) == expected)
        #expect(KubectlPrefix.isValid(prefix))
    }

    @Test("Rejected prefixes", arguments: [
        "kubectl; rm -rf /", "kubectl && id", "kubectl | tee x", "kubectl > /tmp/x", "kubectl < /etc/passwd",
        "$(id) kubectl", "`id` kubectl", "${KUBECTL}", "kubectl 'get'", "kubectl \"x\"", "kubectl\nid",
        "kubectl\rid", "kubectl *", "kubectl ?", "kubectl [a]", "kubectl {a,b}", "(kubectl)", "~/bin/kubectl",
        "kubectl #comment", "!kubectl", "kubectl\\ x", "kubéctl", "=x kubectl", "1A=x kubectl", "A-B=x kubectl",
        "KUBECONFIG=/x", "A=1 B=2", "-n kubectl", "A=1 --flag", String(repeating: "a", count: 257),
        Array(repeating: "a", count: 17).joined(separator: " "), "kubectl\u{0}x", "kubectl\u{7F}",
    ])
    func rejected(prefix: String) {
        #expect(!KubectlPrefix.isValid(prefix))
        #expect(throws: CollectorInputError.self) { try KubectlPrefix.normalized(prefix) }
        #expect(throws: CollectorInputError.self) { try KubectlCommands(prefix: prefix) }
    }

    @Test("Rejections explain themselves and carry a recovery suggestion")
    func rejectionMessage() {
        let error = #expect(throws: CollectorInputError.self) { try KubectlPrefix.normalized("kubectl; id") }
        guard case .invalidKubectlPrefix(let prefix, let reason)? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(prefix == "kubectl; id")
        #expect(reason.contains("\";\""))
        #expect(error?.recoverySuggestion?.contains("sudo -n k3s kubectl") == true)
        #expect(error?.errorDescription?.contains("kubectl prefix") == true)
    }
}

@Suite("Kubectl commands")
struct KubernetesCommandTests {
    @Test("Pods and their metrics, all namespaces or one")
    func pods() throws {
        let plain = try KubectlCommands(prefix: nil)
        #expect(try plain.pods() == #"""
            LC_ALL=C sh -c 'kubectl get pods -A -o json || exit $?; echo; echo @@aero-pod-metrics; \#
            kubectl get --raw '\''/apis/metrics.k8s.io/v1beta1/pods'\'' --request-timeout=5s 2>/dev/null || true'
            """#)
        #expect(try plain.pods(namespace: "demo") == #"""
            LC_ALL=C sh -c 'kubectl get pods -n '\''demo'\'' -o json || exit $?; echo; echo @@aero-pod-metrics; \#
            kubectl get --raw '\''/apis/metrics.k8s.io/v1beta1/namespaces/demo/pods'\'' --request-timeout=5s 2>/dev/null || true'
            """#)
        let k3s = try KubectlCommands(host: ProbeTestData.host(kubectlPrefix: "sudo -n k3s kubectl"))
        #expect(try k3s.pods() == Self.k3sPods)
        #expect(throws: CollectorInputError.self) { try plain.pods(namespace: "demo/../x") }
    }

    static let k3sPods = #"""
        LC_ALL=C sh -c 'sudo -n k3s kubectl get pods -A -o json || exit $?; echo; echo @@aero-pod-metrics; \#
        sudo -n k3s kubectl get --raw '\''/apis/metrics.k8s.io/v1beta1/pods'\'' --request-timeout=5s 2>/dev/null || true'
        """#

    @Test("Pods output splits at the marker line")
    func splitPodsOutput() {
        let pods = Data(#"{"items":[{"metadata":{"name":"@@aero-pod-metrics"}}]}"#.utf8)
        let metrics = Data(#"{"items":[]}"#.utf8)
        let joined = pods + Data("\n\n@@aero-pod-metrics\n".utf8) + metrics + Data("\n".utf8)
        let parts = KubectlCommands.splitPodsOutput(joined)
        #expect(parts.pods == pods + Data("\n".utf8))
        #expect(parts.metrics == metrics + Data("\n".utf8))

        let failed = KubectlCommands.splitPodsOutput(pods + Data("\n\n@@aero-pod-metrics\n".utf8))
        #expect(failed.pods == pods + Data("\n".utf8))
        #expect(failed.metrics.isEmpty)

        let bare = KubectlCommands.splitPodsOutput(pods)
        #expect(bare.pods == pods)
        #expect(bare.metrics.isEmpty)
    }

    @Test("Logs: container, previous, tail, timestamps, since, follow")
    func logs() throws {
        let k3s = try KubectlCommands(prefix: "sudo -n k3s kubectl")
        #expect(try k3s.logs(pod: "crasher-89b4b56b4-djl5b", namespace: "demo", container: "crasher", previous: true, tail: 500)
            == "LC_ALL=C sudo -n k3s kubectl logs -n 'demo' 'crasher-89b4b56b4-djl5b' -c 'crasher' --previous --tail=500 --timestamps")
        #expect(try k3s.logs(pod: "web-1", namespace: "demo", tail: 9000, sinceSeconds: 120, follow: true)
            == "LC_ALL=C sudo -n k3s kubectl logs -f -n 'demo' 'web-1' --tail=2000 --timestamps --since=120s")
    }

    @Test("Describe and events")
    func describeAndEvents() throws {
        let plain = try KubectlCommands(prefix: "kubectl")
        #expect(try plain.describe(pod: "crasher-1", namespace: "demo") == "LC_ALL=C kubectl describe pod -n 'demo' 'crasher-1'")
        #expect(try plain.events(pod: "pending-1", namespace: "demo")
            == "LC_ALL=C kubectl get events -n 'demo' --field-selector 'involvedObject.name=pending-1' -o json")
    }

    @Test("Delete a pod without waiting; scale its owner")
    func actions() throws {
        let k3s = try KubectlCommands(prefix: "sudo -n k3s kubectl")
        #expect(try k3s.deletePod("web-7b56d94874-b8t9q", namespace: "demo")
            == "LC_ALL=C sudo -n k3s kubectl delete pod -n 'demo' 'web-7b56d94874-b8t9q' --wait=false")
        #expect(try k3s.scale(PodOwner(kind: "Deployment", name: "web"), namespace: "demo", replicas: 0)
            == "LC_ALL=C sudo -n k3s kubectl scale -n 'demo' 'deployment/web' --replicas=0")
        #expect(try k3s.scale(PodOwner(kind: "StatefulSet", name: "db"), namespace: "demo", replicas: 3)
            == "LC_ALL=C sudo -n k3s kubectl scale -n 'demo' 'statefulset/db' --replicas=3")
        #expect(throws: CollectorInputError.self) {
            try k3s.scale(PodOwner(kind: "DaemonSet", name: "agent"), namespace: "demo", replicas: 0)
        }
        #expect(throws: CollectorInputError.self) {
            try k3s.scale(PodOwner(kind: "Deployment", name: "web"), namespace: "demo", replicas: -1)
        }
    }

    @Test("Hostile names are rejected in every position", arguments: dockerHostileNames)
    func hostileNames(name: String) throws {
        let kubectl = try KubectlCommands(prefix: nil)
        #expect(throws: CollectorInputError.unsafeName(field: "namespace", value: name)) { try kubectl.pods(namespace: name) }
        #expect(throws: CollectorInputError.unsafeName(field: "pod", value: name)) {
            try kubectl.logs(pod: name, namespace: "demo", tail: 1)
        }
        #expect(throws: CollectorInputError.unsafeName(field: "namespace", value: name)) {
            try kubectl.logs(pod: "web", namespace: name, tail: 1)
        }
        #expect(throws: CollectorInputError.unsafeName(field: "container", value: name)) {
            try kubectl.logs(pod: "web", namespace: "demo", container: name, tail: 1)
        }
        #expect(throws: CollectorInputError.self) { try kubectl.describe(pod: name, namespace: "demo") }
        #expect(throws: CollectorInputError.self) { try kubectl.events(pod: name, namespace: "demo") }
        #expect(throws: CollectorInputError.self) { try kubectl.events(pod: "web", namespace: name) }
        #expect(throws: CollectorInputError.self) { try kubectl.deletePod(name, namespace: "demo") }
        #expect(throws: CollectorInputError.self) { try kubectl.deletePod("web", namespace: name) }
        #expect(throws: CollectorInputError.unsafeName(field: "name", value: name)) {
            try kubectl.scale(PodOwner(kind: "Deployment", name: name), namespace: "demo", replicas: 0)
        }
        #expect(throws: CollectorInputError.self) {
            try kubectl.scale(PodOwner(kind: "Deployment", name: "web"), namespace: name, replicas: 0)
        }
    }
}

@Suite("KubernetesCollector")
struct KubernetesCollectorTests {
    private let k3sHost = ProbeTestData.host(kubectlPrefix: "sudo -n k3s kubectl")

    @Test("Pods parse, including the crash-looping one")
    func pods() async throws {
        let runner = ProbeScriptedRunner(result: SSHResult(exitCode: 0, stdout: try Fixtures.data("kubectl/pods-all.json")))
        let pods = try await KubernetesCollector(runner: runner).pods(on: k3sHost)

        #expect(pods.count == 7)
        let crasher = try #require(pods.first { $0.name.hasPrefix("crasher-") })
        #expect(crasher.namespace == "demo")
        #expect(crasher.restarts > 0)
        #expect(crasher.cpuMillicores == nil)
        #expect(runner.commands == [KubernetesCommandTests.k3sPods])
    }

    @Test("Pods carry CPU and memory when the metrics API answers")
    func podsWithMetrics() async throws {
        let output = try Fixtures.data("kubectl/pods-all.json") + Data("\n@@aero-pod-metrics\n".utf8)
            + (try Fixtures.data("kubectl/synthetic-metrics-pods.json"))
        let runner = ProbeScriptedRunner(result: SSHResult(exitCode: 0, stdout: output))
        let pods = try await KubernetesCollector(runner: runner).pods(on: k3sHost)

        #expect(pods.count == 7)
        let web = try #require(pods.first { $0.name.hasPrefix("web-") })
        #expect(web.cpuMillicores == 3)
        #expect(web.memUsedBytes == 3_764_224)
        #expect(web.memLimitBytes == 96 << 20)
        #expect(pods.first { $0.name.hasPrefix("pending-") }?.memUsedBytes == nil)
    }

    @Test("An invalid prefix fails before ssh")
    func invalidPrefix() async {
        let runner = ProbeScriptedRunner()
        let collector = KubernetesCollector(runner: runner)
        let host = ProbeTestData.host(kubectlPrefix: "kubectl; reboot")
        await #expect(throws: CollectorInputError.self) { try await collector.pods(on: host) }
        await #expect(throws: CollectorInputError.self) { try await collector.logs(pod: "a", namespace: "b", on: host) }
        await #expect(throws: CollectorInputError.self) { try await collector.followLogs(pod: "a", namespace: "b", on: host) }
        await #expect(throws: CollectorInputError.self) { try await collector.describe(pod: "a", namespace: "b", on: host) }
        await #expect(throws: CollectorInputError.self) { try await collector.events(pod: "a", namespace: "b", on: host) }
        #expect(runner.calls.isEmpty)
    }

    @Test("Unreadable kubeconfig maps to kubeconfigUnreadable with the k3s hint")
    func kubeconfigUnreadable() async throws {
        let runner = ProbeScriptedRunner(result: try ProbeTestData.errorFixture("kubectl/error-kubeconfig-unreadable.txt"))
        let error = await #expect(throws: KubectlError.self) {
            try await KubernetesCollector(runner: runner).pods(on: ProbeTestData.host())
        }
        #expect(error == .kubeconfigUnreadable(path: "/etc/rancher/k3s/k3s.yaml"))
        #expect(error?.hint?.contains("sudo -n k3s kubectl") == true)
    }

    @Test("sudo refusal maps to sudoRefused")
    func sudoRefused() async throws {
        let runner = ProbeScriptedRunner(result: try ProbeTestData.errorFixture("kubectl/error-sudo-not-allowed.txt"))
        let error = await #expect(throws: KubectlError.self) {
            try await KubernetesCollector(runner: runner).pods(on: k3sHost)
        }
        #expect(error == .sudoRefused)
        #expect(error?.hint?.contains("NOPASSWD") == true)
    }

    @Test("Previous logs of a container that never restarted map to noPreviousContainer")
    func noPrevious() async throws {
        let runner = ProbeScriptedRunner(result: try ProbeTestData.errorFixture("kubectl/error-no-previous-container.txt"))
        await #expect(throws: KubectlError.noPreviousContainer(container: "nginx", pod: "web-7b56d94874-b8t9q")) {
            try await KubernetesCollector(runner: runner)
                .logs(pod: "web-7b56d94874-b8t9q", namespace: "demo", container: "nginx", previous: true, on: k3sHost)
        }
    }

    @Test("Previous logs come back stripped, with the right command")
    func previousLogs() async throws {
        let raw = try Fixtures.string("kubectl/logs-crasher-previous.txt")
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(raw))
        let text = try await KubernetesCollector(runner: runner)
            .logs(pod: "crasher-89b4b56b4-djl5b", namespace: "demo", previous: true, tail: 50, on: k3sHost)
        #expect(text.text.contains("FATAL: connection refused"))
        #expect(!text.truncated)
        #expect(runner.commands == [
            "LC_ALL=C sudo -n k3s kubectl logs -n 'demo' 'crasher-89b4b56b4-djl5b' --previous --tail=50 --timestamps",
        ])
    }

    @Test("Pod actions run the right command; RBAC refusals are classified")
    func podActions() async throws {
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok("pod \"web-1\" deleted\n"))
        let collector = KubernetesCollector(runner: runner)
        try await collector.deletePod("web-1", namespace: "demo", on: k3sHost)
        try await collector.scale(PodOwner(kind: "Deployment", name: "web"), namespace: "demo", replicas: 0, on: k3sHost)
        #expect(runner.commands == [
            "LC_ALL=C sudo -n k3s kubectl delete pod -n 'demo' 'web-1' --wait=false",
            "LC_ALL=C sudo -n k3s kubectl scale -n 'demo' 'deployment/web' --replicas=0",
        ])

        let forbidden = ProbeScriptedRunner(result: ProbeTestData.failure(
            stderr: "Error from server (Forbidden): pods \"web-1\" is forbidden: User \"dev\" cannot delete resource \"pods\"\n"
        ))
        await #expect(throws: KubectlError.self) {
            try await KubernetesCollector(runner: forbidden).deletePod("web-1", namespace: "demo", on: k3sHost)
        }
    }

    @Test("Events for the Pending pod")
    func events() async throws {
        let runner = ProbeScriptedRunner(result: SSHResult(exitCode: 0, stdout: try Fixtures.data("kubectl/events-pending.json")))
        let events = try await KubernetesCollector(runner: runner).events(pod: "pending-55687bcf9d-h9f9k", namespace: "demo", on: k3sHost)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.reason == "FailedScheduling" })
        #expect(runner.commands == [
            "LC_ALL=C sudo -n k3s kubectl get events -n 'demo' --field-selector 'involvedObject.name=pending-55687bcf9d-h9f9k' -o json",
        ])
    }

    @Test("Non-JSON events output is invalidOutput")
    func eventsInvalid() async {
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok("No resources found in demo namespace.\n"))
        await #expect(throws: KubectlError.invalidOutput) {
            try await KubernetesCollector(runner: runner).events(pod: "x", namespace: "demo", on: k3sHost)
        }
    }

    @Test("Describe keeps the head when capped")
    func describe() async throws {
        let raw = try Fixtures.string("kubectl/describe-crasher.txt")
        let runner = ProbeScriptedRunner(result: ProbeTestData.ok(raw))
        let text = try await KubernetesCollector(runner: runner).describe(pod: "crasher-89b4b56b4-djl5b", namespace: "demo", on: k3sHost)
        #expect(text.text == raw)
        #expect(!text.truncated)

        let huge = "Name: big\n" + String(repeating: "x\n", count: 700_000)
        let big = try await KubernetesCollector(runner: ProbeScriptedRunner(result: ProbeTestData.ok(huge)))
            .describe(pod: "big", namespace: "demo", on: k3sHost)
        #expect(big.truncated)
        #expect(big.text.hasPrefix("Name: big\n"))
        #expect(big.text.utf8.count <= LogText.defaultMaxBytes)
    }

    @Test("Follow streams lines; errors on stderr are classified")
    func follow() async throws {
        let ok = ProbeScriptedRunner(stream: { _ in .init(lines: ["l1", "l2"], end: .finish) })
        var lines: [String] = []
        for try await line in try await KubernetesCollector(runner: ok)
            .followLogs(pod: "web-1", namespace: "demo", container: "log-sidecar", on: k3sHost) {
            lines.append(line)
        }
        #expect(lines == ["l1", "l2"])
        #expect(ok.commands == [LogFollowStream.remoteCommand(
            "LC_ALL=C sudo -n k3s kubectl logs -f -n 'demo' 'web-1' -c 'log-sidecar' --tail=100 --timestamps"
        )])

        let refused = ProbeScriptedRunner(stream: { _ in
            .init(lines: [], end: .fail(.remoteCommandFailed(exitCode: 1, stderr: "sudo: a password is required")))
        })
        let stream = try await KubernetesCollector(runner: refused).followLogs(pod: "web-1", namespace: "demo", on: k3sHost)
        await #expect(throws: KubectlError.sudoRefused) {
            for try await _ in stream {}
        }
    }

    @Test("Follow cancellation reaches the ssh stream")
    func followCancel() async throws {
        let runner = ProbeScriptedRunner(stream: { _ in .init(lines: ["x"], end: .hang) })
        let stream = try await KubernetesCollector(runner: runner).followLogs(pod: "web-1", namespace: "demo", on: k3sHost)
        let consumer = Task { for try await _ in stream {} }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = await consumer.result
        #expect(await runner.waitUntil { $0.cancelledStreams == 1 })
    }
}
