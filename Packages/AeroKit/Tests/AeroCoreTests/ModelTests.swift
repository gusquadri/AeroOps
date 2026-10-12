import Foundation
import Testing
import AeroCore

@Suite("Model decoding")
struct ModelTests {
    let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    @Test("RemoteHost round-trips through JSON")
    func hostRoundTrip() throws {
        let host = RemoteHost(
            id: id, name: "web-01", address: "10.0.0.12", port: 2222, user: "deploy",
            keyId: "key-1", auth: .password, tags: ["prod", "eu"], kubectlPrefix: "sudo -n k3s kubectl",
            dockerSudo: true, mcpTier: .readExec
        )
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: JSONEncoder().encode(host))
        #expect(decoded == host)
    }

    @Test("RemoteHost defaults missing optional fields and ignores unknown ones")
    func hostTolerantDecoding() throws {
        let json = """
        {"id":"\(id.uuidString)","name":"db","address":"db.local","user":"root",
         "futureField":{"nested":[1,2,3]},"anotherOne":true}
        """
        let host = try JSONDecoder().decode(RemoteHost.self, from: Data(json.utf8))
        #expect(host.id == id)
        #expect(host.port == 22)
        #expect(host.keyId == nil)
        #expect(host.auth == .key)
        #expect(host.tags.isEmpty)
        #expect(host.kubectlPrefix == nil)
        #expect(host.dockerSudo == false)
        #expect(host.mcpTier == .read)
    }

    @Test("RemoteHost requires id, name, address and user", arguments: ["id", "name", "address", "user"])
    func hostRequiredFields(_ missing: String) throws {
        var object: [String: String] = [
            "id": id.uuidString, "name": "n", "address": "a", "user": "u",
        ]
        object[missing] = nil
        let data = try JSONEncoder().encode(object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RemoteHost.self, from: data) }
    }

    @Test("MCPTier defaults to read, unknown values fail closed to off")
    func mcpTier() throws {
        #expect(MCPTier.default == .read)
        #expect(RemoteHost(name: "n", address: "a", user: "u").mcpTier == .read)
        let decode = { (raw: String) in try JSONDecoder().decode(MCPTier.self, from: Data("\"\(raw)\"".utf8)) }
        #expect(try decode("readExec") == .readExec)
        #expect(try decode("off") == .off)
        #expect(try decode("sessions") == .off)
        #expect(try decode("READ") == .off)
    }

    @Test("HostAuthMethod defaults to key, unknown values fall back to key")
    func authMethod() throws {
        #expect(RemoteHost(name: "n", address: "a", user: "u").auth == .key)
        let decode = { (raw: String) in try JSONDecoder().decode(HostAuthMethod.self, from: Data("\"\(raw)\"".utf8)) }
        #expect(try decode("password") == .password)
        #expect(try decode("key") == .key)
        #expect(try decode("keyboard-interactive") == .key)
        #expect(try decode("PASSWORD") == .key)
        let json = try String(decoding: JSONEncoder().encode(RemoteHost(name: "n", address: "a", user: "u", auth: .password)), as: UTF8.self)
        #expect(json.contains(#""auth":"password""#))
    }

    @Test("Container state and pod phase decode unknown strings tolerantly")
    func tolerantEnums() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ContainerState.self, from: Data(#""running""#.utf8)) == .running)
        #expect(try decoder.decode(ContainerState.self, from: Data(#""zombie""#.utf8)) == .unknown)
        #expect(ContainerState(dockerState: "Exited") == .exited)
        #expect(try decoder.decode(PodPhase.self, from: Data(#""Running""#.utf8)) == .running)
        #expect(try decoder.decode(PodPhase.self, from: Data(#""Evicted""#.utf8)) == .unknown)
    }

    @Test("PodInfo derives ready x/y and restarts")
    func podDerived() {
        let pod = PodInfo(namespace: "default", name: "api", phase: .running, containers: [
            .init(name: "app", ready: true, restartCount: 3),
            .init(name: "sidecar", ready: false, restartCount: 2, waitingReason: "CrashLoopBackOff"),
        ])
        #expect(pod.id == "default/api")
        #expect(pod.readyCount == 1)
        #expect(pod.containerCount == 2)
        #expect(pod.restarts == 5)
    }

    @Test("MetricsSnapshot fractions and root disk")
    func metricsDerived() throws {
        let snapshot = MetricsSnapshot(
            cpuPercent: nil, memUsedBytes: 1_000, memTotalBytes: 4_000,
            disks: [
                DiskUsage(mount: "/", device: "/dev/sda1", usedBytes: 50, totalBytes: 200),
                DiskUsage(mount: "/boot", device: "/dev/sda2", usedBytes: 1, totalBytes: 0),
            ],
            uptimeSeconds: 12.5, load1: 0.1, load5: 0.2, load15: 0.3,
            hostname: "web", kernel: "Linux 6.8.0 x86_64", sampledAt: Date(timeIntervalSince1970: 0)
        )
        #expect(snapshot.memUsedFraction == 0.25)
        #expect(snapshot.disk()?.usedFraction == 0.25)
        #expect(snapshot.disk(mountedAt: "/boot")?.usedFraction == nil)
        let decoded = try JSONDecoder().decode(MetricsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(snapshot.swapUsedFraction == nil)
    }

    @Test("MetricsSnapshot swap: fraction, no swap, and JSON without swap fields")
    func metricsSwap() throws {
        var snapshot = MetricsSnapshot(
            cpuPercent: 12, memUsedBytes: 1, memTotalBytes: 2, disks: [],
            uptimeSeconds: 1, load1: 0, load5: 0, load15: 0, hostname: "h", kernel: "Linux",
            sampledAt: Date(timeIntervalSince1970: 0), swapTotalBytes: 400, swapUsedBytes: 100
        )
        #expect(snapshot.swapUsedFraction == 0.25)
        let roundTrip = try JSONDecoder().decode(MetricsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(roundTrip == snapshot)
        snapshot.swapTotalBytes = 0
        snapshot.swapUsedBytes = 0
        #expect(snapshot.swapUsedFraction == nil)

        // Snapshots encoded before the swap fields existed still decode.
        let json = #"{"cpuPercent":5,"memUsedBytes":1,"memTotalBytes":2,"disks":[],"uptimeSeconds":1,"load1":0,"load5":0,"load15":0,"hostname":"h","kernel":"Linux","sampledAt":0}"#
        let old = try JSONDecoder().decode(MetricsSnapshot.self, from: Data(json.utf8))
        #expect(old.swapTotalBytes == nil)
        #expect(old.swapUsedBytes == nil)
        #expect(old.cpuPercent == 5)
    }

    @Test("LogRequest clamps tail, defaults fields and validates names")
    func logRequest() throws {
        var request = LogRequest(hostId: id, kind: .pod, name: "api-7f9", namespace: "prod", tail: 10_000)
        #expect(request.tail == LogRequest.maxTail)
        request.tail = 0
        #expect(request.tail == 1)
        #expect(request.isValid)
        #expect(!LogRequest(hostId: id, kind: .container, name: "x; rm -rf /").isValid)
        #expect(!LogRequest(hostId: id, kind: .pod, name: "ok", namespace: "$(id)").isValid)
        #expect(!LogRequest(hostId: id, kind: .pod, name: "ok", container: "-c").isValid)
        #expect(!LogRequest(hostId: id, kind: .container, name: "ok", sinceSeconds: 0).isValid)

        let json = #"{"hostId":"\#(id.uuidString)","kind":"container","name":"web","tail":99999,"extra":1}"#
        let decoded = try JSONDecoder().decode(LogRequest.self, from: Data(json.utf8))
        #expect(decoded.tail == LogRequest.maxTail)
        #expect(decoded.follow == false)
        #expect(decoded.previous == false)
        #expect(decoded.namespace == nil)
    }

    @Test("AeroPaths follow the plan's runtime layout")
    func paths() {
        let paths = AeroPaths(home: URL(fileURLWithPath: "/Users/test"))
        #expect(paths.agentSocket.path == "/Users/test/.aeroops/agent.sock")
        #expect(paths.askpassSocket.path == "/Users/test/.aeroops/askpass.sock")
        #expect(paths.bridgeSocket.path == "/Users/test/.aeroops/bridge.sock")
        #expect(paths.controlMasterDirectory.path == "/Users/test/.aeroops/cm")
        #expect(paths.sshConfig.path == "/Users/test/.aeroops/ssh_config")
        #expect(paths.knownHosts.path == "/Users/test/.aeroops/known_hosts")
        #expect(paths.publicKeysDirectory.path == "/Users/test/.aeroops/pub")
        #expect(paths.hostsFile.path == "/Users/test/Library/Application Support/AeroOps/hosts.json")
        #expect(paths.auditLog.path == "/Users/test/Library/Application Support/AeroOps/audit.jsonl")
        // Socket paths must stay well under the 104-byte sun_path limit for typical home dirs.
        #expect(paths.bridgeSocket.path.utf8.count < 104)
    }
}
