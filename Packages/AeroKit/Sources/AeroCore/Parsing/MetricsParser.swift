import Foundation

/// Parses the output of `Scripts/remote/metrics.sh`.
///
/// One run prints `@@stat`, `@@cpus`, `@@mem`, `@@uptime`, `@@load`, `@@df`, `@@host`, `@@os`
/// and `@@end` sections. Keep the returned ``MetricsSample`` and pass it as `previous` on the next poll: CPU %
/// is the busy share of the CPU time that passed between two samples.
///
/// ```swift
/// switch MetricsParser.parse(output, previous: lastSample) {
/// case .success(let snapshot, let sample): lastSample = sample; show(snapshot)
/// case .unsupportedOS(let sample): markUnsupported(kernel: sample.kernel)
/// case .truncated: countFailure()
/// }
/// ```
public enum MetricsParser {
    /// Parses one poll.
    ///
    /// - Output without an `@@end` line is ``MetricsParseResult/truncated`` (the connection dropped
    ///   or the script was cut off), whatever else it contains.
    /// - Output without a usable `cpu` line in `@@stat` (no `/proc/stat`) is
    ///   ``MetricsParseResult/unsupportedOS(_:)``.
    /// - Empty or junk sections are "unavailable": `nil` in the sample, `0` (or empty) in the
    ///   snapshot, whose non-optional fields predate this parser. A 0 `memTotalBytes` makes
    ///   ``MetricsSnapshot/memUsedFraction`` `nil`.
    public static func parse(_ output: String, previous: MetricsSample? = nil, sampledAt: Date = .now) -> MetricsParseResult {
        let (sections, complete) = splitSections(output)
        guard complete else { return .truncated }
        let sample = sample(from: sections)
        guard sample.cpuTimes != nil else { return .unsupportedOS(sample) }
        return .success(snapshot(from: sample, previous: previous, sampledAt: sampledAt), sample: sample)
    }

    /// Builds the snapshot for `sample`; CPU % is `nil` without a usable `previous` sample.
    public static func snapshot(from sample: MetricsSample, previous: MetricsSample?, sampledAt: Date) -> MetricsSnapshot {
        var cpuPercent: Double?
        if let current = sample.cpuTimes, let earlier = previous?.cpuTimes {
            cpuPercent = CPUTimes.busyPercent(from: earlier, to: current)
        }
        return MetricsSnapshot(
            cpuPercent: cpuPercent,
            cpuCount: sample.cpuCount,
            memUsedBytes: sample.memory?.usedBytes ?? 0,
            memTotalBytes: sample.memory?.totalBytes ?? 0,
            disks: sample.disks,
            uptimeSeconds: sample.uptimeSeconds ?? 0,
            load1: sample.load?.one ?? 0,
            load5: sample.load?.five ?? 0,
            load15: sample.load?.fifteen ?? 0,
            hostname: sample.hostname ?? "",
            kernel: sample.kernel ?? "",
            sampledAt: sampledAt,
            swapTotalBytes: sample.memory?.swapTotalBytes,
            swapUsedBytes: sample.memory.flatMap { memory in
                guard let total = memory.swapTotalBytes, let free = memory.swapFreeBytes else { return nil }
                return max(total - free, 0)
            },
            os: sample.os
        )
    }

    /// Parses `df -Pk` output (one or more listings, each with its `Filesystem ...` header).
    ///
    /// Header lines are skipped, rows are de-duplicated by device (first occurrence wins), and
    /// each row is split around its Capacity field (`N%`) so devices and mount points may contain
    /// spaces: the three numbers before Capacity are size, used and available; everything before
    /// them is the device and everything after Capacity is the mount point.
    public static func parseDF(_ text: String) -> [DiskUsage] {
        parseDF(lines: text.split(whereSeparator: \.isNewline))
    }

