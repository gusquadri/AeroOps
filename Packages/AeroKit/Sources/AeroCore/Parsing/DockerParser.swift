import Foundation

/// Parses Docker CLI output.
///
/// ```swift
/// let ps = try await run("docker ps -a --no-trunc --format '{{json .}}'")
/// let stats = try await run("docker stats --no-stream --format '{{json .}}'")
/// let rows = try DockerParser.parseContainers(ps: ps, stats: stats)
/// ```
/// When a command exits non-zero, classify its stderr with ``DockerError/classify(_:)``.
public enum DockerParser {
    /// Merges `docker ps -a --no-trunc --format '{{json .}}'` with
    /// `docker stats --no-stream --format '{{json .}}'` (JSON lines; junk lines are skipped).
    ///
    /// Rows keep `docker ps` order. Stats attach by full ID, then name, then short-ID prefix;
    /// containers without stats (not running) have `nil` CPU and memory.
    ///
    /// - Throws: ``DockerError`` when `ps` has no JSON rows at all but does have text, e.g. the
    ///   permission-denied message when stderr was merged into stdout.
    public static func parseContainers(ps psOutput: String, stats statsOutput: String = "") throws(DockerError) -> [ContainerInfo] {
        var rows: [ContainerInfo] = []
        var junk: [Substring] = []
        for line in nonEmptyLines(psOutput) {
            if let row = decodeLine(PSRow.self, line), let container = row.container() {
                rows.append(container)
            } else {
                junk.append(line)
            }
        }
        if rows.isEmpty, !junk.isEmpty {
            throw DockerError.classify(junk.joined(separator: "\n"))
        }
        let stats = parseStats(statsOutput)
        guard !stats.isEmpty else { return rows }

        var byID: [String: DockerStats] = [:]
        var byName: [String: DockerStats] = [:]
        for entry in stats {
            if !entry.containerID.isEmpty, byID[entry.containerID] == nil { byID[entry.containerID] = entry }
            if !entry.name.isEmpty, byName[entry.name] == nil { byName[entry.name] = entry }
        }
        return rows.map { row in
            let match = byID[row.id] ?? byName[row.name]
                ?? stats.first { $0.shortID.count >= 12 && row.id.hasPrefix($0.shortID) }
            guard let match else { return row }
            var merged = row
            merged.cpuPercent = match.cpuPercent
            merged.memUsedBytes = match.memUsedBytes
            merged.memLimitBytes = match.memLimitBytes
            return merged
        }
    }

    /// Parses `docker stats --no-stream --format '{{json .}}'` lines. Junk lines are skipped.
    public static func parseStats(_ output: String) -> [DockerStats] {
        nonEmptyLines(output).compactMap { decodeLine(StatsRow.self, $0)?.stats() }
    }

    /// Parses `docker inspect <id>...` output (a JSON array). Undecodable entries are skipped.
    public static func parseInspect(_ data: Data) -> [DockerInspectSummary] {
        guard let list = decodeJSONTolerantly(LossyArray<InspectJSON>.self, from: data) else { return [] }
        return list.elements.compactMap { $0.summary() }
    }

    /// A Docker size string in bytes: binary units for memory (`204KiB`, `9.25MiB`, `2.911GiB`),
    /// decimal units for I/O (`14.7MB`, `8.19kB`, `0B`). `nil` for `--` or junk.
    public static func parseByteSize(_ text: some StringProtocol) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let unitStart = trimmed.firstIndex(where: { $0.isLetter }) else { return nil }
        guard let number = Double(trimmed[..<unitStart].trimmingCharacters(in: .whitespaces)),
              number.isFinite, number >= 0,
              let multiplier = byteUnits[trimmed[unitStart...].lowercased()]
        else { return nil }
        let bytes = (number * multiplier).rounded()
        guard bytes < 9.0e18 else { return nil }
        return Int64(bytes)
    }

    /// A Docker percentage such as `0.03%`. `nil` for `--` or junk.
    public static func parsePercent(_ text: some StringProtocol) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { trimmed.removeLast() }
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static let byteUnits: [String: Double] = [
        "b": 1,
        "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15,
        "k": 1e3, "m": 1e6, "g": 1e9, "t": 1e12, "p": 1e15,
        "kib": 1_024, "mib": 1_048_576, "gib": 1_073_741_824,
        "tib": 1_099_511_627_776, "pib": 1_125_899_906_842_624,
    ]

    private static func nonEmptyLines(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
    }

    private static func decodeLine<T: Decodable>(_ type: T.Type, _ line: Substring) -> T? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return nil }
        return try? JSONDecoder().decode(type, from: Data(trimmed.utf8))
    }

    /// Docker's state from a status text, for old Docker versions whose `ps` JSON has no `State`.
    static func state(fromStatus status: String) -> ContainerState {
        let lower = status.lowercased()
        if lower.hasPrefix("up") { return lower.contains("(paused)") ? .paused : .running }
        if lower.hasPrefix("exited") { return .exited }
        if lower.hasPrefix("created") { return .created }
        if lower.hasPrefix("restarting") { return .restarting }
        if lower.hasPrefix("removal in progress") { return .removing }
        if lower.hasPrefix("dead") { return .dead }
        return .unknown
    }
}

