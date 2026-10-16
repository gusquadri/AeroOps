import Foundation
import Testing
import AeroCore
import AeroTestSupport

@Suite("KubernetesParser")
struct KubernetesParserTests {
    /// 2026-10-11T00:00:00Z.
    private let day = 1_791_676_800.0

    private func time(_ hour: Double, _ minute: Double, _ second: Double) -> Date {
        Date(timeIntervalSince1970: day + hour * 3600 + minute * 60 + second)
    }

    private func fixturePods() throws -> [PodInfo] {
        try KubernetesParser.parsePods(try Fixtures.data("kubectl/pods-all.json"))
    }

    // MARK: - Pods

    @Test("pods-all: names, namespaces, phases, nodes and creation times")
    func podList() throws {
        let pods = try fixturePods()
        #expect(pods.map(\.id) == [
            "demo/bad-image-596c667b4-wgmpr",
            "demo/crasher-89b4b56b4-djl5b",
            "demo/hello-894fb",
            "demo/pending-55687bcf9d-h9f9k",
            "demo/web-7b56d94874-b8t9q",
            "kube-system/coredns-7cfb7bc9c7-sdcln",
            "kube-system/local-path-provisioner-77b9867795-www4x",
        ])
        #expect(pods.map(\.phase) == [.pending, .running, .succeeded, .pending, .running, .running, .running])
        #expect(pods.map(\.nodeName) == ["aeroops-vm", "aeroops-vm", "aeroops-vm", nil, "aeroops-vm", "aeroops-vm", "aeroops-vm"])
        #expect(pods[0].createdAt == time(6, 55, 6))
        #expect(pods[2].createdAt == time(6, 55, 5))
        #expect(pods.map(\.readyCount) == [0, 0, 0, 0, 2, 1, 1])
        #expect(pods.map(\.containerCount) == [1, 1, 1, 1, 2, 1, 1])
        #expect(pods.map(\.restarts) == [0, 6, 0, 0, 0, 0, 0])
    }

    @Test("pods-all: container details and status colours")
    func podContainers() throws {
        let pods = try fixturePods()

        let badImage = pods[0]
        #expect(badImage.containers == [PodContainerStatus(name: "app", ready: false, waitingReason: "ImagePullBackOff")])
        #expect(badImage.health == .failing)
        #expect(badImage.displayStatus == "ImagePullBackOff")
        #expect(!badImage.isCrashLooping)

        let crasher = pods[1]
        #expect(crasher.containers == [
            PodContainerStatus(name: "crasher", ready: false, restartCount: 6, waitingReason: "CrashLoopBackOff"),
        ])
        #expect(crasher.containers[0].hasPreviousInstance)
        #expect(crasher.health == .failing)
        #expect(crasher.isCrashLooping)
        #expect(crasher.displayStatus == "CrashLoopBackOff")

        let hello = pods[2]
        #expect(hello.containers == [
            PodContainerStatus(name: "hello", ready: false, terminatedReason: "Completed", exitCode: 0),
        ])
        #expect(hello.containers[0].isTerminated)
        #expect(!hello.containers[0].hasPreviousInstance)
        #expect(hello.health == .inactive)
        #expect(hello.displayStatus == "Completed")

        // Unscheduled: the spec container is listed (0/1) even without a status.
        let pending = pods[3]
        #expect(pending.containers == [PodContainerStatus(name: "app", ready: false)])
        #expect(pending.health == .warning)
        #expect(pending.displayStatus == "Pending")

        // Spec order (nginx first) even though kubectl lists statuses alphabetically.
        let web = pods[4]
        #expect(web.containers.map(\.name) == ["nginx", "log-sidecar"])
        #expect(web.containers.allSatisfy { $0.ready && !$0.isTerminated && $0.waitingReason == nil })
        #expect(web.health == .healthy)
        #expect(web.displayStatus == "Running")
        #expect(web.age(now: time(9, 55, 6)) == "3h")

        #expect(pods[5].health == .healthy)
        #expect(pods[6].health == .healthy)
    }

    @Test("terminated with Error between restarts counts as crash-looping")
    func terminatedBetweenRestarts() {
        let pod = PodInfo(namespace: "demo", name: "crasher", phase: .running, containers: [
            PodContainerStatus(name: "crasher", ready: false, restartCount: 3, terminatedReason: "Error", exitCode: 1),
        ])
        #expect(pod.isCrashLooping)
        #expect(pod.health == .failing)
        #expect(pod.displayStatus == "Error")

        // First run ending in an error is failing, but not (yet) a crash loop.
        let firstRun = PodInfo(namespace: "demo", name: "x", phase: .running, containers: [
            PodContainerStatus(name: "x", ready: false, restartCount: 0, terminatedReason: "Error", exitCode: 1),
        ])
        #expect(!firstRun.isCrashLooping)
        #expect(firstRun.health == .failing)

        let noReason = PodInfo(namespace: "demo", name: "y", phase: .running, containers: [
            PodContainerStatus(name: "y", ready: false, restartCount: 2, exitCode: 137),
        ])
        #expect(noReason.isCrashLooping)
        #expect(noReason.displayStatus == "ExitCode:137")
    }

    @Test("status colours for other phases and reasons")
    func healthTable() {
        func pod(_ phase: PodPhase, _ containers: [PodContainerStatus]) -> PodInfo {
            PodInfo(namespace: "n", name: "p", phase: phase, containers: containers)
        }
        #expect(pod(.pending, [PodContainerStatus(name: "a", ready: false, waitingReason: "ContainerCreating")]).health == .warning)
        #expect(pod(.pending, [PodContainerStatus(name: "a", ready: false, waitingReason: "ContainerCreating")]).displayStatus == "ContainerCreating")
        #expect(pod(.pending, [PodContainerStatus(name: "a", ready: false, waitingReason: "ErrImagePull")]).health == .failing)
        #expect(pod(.pending, [PodContainerStatus(name: "a", ready: false, waitingReason: "CreateContainerConfigError")]).health == .failing)
        #expect(pod(.running, [PodContainerStatus(name: "a", ready: true), PodContainerStatus(name: "b", ready: false)]).health == .warning)
        #expect(pod(.running, []).health == .warning)
        #expect(pod(.failed, [PodContainerStatus(name: "a", ready: false)]).health == .failing)
        #expect(pod(.succeeded, []).health == .inactive)
        #expect(pod(.unknown, []).health == .warning)
        #expect(pod(.failed, []).displayStatus == "Failed")
    }

    @Test("a single Pod object, a bare list, and a k3s warning before the JSON")
    func podShapes() throws {
        let single = #"{"kind":"Pod","metadata":{"name":"solo","creationTimestamp":"2026-10-11T06:55:06Z"},"status":{"phase":"Running"}}"#
        let pods = try KubernetesParser.parsePods(single)
        #expect(pods == [PodInfo(namespace: "default", name: "solo", phase: .running, createdAt: time(6, 55, 6))])

        #expect(try KubernetesParser.parsePods(#"{"kind":"List","items":[]}"#).isEmpty)

        let warning = #"time="2026-10-11T04:03:10-03:00" level=warning msg="something""# + "\n"
        let withBanner = warning + (try Fixtures.string("kubectl/pods-all.json"))
        #expect(try KubernetesParser.parsePods(withBanner).count == 7)
    }

    @Test("odd pods are skipped or tolerated, not fatal")
    func oddPods() throws {
        let json = #"""
        {"items":[
          {"metadata":{"name":"ok","namespace":"a"},"status":{"phase":"Evicted?","containerStatuses":[{"name":"c","ready":"yes","restartCount":-4}]}},
          {"metadata":{"namespace":"a"}},
          42,
          null,
          {"metadata":{"name":"typed-wrong","namespace":7},"spec":"nope","status":{"phase":3}},
          {"metadata":{"name":"extra","namespace":"a"},"spec":{"containers":[{"name":"main"},{"image":"x"}]},
           "status":{"containerStatuses":[{"name":"main","ready":true},{"name":"injected","ready":true},{"ready":true}]}}
        ]}
        """#
        let pods = try KubernetesParser.parsePods(json)
        #expect(pods.map(\.name) == ["ok", "typed-wrong", "extra"])
        #expect(pods[0].phase == .unknown)
        #expect(pods[0].containers == [PodContainerStatus(name: "c", ready: false, restartCount: 0)])
        #expect(pods[1].namespace == "default")
        #expect(pods[1].phase == .unknown)
        #expect(pods[1].containers.isEmpty)
        #expect(pods[2].containers.map(\.name) == ["main", "injected"])
        #expect(pods[2].phase == .unknown)
    }

    // MARK: - Owners

    @Test("pods-all: Deployment pods resolve their ReplicaSet to the Deployment; the Job pod keeps its Job")
    func podOwners() throws {
        let pods = try fixturePods()
        #expect(pods.map(\.owner) == [
            PodOwner(kind: "Deployment", name: "bad-image"),
            PodOwner(kind: "Deployment", name: "crasher"),
            PodOwner(kind: "Job", name: "hello"),
            PodOwner(kind: "Deployment", name: "pending"),
            PodOwner(kind: "Deployment", name: "web"),
            PodOwner(kind: "Deployment", name: "coredns"),
            PodOwner(kind: "Deployment", name: "local-path-provisioner"),
        ])
        #expect(pods[1].owner?.isScalable == true)
        #expect(pods[1].owner?.recreatesPods == true)
        #expect(pods[2].owner?.isScalable == false)
        #expect(pods[2].owner?.recreatesPods == false)
    }

    @Test("owners: only the controller counts; a bare ReplicaSet, StatefulSet and DaemonSet stay as they are")
    func ownerVariants() throws {
        let json = #"""
        {"items":[
          {"metadata":{"name":"bare","namespace":"a"}},
          {"metadata":{"name":"not-controller","namespace":"a",
                       "ownerReferences":[{"kind":"ConfigMap","name":"x"},{"kind":"ReplicaSet","name":"y","controller":false}]}},
          {"metadata":{"name":"rs-1","namespace":"a","ownerReferences":[{"kind":"ReplicaSet","name":"rs","controller":true}]}},
          {"metadata":{"name":"other-hash","namespace":"a","labels":{"pod-template-hash":"abc"},
                       "ownerReferences":[{"kind":"ReplicaSet","name":"rs-def","controller":true}]}},
          {"metadata":{"name":"db-0","namespace":"a","ownerReferences":[{"kind":"StatefulSet","name":"db","controller":true}]}},
          {"metadata":{"name":"agent-x1","namespace":"a","ownerReferences":[{"kind":"DaemonSet","name":"agent","controller":true}]}},
          {"metadata":{"name":"etcd-node1","namespace":"a","ownerReferences":[{"kind":"Node","name":"node1","controller":true}]}},
          {"metadata":{"name":"odd","namespace":"a","labels":"none","ownerReferences":"none"}}
        ]}
        """#
        let pods = try KubernetesParser.parsePods(json)
        #expect(pods.map(\.owner) == [
            nil,
            nil,
            PodOwner(kind: "ReplicaSet", name: "rs"),
            PodOwner(kind: "ReplicaSet", name: "rs-def"),
            PodOwner(kind: "StatefulSet", name: "db"),
            PodOwner(kind: "DaemonSet", name: "agent"),
            PodOwner(kind: "Node", name: "node1"),
            nil,
        ])
        #expect(pods[5].owner?.recreatesPods == true)
        #expect(pods[5].owner?.isScalable == false)
        #expect(pods[6].owner?.recreatesPods == false)
    }

    // MARK: - Resources and metrics

    @Test("pods-all: memory limits summed over containers, no CPU limits")
    func podLimits() throws {
        let pods = try fixturePods()
        #expect(pods.map(\.memLimitBytes) == [nil, 32 << 20, nil, nil, 96 << 20, 170 << 20, nil])
        #expect(pods.allSatisfy { $0.cpuLimitMillicores == nil })
        #expect(pods.allSatisfy { $0.cpuMillicores == nil && $0.memUsedBytes == nil })
    }

    @Test("limits: pod-level wins, every container needs one for a sum, bad values are no limit")
    func limitVariants() throws {
        let json = #"""
        {"items":[
          {"metadata":{"name":"pod-level","namespace":"a"},
           "spec":{"resources":{"limits":{"cpu":"2","memory":"1Gi"}},
                   "containers":[{"name":"c","resources":{"limits":{"cpu":"100m","memory":"64Mi"}}}]}},
          {"metadata":{"name":"summed","namespace":"a"},
           "spec":{"containers":[{"name":"a","resources":{"limits":{"cpu":"250m","memory":"64Mi"}}},
                                 {"name":"b","resources":{"limits":{"cpu":"0.1","memory":"128M"}}}]}},
          {"metadata":{"name":"one-unlimited","namespace":"a"},
           "spec":{"containers":[{"name":"a","resources":{"limits":{"cpu":"1","memory":"64Mi"}}},
                                 {"name":"b","resources":{"limits":{"memory":"64Mi"}}}]}},
          {"metadata":{"name":"junk","namespace":"a"},
           "spec":{"containers":[{"name":"a","resources":{"limits":{"cpu":"lots","memory":-5}}}]}},
          {"metadata":{"name":"wrong-types","namespace":"a"},
           "spec":{"containers":[{"name":"a","resources":"none"},{"name":"b","resources":{"limits":[1]}}]}}
        ]}
        """#
        let pods = try KubernetesParser.parsePods(json)
        #expect(pods.map(\.name) == ["pod-level", "summed", "one-unlimited", "junk", "wrong-types"])
        #expect(pods.map(\.cpuLimitMillicores) == [2000, 350, nil, nil, nil])
        #expect(pods.map(\.memLimitBytes) == [1 << 30, (64 << 20) + 128_000_000, 128 << 20, nil, nil])
        #expect(pods[4].containers.map(\.name) == ["a", "b"])
    }

    @Test("metrics: usage summed over containers and rounded up like kubectl top")
    func podMetrics() throws {
        let metrics = KubernetesParser.parsePodMetrics(try Fixtures.data("kubectl/synthetic-metrics-pods.json"))
        #expect(metrics == [
            PodMetrics(namespace: "demo", name: "crasher-89b4b56b4-djl5b", cpuMillicores: 0, memUsedBytes: 1_263_616),
            // 152341n + 2003456n = 2.155797m; 3164Ki + 512Ki.
            PodMetrics(namespace: "demo", name: "web-7b56d94874-b8t9q", cpuMillicores: 3, memUsedBytes: 3_764_224),
            PodMetrics(namespace: "demo", name: "gone-6d4cf56db6-q2x7m", cpuMillicores: 7, memUsedBytes: 20 << 20),
            PodMetrics(namespace: "kube-system", name: "coredns-7cfb7bc9c7-sdcln", cpuMillicores: 3, memUsedBytes: 14_258_176),
            PodMetrics(
                namespace: "kube-system", name: "local-path-provisioner-77b9867795-www4x",
                cpuMillicores: 2, memUsedBytes: 7_938_048
            ),
        ])
    }

    @Test("pods-all with metrics: running pods get usage, the rest and unknown pods are left alone")
    func podsWithMetrics() throws {
        let pods = try KubernetesParser.parsePods(
            try Fixtures.data("kubectl/pods-all.json"),
            metrics: try Fixtures.data("kubectl/synthetic-metrics-pods.json")
        )
        #expect(pods.count == 7)
        #expect(pods.map(\.cpuMillicores) == [nil, 0, nil, nil, 3, 3, 2])
        #expect(pods.map(\.memUsedBytes) == [nil, 1_263_616, nil, nil, 3_764_224, 14_258_176, 7_938_048])
        #expect(pods.map(\.memLimitBytes) == [nil, 32 << 20, nil, nil, 96 << 20, 170 << 20, nil])
    }

    @Test("metrics: errors, empty output and odd items are no metrics, not a failure")
    func podMetricsVariants() throws {
        let notFound = "Error from server (NotFound): the server could not find the requested resource"
        for junk in ["", notFound, "{}", #"{"items":null}"#, "[1,2]"] {
            #expect(KubernetesParser.parsePodMetrics(Data(junk.utf8)).isEmpty)
            #expect(try KubernetesParser.parsePods(#"{"items":[{"metadata":{"name":"p"}}]}"#, metrics: junk).count == 1)
        }

        let json = #"""
        {"items":[
          {"metadata":{"name":"no-ns"},"containers":[{"name":"c","usage":{"cpu":"250m"}}]},
          {"containers":[{"usage":{"cpu":"1"}}]},
          {"metadata":{"name":"mixed","namespace":"a"},
           "containers":[{"usage":{"cpu":"1m","memory":"1Ki"}},{"usage":"x"},{"usage":{"memory":"bad"}},{"name":"no-usage"}]},
          {"metadata":{"name":"empty","namespace":"a"},"containers":[]}
        ]}
        """#
        #expect(KubernetesParser.parsePodMetrics(Data(json.utf8)) == [
            PodMetrics(namespace: "default", name: "no-ns", cpuMillicores: 250, memUsedBytes: nil),
            PodMetrics(namespace: "a", name: "mixed", cpuMillicores: 1, memUsedBytes: 1024),
            PodMetrics(namespace: "a", name: "empty", cpuMillicores: nil, memUsedBytes: nil),
        ])
    }

    @Test("quantities", arguments: [
        ("0", 0), ("1", 1), ("2.5", 2.5), ("250m", 0.25), ("2367103n", 0.002367103), ("100u", 0.0001),
        ("1k", 1_000), ("1M", 1_000_000), ("1G", 1e9), ("1T", 1e12), ("1P", 1e15), ("1E", 1e18),
        ("1Ki", 1_024), ("14304Ki", 14_647_296), ("64Mi", 67_108_864), ("1.5Gi", 1_610_612_736), ("1Ti", 1_099_511_627_776),
        ("1e3", 1_000), ("1E3", 1_000), ("5e-3", 0.005), ("+3", 3), (" 7Mi ", 7_340_032),
    ] as [(String, Double)])
    func quantity(text: String, expected: Double) throws {
        let value = try #require(KubernetesParser.parseQuantity(text))
        #expect(abs(value - expected) <= expected * 1e-12)
    }

    @Test("quantities that are not", arguments: ["", "-1", "-250m", "m", "Ki", "1x", "1KI", "1kb", "1.2.3", "1e", "1e999", "NaN", "inf", "1 Mi"])
    func badQuantity(text: String) {
        #expect(KubernetesParser.parseQuantity(text) == nil)
    }

    // MARK: - Events

    @Test("crasher events: counts, times and sources")
    func crasherEvents() throws {
        let events = try KubernetesParser.parseEvents(try Fixtures.data("kubectl/events-crasher.json"))
        #expect(events.map(\.reason) == ["Scheduled", "Pulling", "Pulled", "Created", "Started", "Pulled", "BackOff"])
        #expect(events.map(\.count) == [1, 1, 1, 7, 7, 6, 9])
        #expect(events.map(\.source) == ["default-scheduler", "kubelet", "kubelet", "kubelet", "kubelet", "kubelet", "kubelet"])
        #expect(events.map(\.isWarning) == [false, false, false, false, false, false, true])

        let scheduled = events[0]
        #expect(scheduled.id == "b6452066-86a6-4b31-8f9a-fc93176c11f7")
        #expect(scheduled.message == "Successfully assigned demo/crasher-89b4b56b4-djl5b to aeroops-vm")
        // No first/lastTimestamp: eventTime is used for both.
        let scheduledAt = try #require(scheduled.firstSeen)
        #expect(abs(scheduledAt.timeIntervalSince1970 - (day + 6 * 3600 + 55 * 60 + 7.379521)) < 1e-5)
        #expect(scheduled.lastSeen == scheduled.firstSeen)

        let backOff = events[6]
        #expect(backOff.type == "Warning")
        #expect(backOff.firstSeen == time(6, 55, 36))
        #expect(backOff.lastSeen == time(7, 2, 30))
        #expect(backOff.message
            == "Back-off restarting failed container crasher in pod crasher-89b4b56b4-djl5b_demo(65ccbfde-66eb-403f-b5aa-5c346406712e)")
        #expect(backOff.age(now: time(7, 7, 30)) == "5m")
        #expect(events[3].firstSeen == time(6, 55, 28))
        #expect(events[3].lastSeen == time(7, 1, 14))
    }

    @Test("pending events: FailedScheduling with eventTime only")
    func pendingEvents() throws {
        let events = try KubernetesParser.parseEvents(try Fixtures.data("kubectl/events-pending.json"))
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.reason == "FailedScheduling" && $0.isWarning && $0.count == 1 })
        #expect(events.allSatisfy { $0.source == "default-scheduler" })
        #expect(events[0].message.hasPrefix("0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector."))
        let first = try #require(events[0].lastSeen)
        let second = try #require(events[1].lastSeen)
        #expect(abs(first.timeIntervalSince1970 - (day + 6 * 3600 + 55 * 60 + 6.048068)) < 1e-5)
        #expect(abs(second.timeIntervalSince1970 - (day + 7 * 3600 + 33.663307)) < 1e-5)
    }

    @Test("events: series fallback, sorting by last seen, missing fields")
    func eventVariants() throws {
        let json = #"""
        {"items":[
          {"metadata":{"name":"late"},"reason":"B","series":{"count":4,"lastObservedTime":"2026-10-11T08:00:00.5Z"},
           "eventTime":"2026-10-11T07:00:00Z","reportingComponent":"kubelet"},
          {"reason":"A","lastTimestamp":"2026-10-11T07:30:00Z","count":0,"source":{"component":""},"type":"warning"},
          {"reason":"C"},
          "junk"
        ]}
        """#
        let events = try KubernetesParser.parseEvents(json)
        #expect(events.map(\.reason) == ["C", "A", "B"])
        #expect(events[0].id == "2")
        #expect(events[0].type == "Normal")
        #expect(events[0].lastSeen == nil)
        #expect(events[1].id == "1")
        #expect(events[1].count == 1)
        #expect(events[1].isWarning)
        #expect(events[1].source == nil)
        #expect(events[2].id == "late")
        #expect(events[2].count == 4)
        #expect(events[2].firstSeen == time(7, 0, 0))
        #expect(events[2].lastSeen == time(8, 0, 0.5))
        #expect(events[2].source == "kubelet")
    }

    // MARK: - Errors

    @Test("kubeconfig unreadable (k3s warning plus error)")
    func kubeconfigUnreadable() throws {
        let text = try Fixtures.string("kubectl/error-kubeconfig-unreadable.txt")
        let error = KubectlError.classify(text)
        #expect(error == .kubeconfigUnreadable(path: "/etc/rancher/k3s/k3s.yaml"))
        #expect(error.hint?.contains("sudo -n k3s kubectl") == true)
        #expect(error.errorDescription == "Cannot read the kubeconfig (/etc/rancher/k3s/k3s.yaml).")
        // As stdout of a parse, the same text becomes the same error, not invalidOutput.
        #expect(throws: KubectlError.kubeconfigUnreadable(path: "/etc/rancher/k3s/k3s.yaml")) {
            try KubernetesParser.parsePods(text)
        }
        // Only the warning line still identifies the path.
        let warningOnly = String(text.split(separator: "\n")[0])
        #expect(KubectlError.classify(warningOnly) == .kubeconfigUnreadable(path: "/etc/rancher/k3s/k3s.yaml"))
    }

    @Test("sudo refused")
    func sudoRefused() throws {
        let error = KubectlError.classify(try Fixtures.string("kubectl/error-sudo-not-allowed.txt"))
        #expect(error == .sudoRefused)
        #expect(error.hint?.contains("NOPASSWD") == true)
        #expect(KubectlError.classify("Sorry, user dev is not allowed to execute '/usr/local/bin/k3s kubectl get pods' as root on vm.")
            == .sudoRefused)
    }

    @Test("no previous container")
    func noPreviousContainer() throws {
        let error = KubectlError.classify(try Fixtures.string("kubectl/error-no-previous-container.txt"))
        #expect(error == .noPreviousContainer(container: "nginx", pod: "web-7b56d94874-b8t9q"))
        #expect(error.errorDescription == "No previous instance of container \"nginx\" in pod \"web-7b56d94874-b8t9q\".")
        #expect(error.hint != nil)
    }

    @Test("other kubectl errors and invalid output")
    func otherErrors() {
        #expect(KubectlError.classify("The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?")
            == .connectionRefused(server: "127.0.0.1:6443"))
        #expect(KubectlError.classify("sh: kubectl: not found") == .notInstalled)
        #expect(KubectlError.classify("sudo: k3s: command not found") == .notInstalled)
        #expect(KubectlError.classify("error: the server doesn't have a resource type \"podz\"\n[exit status 1]")
            == .failed(message: "error: the server doesn't have a resource type \"podz\""))
        #expect(throws: KubectlError.invalidOutput) { try KubernetesParser.parsePods("") }
        #expect(throws: KubectlError.invalidOutput) { try KubernetesParser.parsePods("No resources found") }
        #expect(throws: KubectlError.invalidOutput) { try KubernetesParser.parseEvents("[1, 2, 3]") }
        #expect(throws: KubectlError.sudoRefused) { try KubernetesParser.parseEvents("sudo: a password is required") }
        #expect(KubectlError.invalidOutput.hint != nil)
        #expect(KubectlError.failed(message: "").errorDescription == "The kubectl command failed.")
    }

    @Test("the other kubectl text fixtures are plain text")
    func textFixtures() throws {
        for name in ["logs-crasher-previous", "logs-web-log-sidecar", "describe-crasher"] {
            let text = try Fixtures.string("kubectl/\(name).txt")
            #expect(LogText.stripANSI(text) == text, "\(name)")
        }
        let previous = try Fixtures.string("kubectl/logs-crasher-previous.txt")
        #expect(LogText.capLines(previous, maxLines: 1).text
            == "2026-10-11T04:01:17.695760787-03:00 FATAL: connection refused (db.demo.svc:5432)\n")
        #expect(LogText.capLines(try Fixtures.string("kubectl/logs-web-log-sidecar.txt")).truncated == false)
        let describe = try Fixtures.string("kubectl/describe-crasher.txt")
        let head = LogText.capLines(describe, maxLines: 10, keep: .head)
        #expect(head.truncated)
        #expect(head.text.split(separator: "\n", omittingEmptySubsequences: false).count == 11)
        #expect(describe.hasPrefix(head.text))
    }
}