    /// Splits the output into named sections. Lines before the first marker are ignored (login
    /// banners), a repeated section is ignored (first wins), and parsing stops at `@@end`.
    static func splitSections(_ output: String) -> (sections: [String: [Substring]], complete: Bool) {
        var sections: [String: [Substring]] = [:]
        var current: String?
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@@") {
                let name = trimmed.dropFirst(2)
                if name == "end" { return (sections, true) }
                if !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isLetter }) {
                    let key = String(name)
                    if sections[key] == nil {
                        sections[key] = []
                        current = key
                    } else {
                        current = nil
                    }
                    continue
                }
            }
            guard let current, !trimmed.isEmpty else { continue }
            sections[current, default: []].append(line)
        }
        return (sections, false)
    }

    static func sample(from sections: [String: [Substring]]) -> MetricsSample {
        let host = sections["host"] ?? []
        return MetricsSample(
            cpuTimes: (sections["stat"] ?? []).lazy.compactMap { CPUTimes(statLine: $0) }.first,
            cpuCount: sections["cpus"]?.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil },
            memory: MemoryInfo(meminfoLines: sections["mem"] ?? []),
            uptimeSeconds: sections["uptime"]?.first.flatMap { firstNumber(in: $0) },
            load: sections["load"]?.first.flatMap { LoadAverage(loadavgLine: $0) },
            disks: parseDF(lines: sections["df"] ?? []),
            kernel: host.first.map { $0.trimmingCharacters(in: .whitespaces) },
            hostname: host.dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) },
            os: OSRelease(lines: sections["os"] ?? [])
        )
    }

    /// The first whitespace-separated field as a finite, non-negative number.
    static func firstNumber(in line: Substring) -> Double? {
        guard let field = line.split(whereSeparator: \.isWhitespace).first,
              let value = Double(field), value.isFinite, value >= 0
        else { return nil }
        return value
    }

    static func parseDF(lines: [Substring]) -> [DiskUsage] {
        var blockSize: Int64 = 1024
        var seenDevices = Set<String>()
        var disks: [DiskUsage] = []
        for line in lines {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let first = tokens.first else { continue }
            if first == "Filesystem" {
                blockSize = tokens.count > 1 ? headerBlockSize(tokens[1]) : 1024
                continue
            }
            guard let disk = dfRow(line, tokens: tokens, blockSize: blockSize),
                  seenDevices.insert(disk.device).inserted
            else { continue }
            disks.append(disk)
        }
        return disks
    }

    /// Block size from a header's size column: `1024-blocks` (df -Pk), `512-blocks`, `1K-blocks`.
    private static func headerBlockSize(_ column: Substring) -> Int64 {
        guard column.hasSuffix("-blocks") else { return 1024 }
        let size = column.dropLast("-blocks".count)
        if size.uppercased() == "1K" { return 1024 }
        if let value = Int64(size), value > 0, value <= 1 << 20 { return value }
        return 1024
    }

    private static func dfRow(_ line: Substring, tokens: [Substring], blockSize: Int64) -> DiskUsage? {
        guard tokens.count >= 6 else { return nil }
        for capacityIndex in 4..<(tokens.count - 1) where isCapacity(tokens[capacityIndex]) {
            guard let size = blocks(tokens[capacityIndex - 3], blockSize),
                  let used = blocks(tokens[capacityIndex - 2], blockSize),
                  let available = blocks(tokens[capacityIndex - 1], blockSize)
            else { continue }
            let device = line[tokens[0].startIndex..<tokens[capacityIndex - 4].endIndex]
            let mount = line[tokens[capacityIndex + 1].startIndex..<tokens[tokens.count - 1].endIndex]
            return DiskUsage(
                mount: String(mount), device: String(device),
                usedBytes: used, totalBytes: size, availableBytes: available
            )
        }
        return nil
    }

    /// `N%`, or `-` (GNU df's Capacity for a zero-size filesystem).
    private static func isCapacity(_ token: Substring) -> Bool {
        if token == "-" { return true }
        guard token.hasSuffix("%") else { return false }
        let digits = token.dropLast()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func blocks(_ token: Substring, _ blockSize: Int64) -> Int64? {
        guard token.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int64(token) else { return nil }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: blockSize)
        return overflow ? nil : bytes
    }
}