/// One `docker stats --no-stream` row.
public struct DockerStats: Sendable, Hashable {
    /// `Container`: the full ID (or the name/ID the user passed to `docker stats`).
    public var containerID: String
    /// `ID`: the 12-character short ID.
    public var shortID: String
    /// `Name`.
    public var name: String
    /// `CPUPerc` as a number (may exceed 100 on multi-core hosts).
    public var cpuPercent: Double?
    /// Used part of `MemUsage` (`9.25MiB / 2.911GiB`), in bytes.
    public var memUsedBytes: Int64?
    /// Limit part of `MemUsage`, in bytes.
    public var memLimitBytes: Int64?

    /// Creates a stats row.
    public init(containerID: String, shortID: String, name: String, cpuPercent: Double?,
                memUsedBytes: Int64?, memLimitBytes: Int64?) {
        self.containerID = containerID
        self.shortID = shortID
        self.name = name
        self.cpuPercent = cpuPercent
        self.memUsedBytes = memUsedBytes
        self.memLimitBytes = memLimitBytes
    }
}

/// Docker's health-check result, from `Status` (`(healthy)`) or `State.Health.Status`.
public enum ContainerHealthCheck: String, Codable, Sendable, Hashable, CaseIterable {
    case healthy
    case unhealthy
    /// `health: starting`: the first check has not passed yet.
    case starting

    /// Maps `healthy`, `unhealthy` and `starting`; `none` and unknown strings give `nil`.
    public init?(dockerHealthStatus: String) {
        self.init(rawValue: dockerHealthStatus.lowercased())
    }
}

/// The parts of `docker inspect` the container detail view uses.
public struct DockerInspectSummary: Sendable, Hashable {
    /// Full container ID.
    public var id: String
    /// Name without the leading slash.
    public var name: String
    /// `Config.Image`, e.g. `nginx:1.27-alpine`.
    public var image: String?
    /// `RestartCount`.
    public var restartCount: Int
    /// `State.Health.Status`; `nil` without a health check.
    public var healthCheck: ContainerHealthCheck?
    /// `State.ExitCode`.
    public var exitCode: Int?
    /// `State.StartedAt`; `nil` if never started.
    public var startedAt: Date?
    /// `State.FinishedAt`; `nil` if it never finished (Docker's `0001-01-01T00:00:00Z`).
    public var finishedAt: Date?
    /// `HostConfig.RestartPolicy.Name`, e.g. `unless-stopped`; `nil` when empty or `no`.
    public var restartPolicy: String?
    /// `NetworkSettings.Ports` in `docker ps` style: `0.0.0.0:8080->80/tcp`, `[::]:8080->80/tcp`,
    /// or just `80/tcp` when not published. Sorted by container port.
    public var ports: [String]
}

/// Errors from Docker commands, with user-facing hints.
public enum DockerError: Error, Sendable, Hashable, LocalizedError {
    /// The user cannot use the Docker socket (not in the `docker` group).
    case permissionDenied(socket: String?)
    /// The Docker daemon is not running (or the socket path is wrong).
    case daemonNotRunning
    /// `sudo -n docker` was refused: no passwordless sudo rule for docker.
    case sudoRefused
    /// `docker` is not installed or not on the PATH.
    case notInstalled
    /// Anything else; the first line of the error output.
    case failed(message: String)

