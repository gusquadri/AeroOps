import Foundation
import Testing
import AeroCore
import AeroTestSupport

@Suite("MetricsParser")
struct MetricsParserTests {
    private let kib: Int64 = 1024

    private func parse(_ name: String, previous: MetricsSample? = nil) throws -> MetricsParseResult {
        MetricsParser.parse(try Fixtures.string("metrics/\(name).txt"), previous: previous,
                            sampledAt: Date(timeIntervalSince1970: 1_000))
    }

    private func success(_ name: String, previous: MetricsSample? = nil) throws -> (MetricsSnapshot, MetricsSample) {
        try #require(try parse(name, previous: previous).successPair, "expected success for \(name)")
    }

    @Test("ubuntu VM sample 1: every section, first sample has no CPU %")
    func ubuntuFirstSample() throws {
        let (snapshot, sample) = try success("ubuntu-vm-1")
        #expect(snapshot.cpuPercent == nil)
        #expect(sample.cpuTimes == CPUTimes(total: 726_203_233, idle: 717_171_148))
        #expect(sample.cpuTimes?.busy == 9_032_085)
        #expect(snapshot.cpuCount == 10)
        #expect(snapshot.memTotalBytes == 3_052_020 * kib)
        #expect(snapshot.memUsedBytes == (3_052_020 - 1_509_780) * kib)
        #expect(snapshot.memUsedBytes == 1_579_253_760)
        #expect(sample.memory?.availableIsEstimate == false)
        #expect(sample.memory?.swapTotalBytes == 4_100_588 * kib)
        #expect(sample.memory?.swapFreeBytes == 3_557_896 * kib)
        #expect(snapshot.swapTotalBytes == 4_100_588 * kib)
        #expect(snapshot.swapUsedBytes == (4_100_588 - 3_557_896) * kib)
        #expect(snapshot.uptimeSeconds == 727_305.64)
        #expect(snapshot.load1 == 1.80)
        #expect(snapshot.load5 == 2.20)
        #expect(snapshot.load15 == 2.90)
        #expect(snapshot.kernel == "Linux 7.0.14-orbstack-00380-ga7e0a2dc9535 aarch64")
        #expect(snapshot.hostname == "aeroops-vm")
        #expect(snapshot.sampledAt == Date(timeIntervalSince1970: 1_000))
        #expect(snapshot.disks == [
            DiskUsage(mount: "/", device: "/dev/vdb1", usedBytes: 22_392_144 * kib,
                      totalBytes: 51_904_512 * kib, availableBytes: 29_512_368 * kib),
        ])
        let root = try #require(snapshot.cardDisk())
        #expect(abs(try #require(root.usedFraction) - 22_392_144.0 / 51_904_512.0) < 1e-12)
    }

    @Test("ubuntu VM: CPU % is the busy share of the delta between samples 1 and 2")
    func ubuntuCPUDelta() throws {
        let (_, first) = try success("ubuntu-vm-1")
        let (snapshot, second) = try success("ubuntu-vm-2", previous: first)
        #expect(second.cpuTimes == CPUTimes(total: 726_205_398, idle: 717_173_271))
        let percent = try #require(snapshot.cpuPercent)
        #expect(abs(percent - 42.0 / 2165.0 * 100) < 1e-9)
        #expect(snapshot.memUsedBytes == (3_052_020 - 1_516_580) * kib)
        #expect(snapshot.uptimeSeconds == 727_307.81)
    }

    @Test("CPU deltas for the other -1/-2 pairs, iowait counted as idle")
    func otherCPUDeltas() throws {
        let pairs: [(String, Double)] = [
            ("debian", 75.0 / 2118.0 * 100),
            ("devcontainer", 62.0 / 2111.0 * 100),
            ("alpine-busybox", 76.0 / 2239.0 * 100),
        ]
        for (name, expected) in pairs {
            let (_, first) = try success("\(name)-1")
            let (snapshot, _) = try success("\(name)-2", previous: first)
            let percent = try #require(snapshot.cpuPercent, "\(name)")
            #expect(abs(percent - expected) < 1e-9, "\(name)")
        }
    }

    @Test("CPU % is nil when counters go backwards (reboot) or do not move")
    func cpuCountersBackwards() throws {
        let (_, newer) = try success("ubuntu-vm-2")
        let (snapshot, _) = try success("ubuntu-vm-1", previous: newer)
        #expect(snapshot.cpuPercent == nil)
        let (same, _) = try success("ubuntu-vm-1", previous: try success("ubuntu-vm-1").1)
        #expect(same.cpuPercent == nil)
    }

    @Test("debian: overlay root plus a bind-mounted file")
    func debian() throws {
        let (snapshot, _) = try success("debian-1")
        #expect(snapshot.hostname == "debian-fixture")
        #expect(snapshot.load1 == 1.65)
        #expect(snapshot.load5 == 2.17)
        #expect(snapshot.load15 == 2.89)
        #expect(snapshot.memUsedBytes == (3_052_020 - 1_521_008) * kib)
        #expect(snapshot.disks.map(\.mount) == ["/", "/etc/hosts"])
        #expect(snapshot.disks.map(\.device) == ["overlay", "/dev/vdb1"])
        #expect(snapshot.disks[0].usedBytes == 22_392_116 * kib)
        #expect(snapshot.disks[0].availableBytes == 29_512_396 * kib)
    }

    @Test("devcontainer: three devices, pinned mount helper")
    func devcontainer() throws {
        let (snapshot, _) = try success("devcontainer-1")
        #expect(snapshot.hostname == "aeroops-dev")
        #expect(snapshot.memUsedBytes == (3_052_020 - 1_516_064) * kib)
        #expect(snapshot.disks.map(\.mount) == ["/", "/pubkeys", "/config"])
        #expect(snapshot.disks.map(\.device) == ["overlay", "mac", "/dev/vdb1"])
        let pubkeys = try #require(snapshot.disk(mountedAt: "/pubkeys"))
        #expect(pubkeys.totalBytes == 976_629_760 * kib)
        #expect(pubkeys.usedBytes == 120_183_496 * kib)
        #expect(pubkeys.availableBytes == 856_446_264 * kib)

        #expect(snapshot.cardDisk()?.mount == "/")
        #expect(snapshot.cardDisk(pinnedMount: "/pubkeys") == pubkeys)
        #expect(snapshot.cardDisk(pinnedMount: "/gone")?.mount == "/")
    }

    @Test("alpine BusyBox: df quirks and de-duplication by device")
    func alpineBusybox() throws {
        let (snapshot, _) = try success("alpine-busybox-1")
        #expect(snapshot.hostname == "aeroops-alpine")
        #expect(snapshot.memUsedBytes == (3_052_020 - 1_523_764) * kib)
        #expect(snapshot.disks.map(\.mount) == ["/", "/dev", "/dev/shm", "/pubkeys", "/etc/resolv.conf"])
        #expect(snapshot.disks.map(\.device) == ["overlay", "tmpfs", "shm", "mac", "/dev/vdb1"])
        #expect(snapshot.disks[1] == DiskUsage(mount: "/dev", device: "tmpfs", usedBytes: 0,
                                               totalBytes: 65_536 * kib, availableBytes: 65_536 * kib))
        #expect(snapshot.disks[1].usedFraction == 0)
        #expect(snapshot.disks[2].totalBytes == 1_525_760 * kib)
        #expect(snapshot.disks[3].usedBytes == 120_177_432 * kib)
        #expect(snapshot.disks[3].availableBytes == 856_452_328 * kib)
    }

    @Test("old kernel without MemAvailable: MemFree + Buffers + Cached")
    func oldKernelFallback() throws {
        let (snapshot, sample) = try success("synthetic-oldkernel-no-memavailable")
        #expect(sample.memory?.availableIsEstimate == true)
        #expect(sample.memory?.availableBytes == (821_496 + 168 + 914_268) * kib)
        #expect(snapshot.memUsedBytes == 1_347_674_112)
        #expect(snapshot.memTotalBytes == 3_125_268_480)
        #expect(snapshot.kernel == "Linux 3.10.0-1160.el7.x86_64 x86_64")
        #expect(snapshot.hostname == "oldkernel-fixture")
    }

    @Test("darwin, script without the macOS branch: unsupported OS; host and df still parse")
    func darwinUnsupported() throws {
        let result = try parse("nonlinux-darwin")
        guard case .unsupportedOS(let sample) = result else {
            Issue.record("expected unsupportedOS, got \(result)")
            return
        }
        #expect(result.snapshot == nil)
        #expect(result.sample == sample)
        #expect(sample.cpuTimes == nil)
        #expect(sample.cpuCount == nil)
        #expect(sample.memory == nil)
        #expect(sample.uptimeSeconds == nil)
        #expect(sample.load == nil)
        #expect(sample.kernel == "Darwin 27.0.0 arm64")
        #expect(sample.hostname == "mac-fixture.local")

        #expect(sample.disks.count == 15)
        let root = sample.disks[0]
        #expect(root == DiskUsage(mount: "/", device: "/dev/disk3s1s1", usedBytes: 13_338_596 * kib,
                                  totalBytes: 239_362_496 * kib, availableBytes: 31_105_088 * kib))
        #expect(abs(try #require(root.usedFraction) - 13_338_596.0 / 44_443_684.0) < 1e-12)

        let autoHome = try #require(sample.disks.first { $0.mount == "/System/Volumes/Data/home" })
        #expect(autoHome.device == "map auto_home")
        #expect(autoHome.totalBytes == 0)
        #expect(autoHome.usedFraction == nil)
        let deviceFS = try #require(sample.disks.first { $0.mount == "/Users/dev/Library/Developer/CoreDevice/DeviceFS" })
        #expect(deviceFS.device
            == "devices -- file:///Users/dev/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/")
        #expect(deviceFS.totalBytes == 1_073_741_824 * kib)
        #expect(sample.disks.last == DiskUsage(mount: "/Users/dev/OrbStack", device: "OrbStack:/OrbStack",
                                               usedBytes: 22_392_100 * kib, totalBytes: 51_904_512 * kib,
                                               availableBytes: 29_512_412 * kib))
    }

    @Test("macOS: @@cpubusy is the CPU % of the first sample; memory, swap, uptime, load, df and os parse")
    func macOS() throws {
        let (snapshot, sample) = try success("macos-1")
        #expect(sample.cpuTimes == nil)
        #expect(sample.cpuBusyPercent == 16)
        #expect(snapshot.cpuPercent == 16)
        #expect(snapshot.cpuCount == 10)
        #expect(snapshot.memTotalBytes == 16_777_216 * kib)
        #expect(snapshot.memUsedBytes == (16_777_216 - 2_873_712) * kib)
        #expect(snapshot.swapTotalBytes == 8_388_608 * kib)
        #expect(snapshot.swapUsedBytes == (8_388_608 - 1_027_389) * kib)
        #expect(snapshot.uptimeSeconds == 367_248)
        #expect(snapshot.load1 == 2.76)
        #expect(snapshot.load15 == 4.76)
        #expect(snapshot.kernel == "Darwin 27.2.0 arm64")
        #expect(snapshot.hostname == "mac-fixture.local")
        #expect(snapshot.os == OSRelease(id: "macos", name: "macOS", versionID: "27.2"))
        #expect(snapshot.os?.displayName == "macOS 27.2")
        #expect(snapshot.disks.map(\.mount) == ["/", "/Volumes/ADATA"])
        #expect(snapshot.cardDisk() == DiskUsage(mount: "/", device: "/dev/disk3s1s1", usedBytes: 203_219_444 * kib,
                                                 totalBytes: 239_362_496 * kib, availableBytes: 36_143_052 * kib))
    }

    @Test("macOS: a later sample keeps its own @@cpubusy instead of a /proc/stat delta")
    func macOSSecondSample() throws {
        let (_, first) = try success("macos-1")
        let text = try Fixtures.string("metrics/macos-1.txt").replacingOccurrences(of: "@@cpubusy\n16\n", with: "@@cpubusy\n42\n")
        let snapshot = try #require(MetricsParser.parse(text, previous: first).snapshot)
        #expect(snapshot.cpuPercent == 42)
        #expect(MetricsParser.parse("@@cpubusy\n250\n@@end\n").snapshot?.cpuPercent == 100)
        #expect(MetricsParser.parse("@@cpubusy\n-3\n@@end\n") == .unsupportedOS(MetricsSample()))
    }

    @Test("darwin stderr fixture is only 'No such file' noise")
    func darwinStderr() throws {
        let stderr = try Fixtures.string("metrics/nonlinux-darwin.stderr.txt")
        let lines = stderr.split(whereSeparator: \.isNewline)
        #expect(lines.count == 5)
        #expect(lines.allSatisfy { $0.contains("No such file") })
    }

    @Test("missing @@end is truncated, whatever else is present")
    func truncated() throws {
        let full = try Fixtures.string("metrics/ubuntu-vm-1.txt")
        let cut = full.components(separatedBy: "@@end")[0]
        #expect(MetricsParser.parse(cut) == .truncated)
        #expect(MetricsParser.parse(String(full.prefix(40))) == .truncated)
        #expect(MetricsParser.parse("") == .truncated)
        #expect(MetricsParser.parse(cut).sample == nil)
        let darwin = try Fixtures.string("metrics/nonlinux-darwin.txt")
        #expect(MetricsParser.parse(darwin.components(separatedBy: "@@end")[0]) == .truncated)
    }

    @Test("only @@end is an unsupported OS with nothing known")
    func onlyEnd() {
        #expect(MetricsParser.parse("@@end\n") == .unsupportedOS(MetricsSample()))
    }

    @Test("banner before the first marker, CRLF, and text after @@end are ignored")
    func bannerAndCRLF() throws {
        let body = try Fixtures.string("metrics/ubuntu-vm-1.txt")
        let noisy = "Welcome to Ubuntu!\nLast login: yesterday\n"
            + body.replacingOccurrences(of: "\n", with: "\r\n")
            + "@@stat\ncpu 1 1 1 1\n"
        let (snapshot, sample) = try #require(MetricsParser.parse(noisy).successPair)
        #expect(sample.cpuTimes == CPUTimes(total: 726_203_233, idle: 717_171_148))
        #expect(snapshot.hostname == "aeroops-vm")
        #expect(snapshot.disks.count == 1)
    }

    @Test("a repeated section keeps the first copy")
    func repeatedSection() {
        let output = "@@stat\ncpu 10 0 10 80 0\n@@stat\ncpu 999 0 0 1 0\n@@host\nLinux\nbox\n@@end\n"
        let sample = MetricsParser.parse(output).sample
        #expect(sample?.cpuTimes == CPUTimes(total: 100, idle: 80))
        #expect(sample?.hostname == "box")
    }

    @Test("junk sections are unavailable (nil), not zero")
    func junkSections() {
        let output = """
        @@stat
        cpu 100 0 100 800
        @@cpus
        many
        @@mem
        MemTotal: lots kB
        @@uptime
        -5
        @@load
        1.0 two 3.0
        @@df
        not a df line
        @@end
        """
        let result = MetricsParser.parse(output)
        let sample = result.sample
        #expect(sample != nil)
        #expect(sample?.cpuTimes == CPUTimes(total: 1000, idle: 800))
        #expect(sample?.cpuCount == nil)
        #expect(sample?.memory == nil)
        #expect(sample?.uptimeSeconds == nil)
        #expect(sample?.load == nil)
        #expect(sample?.disks == [])
        #expect(sample?.kernel == nil)
        #expect(result.snapshot?.memTotalBytes == 0)
        #expect(result.snapshot?.memUsedFraction == nil)
    }

    @Test("cpu line parsing: old kernels, guest columns, junk")
    func cpuLine() {
        #expect(CPUTimes(statLine: "cpu 10 20 30 40") == CPUTimes(total: 100, idle: 40))
        #expect(CPUTimes(statLine: "cpu 1 2 3 4 5 6 7 8 1000 1000") == CPUTimes(total: 36, idle: 9))
        #expect(CPUTimes(statLine: "cpu0 1 2 3 4 5") == nil)
        #expect(CPUTimes(statLine: "cpu 1 2 3") == nil)
        #expect(CPUTimes(statLine: "cpu 1 2 -3 4") == nil)
        #expect(CPUTimes(statLine: "cpu 18446744073709551615 1 0 0") == nil)
        #expect(CPUTimes(statLine: "") == nil)
    }

    @Test("busyPercent clamps and rejects no-progress deltas")
    func busyPercent() {
        let a = CPUTimes(total: 100, idle: 50)
        #expect(CPUTimes.busyPercent(from: a, to: CPUTimes(total: 200, idle: 50)) == 100)
        #expect(CPUTimes.busyPercent(from: a, to: CPUTimes(total: 200, idle: 150)) == 0)
        #expect(CPUTimes.busyPercent(from: a, to: CPUTimes(total: 200, idle: 100)) == 50)
        #expect(CPUTimes.busyPercent(from: a, to: CPUTimes(total: 110, idle: 110)) == 0)
        #expect(CPUTimes.busyPercent(from: a, to: a) == nil)
    }

    @Test("df: 512-byte blocks, GNU '-' capacity, short and header-only rows")
    func dfVariants() {
        let disks = MetricsParser.parseDF("""
        Filesystem 512-blocks Used Available Capacity Mounted on
        /dev/disk1 1000 250 750 25% /Volumes/My Disk
        Filesystem 1024-blocks Used Available Capacity Mounted on
        proc 0 0 0 - /proc
        short 1 2 3
        /dev/x 1 2 3 4%
        """)
        #expect(disks == [
            DiskUsage(mount: "/Volumes/My Disk", device: "/dev/disk1", usedBytes: 250 * 512,
                      totalBytes: 1000 * 512, availableBytes: 750 * 512),
            DiskUsage(mount: "/proc", device: "proc", usedBytes: 0, totalBytes: 0, availableBytes: 0),
        ])
    }

    @Test("DiskUsage keeps its old initialiser and used/total fraction")
    func diskUsageCompat() {
        let disk = DiskUsage(mount: "/", device: "/dev/sda1", usedBytes: 50, totalBytes: 200)
        #expect(disk.availableBytes == nil)
        #expect(disk.usedFraction == 0.25)
        let reserved = DiskUsage(mount: "/", device: "/dev/sda1", usedBytes: 50, totalBytes: 200, availableBytes: 50)
        #expect(reserved.usedFraction == 0.5)
    }

    @Test("MetricsSample round-trips through Codable")
    func sampleCodable() throws {
        let (_, sample) = try success("ubuntu-vm-1")
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(MetricsSample.self, from: data) == sample)
    }
}

extension MetricsParseResult {
    /// Test convenience: the snapshot and sample of a successful parse.
    var successPair: (MetricsSnapshot, MetricsSample)? {
        if case .success(let snapshot, let sample) = self { (snapshot, sample) } else { nil }
    }
}
