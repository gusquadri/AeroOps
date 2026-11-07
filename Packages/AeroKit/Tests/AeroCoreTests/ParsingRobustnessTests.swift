import Foundation
import Testing
import AeroCore
import AeroTestSupport

@Suite("Timestamps and age")
struct TimestampTests {
    /// 2026-10-11T00:00:00Z.
    private let day = 1_791_676_800.0

    @Test("RFC 3339 as printed by Kubernetes and Docker")
    func rfc3339() throws {
        #expect(Timestamps.parseRFC3339("2026-10-11T06:55:06Z") == Date(timeIntervalSince1970: day + 24_906))
        #expect(Timestamps.parseRFC3339("2026-10-11t06:55:06z") == Date(timeIntervalSince1970: day + 24_906))
        #expect(Timestamps.parseRFC3339("2026-10-11 06:55:06Z") == Date(timeIntervalSince1970: day + 24_906))
        #expect(Timestamps.parseRFC3339(" 2026-10-11T03:55:06-03:00 ") == Date(timeIntervalSince1970: day + 24_906))
        #expect(Timestamps.parseRFC3339("2026-10-11T12:25:06+05:30") == Date(timeIntervalSince1970: day + 24_906))
        #expect(Timestamps.parseRFC3339("2026-10-11T12:25:06+0530") == Date(timeIntervalSince1970: day + 24_906))
        let nanos = try #require(Timestamps.parseRFC3339("2026-10-11T04:01:14.694177452-03:00"))
        #expect(abs(nanos.timeIntervalSince1970 - (day + 25_274.694177452)) < 1e-5)
        #expect(Timestamps.parseRFC3339("2000-02-29T00:00:00Z") == Date(timeIntervalSince1970: 951_782_400))
        #expect(Timestamps.parseRFC3339("1969-12-31T23:59:59Z") == Date(timeIntervalSince1970: -1))
        #expect(Timestamps.parseRFC3339("0001-01-01T00:00:00Z") == Date(timeIntervalSince1970: -62_135_596_800))
        #expect(Timestamps.parseRFC3339("2016-12-31T23:59:60Z") == Date(timeIntervalSince1970: 1_483_228_799))
    }

    @Test("invalid RFC 3339 strings are nil")
    func rfc3339Invalid() {
        for text in [
            "", "Z", "2026-10-11", "2026-10-11T06:55:06", "2026-10-11T06:55:06Zjunk", "2026-10-11T06:55Z",
            "2001-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z", "2026-10-32T00:00:00Z",
            "2026-10-11T24:00:00Z", "2026-10-11T23:60:00Z", "2026-10-11T06:55:06+24:00", "2026-10-11T06:55:06+5",
            "２０２６-10-11T06:55:06Z", "2026-1O-11T06:55:06Z", "+2026-10-11T06:55:06Z", "null",
        ] {
            #expect(Timestamps.parseRFC3339(text) == nil, "\(text)")
        }
    }

    @Test("Docker CreatedAt")
    func dockerCreatedAt() {
        let expected = Date(timeIntervalSince1970: day + 24_930)
        #expect(Timestamps.parseDockerCreatedAt("2026-10-11 03:55:30 -0300 -03") == expected)
        #expect(Timestamps.parseDockerCreatedAt("2026-10-11 03:55:30 -0300 BRT") == expected)
        #expect(Timestamps.parseDockerCreatedAt("2026-10-11 06:55:30 +0000 UTC") == expected)
        #expect(Timestamps.parseDockerCreatedAt("2026-10-11 06:55:30 +0000") == expected)
        #expect(Timestamps.parseDockerCreatedAt("2026-10-11T06:55:30Z") == nil)
        #expect(Timestamps.parseDockerCreatedAt("2026-10-11 06:55:30") == nil)
        #expect(Timestamps.parseDockerCreatedAt("2026-10-11 06:55:30 UTC") == nil)
        #expect(Timestamps.parseDockerCreatedAt("7 minutes ago") == nil)
    }

    @Test("short age strings")
    func age() {
        #expect(AgeFormat.short(0) == "0s")
        #expect(AgeFormat.short(-30) == "0s")
        #expect(AgeFormat.short(.nan) == "0s")
        #expect(AgeFormat.short(.infinity) == "0s")
        #expect(AgeFormat.short(45.9) == "45s")
        #expect(AgeFormat.short(60) == "1m")
        #expect(AgeFormat.short(5 * 60 + 59) == "5m")
        #expect(AgeFormat.short(3_599) == "59m")
        #expect(AgeFormat.short(3_600) == "1h")
        #expect(AgeFormat.short(3 * 3_600 + 1_799) == "3h")
        #expect(AgeFormat.short(86_399) == "23h")
        #expect(AgeFormat.short(86_400) == "1d")
        #expect(AgeFormat.short(2 * 86_400 + 7_200) == "2d")
        #expect(AgeFormat.short(729 * 86_400) == "729d")
        #expect(AgeFormat.short(730 * 86_400) == "2y")
        #expect(AgeFormat.short(1e300).hasSuffix("y"))
        let created = Date(timeIntervalSince1970: day)
        #expect(AgeFormat.short(since: created, now: Date(timeIntervalSince1970: day + 300)) == "5m")
        #expect(AgeFormat.short(since: created, now: Date(timeIntervalSince1970: day - 300)) == "0s")
    }
}