    /// Classifies a failed Docker command's stderr (or merged output).
    public static func classify(_ output: String) -> DockerError {
        let lower = output.lowercased()
        if CommandErrorText.isSudoRefusal(output) { return .sudoRefused }
        if lower.contains("permission denied"), lower.contains("docker") {
            let socket = output.split(whereSeparator: \.isWhitespace)
                .first { $0.hasPrefix("unix://") || $0.hasPrefix("tcp://") || $0.hasPrefix("npipe://") }
                .map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: ":,."))) }
            return .permissionDenied(socket: socket)
        }
        if lower.contains("cannot connect to the docker daemon") || lower.contains("is the docker daemon running") {
            return .daemonNotRunning
        }
        if CommandErrorText.isCommandNotFound(output, commands: ["docker"]) { return .notInstalled }
        return .failed(message: CommandErrorText.summary(output))
    }

    /// What the user can do about it.
    public var hint: String? {
        switch self {
        case .permissionDenied:
            "Add this user to the docker group (sudo usermod -aG docker <user>, then log in again), "
                + "or turn on \"Run docker with sudo -n\" for this host in the host editor."
        case .daemonNotRunning:
            "Start the Docker service on the host (for example: sudo systemctl start docker)."
        case .sudoRefused:
            "sudo -n needs a passwordless sudoers rule (NOPASSWD) for docker. Add one, "
                + "or turn off \"Run docker with sudo -n\" and add the user to the docker group instead."
        case .notInstalled:
            "Docker is not installed on this host, or not on the login user's PATH."
        case .failed:
            nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let socket?): "Permission denied on the Docker socket (\(socket))."
        case .permissionDenied(nil): "Permission denied on the Docker socket."
        case .daemonNotRunning: "The Docker daemon is not running."
        case .sudoRefused: "sudo refused to run docker without a password."
        case .notInstalled: "Docker was not found."
        case .failed(let message): message.isEmpty ? "The docker command failed." : message
        }
    }

    public var recoverySuggestion: String? { hint }
}

extension ContainerInfo {
    /// The health-check result in the status text: `(healthy)`, `(unhealthy)`, `(health: starting)`.
    public var healthCheck: ContainerHealthCheck? {
        let lower = status.lowercased()
        if lower.contains("(unhealthy)") { return .unhealthy }
        if lower.contains("(healthy)") { return .healthy }
        if lower.contains("(health: starting)") { return .starting }
        return nil
    }

    /// The exit code in `Exited (3) 7 minutes ago`; `nil` for other statuses.
    public var exitCode: Int? {
        guard status.lowercased().hasPrefix("exited"),
              let open = status.firstIndex(of: "("),
              let close = status[open...].firstIndex(of: ")")
        else { return nil }
        return Int(status[status.index(after: open)..<close])
    }

    /// Status colour class:
    /// - running is green, or yellow while the health check is starting, red when unhealthy;
    /// - restarting and dead are red; paused and removing are yellow;
    /// - exited with code 0 (or unknown) and created are grey; exited non-zero is red.
    public var health: WorkloadHealth {
        switch state {
        case .running:
            switch healthCheck {
            case .unhealthy: .failing
            case .starting: .warning
            case .healthy, nil: .healthy
            }
        case .restarting, .dead: .failing
        case .paused, .removing: .warning
        case .exited: (exitCode ?? 0) == 0 ? .inactive : .failing
        case .created, .unknown: .inactive
        }
    }

    /// Short age from ``createdAt`` (`5m`, `3h`, `2d`), or `nil` when unknown.
    public func age(now: Date = .now) -> String? {
        createdAt.map { AgeFormat.short(since: $0, now: now) }
    }
}

/// One `docker ps --format '{{json .}}'` line. Every field is optional and type-tolerant.
private struct PSRow: Decodable {
    var id, names, image, state, status, createdAt, runningFor, ports: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID", names = "Names", image = "Image", state = "State", status = "Status"
        case createdAt = "CreatedAt", runningFor = "RunningFor", ports = "Ports"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.nonEmptyString(.id)
        names = c.nonEmptyString(.names)
        image = c.nonEmptyString(.image)
        state = c.nonEmptyString(.state)
        status = c.lenient(String.self, .status)
        createdAt = c.nonEmptyString(.createdAt)
        runningFor = c.nonEmptyString(.runningFor)
        ports = c.nonEmptyString(.ports)
    }

    func container() -> ContainerInfo? {
        let firstName = names?.split(separator: ",").first.map { String($0.drop { $0 == "/" }) }
        guard let id = id ?? firstName else { return nil }
        let name = firstName ?? id
        let status = status ?? ""
        return ContainerInfo(
            id: id,
            name: name,
            image: image ?? "",
            state: state.map(ContainerState.init(dockerState:)) ?? DockerParser.state(fromStatus: status),
            status: status,
            createdAt: createdAt.flatMap { Timestamps.parseDockerCreatedAt($0) ?? Timestamps.parseRFC3339($0) },
            ports: ports,
            runningFor: runningFor
        )
    }
}

/// One `docker stats --format '{{json .}}'` line.
private struct StatsRow: Decodable {
    var container, id, name, cpu, memory: String?

    enum CodingKeys: String, CodingKey {
        case container = "Container", id = "ID", name = "Name", cpu = "CPUPerc", memory = "MemUsage"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        container = c.nonEmptyString(.container)
        id = c.nonEmptyString(.id)
        name = c.nonEmptyString(.name)
        cpu = c.nonEmptyString(.cpu)
        memory = c.nonEmptyString(.memory)
    }