/// Outcome of ``MetricsParser/parse(_:previous:sampledAt:)``.
public enum MetricsParseResult: Sendable, Hashable {
    /// A Linux poll. Keep `sample` for the next poll's CPU delta.
    case success(MetricsSnapshot, sample: MetricsSample)
    /// The script ran to `@@end` but there was no `/proc/stat` (macOS, BSD, ...): the card says
    /// "unsupported OS". The sample still carries `kernel`, `hostname`, `os` and `disks` when present.
    case unsupportedOS(MetricsSample)
    /// No `@@end`: the output was cut off. Count it as a failed poll.
    case truncated

    /// The snapshot of a successful poll.
    public var snapshot: MetricsSnapshot? {
        if case .success(let snapshot, _) = self { snapshot } else { nil }
    }

    /// The raw sample, unless the output was truncated.
    public var sample: MetricsSample? {
        switch self {
        case .success(_, let sample), .unsupportedOS(let sample): sample
        case .truncated: nil
        }
    }
}

/// Everything one run of `metrics.sh` reported, before CPU % is computed. Unavailable metrics
/// (empty or unparsable sections) are `nil`, never 0.
public struct MetricsSample: Codable, Sendable, Hashable {
    /// Aggregate CPU counters from `@@stat`; `nil` means no `/proc/stat` (unsupported OS).
    public var cpuTimes: CPUTimes?
    /// Logical CPUs (`@@cpus`).
    public var cpuCount: Int?
    /// Memory from `@@mem`.
    public var memory: MemoryInfo?
    /// First field of `/proc/uptime`.
    public var uptimeSeconds: Double?
    /// `/proc/loadavg`.
    public var load: LoadAverage?
    /// `@@df` rows in `df` order, de-duplicated by device (first occurrence wins).
    public var disks: [DiskUsage]
    /// `uname -srm`, e.g. `Linux 6.8.0-45-generic x86_64`.
    public var kernel: String?
    /// `hostname`.
    public var hostname: String?
    /// os-release from `@@os`; `nil` when the host has none (macOS) or the script predates it.
    public var os: OSRelease?

    /// Creates a sample.
    public init(
        cpuTimes: CPUTimes? = nil,
        cpuCount: Int? = nil,
        memory: MemoryInfo? = nil,
        uptimeSeconds: Double? = nil,
        load: LoadAverage? = nil,
        disks: [DiskUsage] = [],
        kernel: String? = nil,
        hostname: String? = nil,
        os: OSRelease? = nil
    ) {
        self.cpuTimes = cpuTimes
        self.cpuCount = cpuCount
        self.memory = memory
        self.uptimeSeconds = uptimeSeconds
        self.load = load
        self.disks = disks
        self.kernel = kernel
        self.hostname = hostname
        self.os = os
    }
}

/// Cumulative CPU time from the aggregate `cpu` line of `/proc/stat`, in clock ticks.
public struct CPUTimes: Codable, Sendable, Hashable {
    /// user + nice + system + idle + iowait + irq + softirq + steal. Guest time is already
    /// included in user and nice, so the guest columns are not added again.
    public var total: UInt64
    /// idle + iowait.
    public var idle: UInt64
    /// total − (idle + iowait).
    public var busy: UInt64 { total - idle }

    /// Creates counters; `idle` is clamped to `total`.
    public init(total: UInt64, idle: UInt64) {
        self.total = total
        self.idle = min(idle, total)
    }

    /// Parses `cpu  user nice system idle [iowait irq softirq steal guest guest_nice]`. Needs at
    /// least the first four counters (very old kernels have no iowait); `nil` for anything else.
    public init?(statLine: some StringProtocol) {
        let fields = statLine.split(whereSeparator: \.isWhitespace)
        guard fields.first == "cpu", fields.count >= 5 else { return nil }
        var values: [UInt64] = []
        for field in fields.dropFirst().prefix(8) {
            guard field.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt64(field) else { return nil }
            values.append(value)
        }
        var total: UInt64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = sum
        }
        let idle = values[3] + (values.count > 4 ? values[4] : 0)
        self.init(total: total, idle: idle)
    }

    /// Busy share of the CPU time between two samples, 0...100. `nil` when no time passed or the
    /// counters went backwards (reboot, counter reset, a different host behind the address).
    public static func busyPercent(from previous: CPUTimes, to current: CPUTimes) -> Double? {
        guard current.total > previous.total else { return nil }
        let elapsed = Double(current.total - previous.total)
        let idle = Double(current.idle) - Double(previous.idle)
        let percent = (elapsed - idle) / elapsed * 100
        guard percent.isFinite else { return nil }
        return min(max(percent, 0), 100)
    }
}