@Suite("Hostile input")
struct ParsingRobustnessTests {
    /// Deterministic 64-bit LCG (Knuth's MMIX constants), so failures reproduce.
    private struct LCG {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }

        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    }

    /// Fragments that look like real output, so random strings reach deep into the parsers.
    private static let fragments: [String] = [
        "@@stat\n", "@@cpus\n", "@@mem\n", "@@uptime\n", "@@load\n", "@@df\n", "@@host\n", "@@end\n", "@@\n",
        "cpu ", "cpu  1 2 3 4 5 6 7 8\n", "MemTotal:", "MemAvailable:", " kB\n", "Filesystem 1024-blocks Used\n",
        "/dev/sda1 ", "100%", "-", " / ", "\n", "\r\n", "\r", "\t", " ", "0", "18446744073709551616", "-1",
        "9223372036854775807", "1e309", "nan", "{", "}", "[", "]", "\"", ":", ",", "null", "true",
        "{\"ID\":", "{\"items\":[", "{\"metadata\":{\"name\":", "\"State\":", "\"status\":{\"phase\":",
        "\"containerStatuses\":[{\"name\":\"c\",\"state\":{\"terminated\":{\"exitCode\":",
        "\u{1B}", "\u{1B}[", "\u{1B}]", "\u{1B}P", "\u{1B}\\", "\u{07}", "\u{9B}", "\u{9C}", "\u{9D}", "\u{0}",
        "\u{7F}", "é", "日本", "👍🏽", "\u{301}", "\u{FEFF}", "\u{FFFD}", "%", "(", ")", "->", "KiB", "GiB", "/",
        "docker", "kubectl", "k3s", "docker-ok", "permission denied", "sudo: a password is required",
        "\"Name\":", "2026-10-11T06:55:06Z", "2026-10-11 03:55:30 -0300 -03", "Exited (", "Up 1 second (healthy)",
    ]

    private static let fixtureNames = [
        "metrics/ubuntu-vm-1.txt", "metrics/ubuntu-vm-2.txt", "metrics/debian-1.txt", "metrics/debian-2.txt",
        "metrics/devcontainer-1.txt", "metrics/devcontainer-2.txt", "metrics/alpine-busybox-1.txt",
        "metrics/alpine-busybox-2.txt", "metrics/nonlinux-darwin.txt", "metrics/nonlinux-darwin.stderr.txt",
        "metrics/synthetic-oldkernel-no-memavailable.txt",
        "probe/vm-dev.txt", "probe/vm-nodocker.txt", "probe/vm-root.txt", "probe/devcontainer.txt",
        "probe/alpine-busybox.txt",
        "docker/ps-a.jsonl", "docker/ps-a-via-sudo.jsonl", "docker/stats.jsonl", "docker/inspect-demo-web.json",
        "docker/error-permission-denied.txt", "docker/logs-demo-logger.txt", "docker/logs-demo-exited.txt",
        "kubectl/pods-all.json", "kubectl/events-crasher.json", "kubectl/events-pending.json",
        "kubectl/error-kubeconfig-unreadable.txt", "kubectl/error-sudo-not-allowed.txt",
        "kubectl/error-no-previous-container.txt", "kubectl/logs-crasher-previous.txt",
        "kubectl/logs-web-log-sidecar.txt", "kubectl/describe-crasher.txt",
    ]

    /// Runs every parser on `text` and checks invariants that must hold for any input.
    private func exerciseAll(_ text: String) {
        let data = Data(text.utf8)

        let metrics = MetricsParser.parse(text, previous: MetricsSample(cpuTimes: CPUTimes(total: 10, idle: 5)))
        if !text.contains("@@end") { #expect(metrics == .truncated) }
        if let percent = metrics.snapshot?.cpuPercent { #expect((0...100).contains(percent)) }
        if let snapshot = metrics.snapshot {
            #expect(snapshot.memUsedBytes >= 0 && snapshot.memUsedBytes <= snapshot.memTotalBytes)
        }
        for disk in MetricsParser.parseDF(text) {
            #expect(disk.usedBytes >= 0 && disk.totalBytes >= 0)
            if let fraction = disk.usedFraction { #expect((0...1).contains(fraction)) }
        }
        _ = HostCapabilities(probeOutput: text)

        _ = try? DockerParser.parseContainers(ps: text, stats: text)
        _ = DockerParser.parseStats(text)
        _ = DockerParser.parseInspect(data)
        _ = DockerError.classify(text).hint
        _ = try? KubernetesParser.parsePods(data)
        _ = try? KubernetesParser.parseEvents(data)
        _ = KubectlError.classify(text).errorDescription
        _ = Timestamps.parseRFC3339(text)
        _ = Timestamps.parseDockerCreatedAt(text)

        let clean = LogText.stripANSI(text)
        #expect(!clean.unicodeScalars.contains {
            ($0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0A) || (0x7F...0x9F).contains($0.value)
        })
        let lines = LogText.capLines(text, maxLines: 3)
        #expect(lines.text.utf8.count(where: { $0 == UInt8(ascii: "\n") }) <= 3)
        for keep in [LogText.Keep.head, .tail] {
            let bytes = LogText.capBytes(text, maxBytes: 7, keep: keep)
            #expect(bytes.text.utf8.count <= 7)
            #expect(bytes.truncated == (text.utf8.count > 7))
        }
        #expect(LogText.prepare(text, maxLines: 5, maxBytes: 64).text.utf8.count <= 64)
    }

    @Test("random fragment soup does not crash any parser")
    func fragmentSoup() {
        var rng = LCG(state: 0xAE20_0000_C0FF_EE00)
        for _ in 0..<400 {
            let count = Int(rng.next() % 60)
            let text = (0..<count).map { _ in rng.pick(Self.fragments) }.joined()
            exerciseAll(text)
        }
    }

    @Test("random bytes (invalid UTF-8 replaced) do not crash any parser")
    func randomBytes() {
        var rng = LCG(state: 42)
        for _ in 0..<200 {
            let bytes = (0..<Int(rng.next() % 300)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            exerciseAll(String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test("every fixture cut at many points, and with bytes flipped, does not crash")
    func mutatedFixtures() throws {
        var rng = LCG(state: 7)
        for name in Self.fixtureNames {
            let original = try Fixtures.data(name)
            exerciseAll(String(decoding: original, as: UTF8.self))
            let step = max(1, original.count / 25)
            for cut in stride(from: 0, to: original.count, by: step) {
                exerciseAll(String(decoding: original.prefix(cut), as: UTF8.self))
            }
            for _ in 0..<10 where !original.isEmpty {
                var mutated = original
                for _ in 0..<4 {
                    let index = Int(rng.next() % UInt64(mutated.count))
                    mutated[index] = UInt8(truncatingIfNeeded: rng.next())
                }
                exerciseAll(String(decoding: mutated, as: UTF8.self))
            }
        }
    }

    @Test("huge numbers are rejected, not wrapped")
    func hugeNumbers() {
        let output = """
        @@stat
        cpu 18446744073709551615 18446744073709551615 0 0
        @@mem
        MemTotal: 9223372036854775807 kB
        MemAvailable: 1 kB
        @@df
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/huge 99999999999999999999 1 1 1% /
        /dev/big 9223372036854775807 1 1 1% /big
        /dev/ok 10 5 5 50% /ok
        @@end
        """
        let result = MetricsParser.parse(output)
        #expect(result == .unsupportedOS(MetricsSample(
            disks: [DiskUsage(mount: "/ok", device: "/dev/ok", usedBytes: 5_120, totalBytes: 10_240, availableBytes: 5_120)]
        )))
        #expect(DockerParser.parseByteSize("99999999999999TiB") == nil)
        #expect(DockerParser.parsePercent("1e999%") == nil)
    }

    @Test("deeply nested and wrongly typed JSON")
    func hostileJSON() throws {
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(throws: KubectlError.invalidOutput) { try KubernetesParser.parsePods(deep) }
        #expect(DockerParser.parseInspect(Data(deep.utf8)).isEmpty)
        #expect(throws: KubectlError.invalidOutput) { try KubernetesParser.parsePods(#"{"items":{"not":"an array"}}"#) }
        #expect(throws: KubectlError.invalidOutput) { try KubernetesParser.parseEvents(#"{"items":"x"}"#) }
        #expect(try KubernetesParser.parsePods(#"{"items":[[],{},"",1.5,{"metadata":[]}]}"#).isEmpty)
        #expect(DockerParser.parseStats(#"{"Name":["x"],"CPUPerc":5,"MemUsage":{}}"#).isEmpty)
        #expect(throws: DockerError.self) { try DockerParser.parseContainers(ps: #"{"ID":5,"Names":[]}"#) }
    }

    @Test("shell metacharacters in remote names stay inert data")
    func parsersAreText() throws {
        let ps = #"{"ID":"x","Names":"$(rm -rf ~);`id`|'\"","State":"running","Status":"Up"}"#
        let row = try #require(try DockerParser.parseContainers(ps: ps).first)
        #expect(row.name == #"$(rm -rf ~);`id`|'""#)
    }
}