    func stats() -> DockerStats? {
        guard container != nil || id != nil || name != nil else { return nil }
        let memoryParts = memory?.split(separator: "/", maxSplits: 1) ?? []
        return DockerStats(
            containerID: container ?? id ?? "",
            shortID: id ?? "",
            name: name.map { String($0.drop { $0 == "/" }) } ?? "",
            cpuPercent: cpu.flatMap { DockerParser.parsePercent($0) },
            memUsedBytes: memoryParts.first.flatMap { DockerParser.parseByteSize($0) },
            memLimitBytes: memoryParts.dropFirst().first.flatMap { DockerParser.parseByteSize($0) }
        )
    }
}

/// The few `docker inspect` fields ``DockerInspectSummary`` needs.
private struct InspectJSON: Decodable {
    struct StateJSON: Decodable {
        struct HealthJSON: Decodable {
            var status: String?
            enum CodingKeys: String, CodingKey { case status = "Status" }
        }
        var exitCode: Int?
        var startedAt: String?
        var finishedAt: String?
        var health: HealthJSON?

        enum CodingKeys: String, CodingKey {
            case exitCode = "ExitCode", startedAt = "StartedAt", finishedAt = "FinishedAt", health = "Health"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exitCode = c.lenient(Int.self, .exitCode)
            startedAt = c.nonEmptyString(.startedAt)
            finishedAt = c.nonEmptyString(.finishedAt)
            health = c.lenient(HealthJSON.self, .health)
        }
    }
    struct ConfigJSON: Decodable {
        var image: String?
        enum CodingKeys: String, CodingKey { case image = "Image" }
    }
    struct HostConfigJSON: Decodable {
        struct RestartPolicyJSON: Decodable {
            var name: String?
            enum CodingKeys: String, CodingKey { case name = "Name" }
        }
        var restartPolicy: RestartPolicyJSON?
        enum CodingKeys: String, CodingKey { case restartPolicy = "RestartPolicy" }
    }
    struct BindingJSON: Decodable {
        var hostIP: String?
        var hostPort: String?
        enum CodingKeys: String, CodingKey { case hostIP = "HostIp", hostPort = "HostPort" }
    }
    struct NetworkSettingsJSON: Decodable {
        var ports: [String: [BindingJSON]?]?
        enum CodingKeys: String, CodingKey { case ports = "Ports" }
    }

    var id: String?
    var name: String?
    var restartCount: Int?
    var state: StateJSON?
    var config: ConfigJSON?
    var hostConfig: HostConfigJSON?
    var networkSettings: NetworkSettingsJSON?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", restartCount = "RestartCount", state = "State", config = "Config"
        case hostConfig = "HostConfig", networkSettings = "NetworkSettings"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.nonEmptyString(.id)
        name = c.nonEmptyString(.name)
        restartCount = c.lenient(Int.self, .restartCount)
        state = c.lenient(StateJSON.self, .state)
        config = c.lenient(ConfigJSON.self, .config)
        hostConfig = c.lenient(HostConfigJSON.self, .hostConfig)
        networkSettings = c.lenient(NetworkSettingsJSON.self, .networkSettings)
    }

    func summary() -> DockerInspectSummary? {
        guard let id else { return nil }
        func date(_ text: String?) -> Date? {
            guard let text, !text.hasPrefix("0001-01-01") else { return nil }
            return Timestamps.parseRFC3339(text)
        }
        func portNumber(_ key: String) -> Int { Int(key.prefix { $0.isNumber }) ?? Int.max }
        let policy = hostConfig?.restartPolicy?.name
        var ports: [String] = []
        let sortedPorts = (networkSettings?.ports ?? [:]).sorted {
            (portNumber($0.key), $0.key) < (portNumber($1.key), $1.key)
        }
        for (containerPort, bindings) in sortedPorts {
            let published = (bindings ?? []).compactMap { binding -> String? in
                guard let hostPort = binding.hostPort, !hostPort.isEmpty else { return nil }
                let ip = binding.hostIP ?? ""
                let host = ip.contains(":") ? "[\(ip)]" : ip
                return "\(host.isEmpty ? "" : host + ":")\(hostPort)->\(containerPort)"
            }
            ports += published.isEmpty ? [containerPort] : published
        }
        return DockerInspectSummary(
            id: id,
            name: String((name ?? id).drop { $0 == "/" }),
            image: config?.image,
            restartCount: max(0, restartCount ?? 0),
            healthCheck: state?.health?.status.flatMap { ContainerHealthCheck(dockerHealthStatus: $0) },
            exitCode: state?.exitCode,
            startedAt: date(state?.startedAt),
            finishedAt: date(state?.finishedAt),
            restartPolicy: policy.flatMap { $0.isEmpty || $0 == "no" ? nil : $0 },
            ports: ports
        )
    }
}