/// Memory from `/proc/meminfo`, in bytes.
public struct MemoryInfo: Codable, Sendable, Hashable {
    /// MemTotal.
    public var totalBytes: Int64
    /// MemAvailable, or MemFree + Buffers + Cached when MemAvailable is missing (kernels before 3.14).
    public var availableBytes: Int64
    /// `true` when ``availableBytes`` is the MemFree + Buffers + Cached estimate.
    public var availableIsEstimate: Bool
    /// SwapTotal, if reported.
    public var swapTotalBytes: Int64?
    /// SwapFree, if reported.
    public var swapFreeBytes: Int64?

    /// MemTotal − available, never negative.
    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    /// Creates memory info; `availableBytes` is clamped to `0...totalBytes`.
    public init(totalBytes: Int64, availableBytes: Int64, availableIsEstimate: Bool = false,
                swapTotalBytes: Int64? = nil, swapFreeBytes: Int64? = nil) {
        self.totalBytes = max(0, totalBytes)
        self.availableBytes = min(max(0, availableBytes), self.totalBytes)
        self.availableIsEstimate = availableIsEstimate
        self.swapTotalBytes = swapTotalBytes
        self.swapFreeBytes = swapFreeBytes
    }

    /// Parses `Key:   value kB` lines. `nil` without a positive MemTotal, or without both
    /// MemAvailable and MemFree.
    init?(meminfoLines lines: [Substring]) {
        var kib: [String: Int64] = [:]
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].hasSuffix(":"),
                  fields[1].allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int64(fields[1])
            else { continue }
            let key = String(fields[0].dropLast())
            if kib[key] == nil { kib[key] = value }
        }
        func bytes(_ key: String) -> Int64? {
            guard let value = kib[key] else { return nil }
            let (result, overflow) = value.multipliedReportingOverflow(by: 1024)
            return overflow ? nil : result
        }
        guard let total = bytes("MemTotal"), total > 0 else { return nil }
        if let available = bytes("MemAvailable") {
            self.init(totalBytes: total, availableBytes: available,
                      swapTotalBytes: bytes("SwapTotal"), swapFreeBytes: bytes("SwapFree"))
        } else if let free = bytes("MemFree") {
            let estimate = [free, bytes("Buffers") ?? 0, bytes("Cached") ?? 0]
                .reduce(Int64(0)) { sum, part in sum.addingReportingOverflow(part).overflow ? Int64.max : sum + part }
            self.init(totalBytes: total, availableBytes: estimate, availableIsEstimate: true,
                      swapTotalBytes: bytes("SwapTotal"), swapFreeBytes: bytes("SwapFree"))
        } else {
            return nil
        }
    }
}

/// Load averages from `/proc/loadavg`.
public struct LoadAverage: Codable, Sendable, Hashable {
    /// 1-minute load.
    public var one: Double
    /// 5-minute load.
    public var five: Double
    /// 15-minute load.
    public var fifteen: Double

    /// Creates load averages.
    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }

    /// Parses `1.80 2.20 2.90 1/982 9213`; needs the first three fields.
    init?(loadavgLine line: Substring) {
        let values = line.split(whereSeparator: \.isWhitespace).prefix(3).compactMap { Double($0) }
        guard values.count == 3, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        self.init(one: values[0], five: values[1], fifteen: values[2])
    }
}

extension MetricsSnapshot {
    /// The disk a host card shows: the pinned mount when it is present in this sample, else `/`.
    /// `nil` when neither exists. Compare the result's `mount` with the pin to tell the user when
    /// a pinned mount has disappeared.
    public func cardDisk(pinnedMount: String? = nil) -> DiskUsage? {
        if let pinnedMount, let pinned = disk(mountedAt: pinnedMount) { return pinned }
        return disk(mountedAt: "/")
    }
}
