import AeroCore
import Foundation

/// A tool call whose arguments failed validation. The message names the argument and the rule,
/// so the model can fix the call: "Argument 'tail' must be between 1 and 2000 (got 5000)."
public struct ToolArgumentError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// `list_hosts` arguments.
public struct ListHostsArguments: Sendable, Hashable {
    /// Only hosts with this tag (case-insensitive).
    public var tag: String?

    public init(tag: String? = nil) {
        self.tag = tag
    }
}

/// Arguments of tools that only take a host.
public struct HostArguments: Sendable, Hashable {
    public var host: String

    public init(host: String) {
        self.host = host
    }
}

/// `list_containers` arguments.
public struct ListContainersArguments: Sendable, Hashable {
    public var host: String
    /// Include stopped containers.
    public var all: Bool

    public init(host: String, all: Bool = false) {
        self.host = host
        self.all = all
    }
}

/// `list_pods` arguments.
public struct ListPodsArguments: Sendable, Hashable {
    public var host: String
    /// `nil` means all namespaces.
    public var namespace: String?

    public init(host: String, namespace: String? = nil) {
        self.host = host
        self.namespace = namespace
    }
}

/// `get_logs` arguments. Every name passed ``ShellQuote/isSafeName(_:)``.
public struct GetLogsArguments: Sendable, Hashable {
    public var host: String
    public var kind: LogRequest.Kind
    public var name: String
    public var namespace: String?
    public var container: String?
    /// 1...2000.
    public var tail: Int
    public var sinceSeconds: Int?
    public var previous: Bool

    public init(host: String, kind: LogRequest.Kind, name: String, namespace: String? = nil, container: String? = nil,
                tail: Int = BridgeLimits.defaultTail, sinceSeconds: Int? = nil, previous: Bool = false) {
        self.host = host
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.container = container
        self.tail = tail
        self.sinceSeconds = sinceSeconds
        self.previous = previous
    }

    /// The AeroCore request for the resolved host. Never follows.
    public func logRequest(hostId: UUID) -> LogRequest {
        LogRequest(hostId: hostId, kind: kind, name: name, namespace: namespace, container: container,
                   tail: tail, sinceSeconds: sinceSeconds, previous: previous, follow: false)
    }
}

/// `run_command` arguments.
public struct RunCommandArguments: Sendable, Hashable {
    public var host: String
    /// Exactly as the agent sent it; shown verbatim in the Activity tab.
    public var command: String
    public var reason: String
    /// 1...300.
    public var timeoutSeconds: Int

    public init(host: String, command: String, reason: String, timeoutSeconds: Int = BridgeLimits.defaultTimeoutSeconds) {
        self.host = host
        self.command = command
        self.reason = reason
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum ToolCall: Sendable, Hashable {
    case monitoring(MonitoringCall)
    case runCommand(RunCommandArguments)
    case files(FileCall)

    public var hostQuery: String? {
        switch self {
        case .monitoring(let call): call.hostQuery
        case .runCommand(let arguments): arguments.host
        case .files(let call): call.host
        }
    }

    public static func parse(toolName name: String, arguments: [String: JSONValue]) throws(ToolArgumentError) -> ToolCall {
        guard let tool = BridgeTool(rawValue: name) else {
            throw ToolArgumentError("Unknown tool '\(ArgumentReader.clip(name))'.")
        }
        return try parse(tool: tool, arguments: arguments)
    }

    public static func parse(tool: BridgeTool, arguments: [String: JSONValue]) throws(ToolArgumentError) -> ToolCall {
        switch tool.family {
        case .monitoring: .monitoring(try MonitoringCall.parse(tool, arguments))
        case .exec: .runCommand(try RunCommandArguments(reading: ArgumentReader(tool, arguments, allowed: RunCommandArguments.keys)))
        case .files: .files(try FileCall.parse(tool, arguments))
        }
    }
}

public enum MonitoringCall: Sendable, Hashable {
    case listHosts(ListHostsArguments)
    case getHostMetrics(HostArguments)
    case listContainers(ListContainersArguments)
    case listPods(ListPodsArguments)
    case getLogs(GetLogsArguments)

    public var hostQuery: String? {
        switch self {
        case .listHosts: nil
        case .getHostMetrics(let a): a.host
        case .listContainers(let a): a.host
        case .listPods(let a): a.host
        case .getLogs(let a): a.host
        }
    }

    static func parse(_ tool: BridgeTool, _ arguments: [String: JSONValue]) throws(ToolArgumentError) -> MonitoringCall {
        switch tool {
        case .listHosts:
            let r = try ArgumentReader(tool, arguments, allowed: ["tag"])
            return .listHosts(ListHostsArguments(tag: try r.text("tag", maxLength: BridgeLimits.maxNameLength)))
        case .getHostMetrics:
            return .getHostMetrics(HostArguments(host: try ArgumentReader(tool, arguments, allowed: ["host"]).host()))
        case .listContainers:
            let r = try ArgumentReader(tool, arguments, allowed: ["host", "all"])
            return .listContainers(ListContainersArguments(host: try r.host(), all: try r.bool("all") ?? false))
        case .listPods:
            let r = try ArgumentReader(tool, arguments, allowed: ["host", "namespace"])
            return .listPods(ListPodsArguments(host: try r.host(), namespace: try r.safeName("namespace")))
        case .getLogs:
            return .getLogs(try GetLogsArguments(reading: ArgumentReader(tool, arguments, allowed: GetLogsArguments.keys)))
        default:
            throw ToolArgumentError("Unknown tool '\(tool.rawValue)'.")
        }
    }
}

extension GetLogsArguments {
    static let keys = ["host", "kind", "name", "namespace", "container", "tail", "since", "previous"]

    init(reading r: ArgumentReader) throws(ToolArgumentError) {
        let host = try r.host()
        let kind = try Self.kind(r)
        guard let name = try r.safeName("name") else {
            throw ToolArgumentError("Missing required argument 'name'.")
        }
        let namespace = try r.safeName("namespace")
        let container = try r.safeName("container")
        let previous = try r.bool("previous") ?? false
        if kind == .container { try Self.checkContainerOptions(namespace, container, previous) }
        self.init(host: host, kind: kind, name: name, namespace: namespace, container: container,
                  tail: try r.int("tail", range: 1...BridgeLimits.maxTail) ?? BridgeLimits.defaultTail,
                  sinceSeconds: try r.duration("since", range: 1...BridgeLimits.maxSinceSeconds), previous: previous)
    }

    private static func kind(_ r: ArgumentReader) throws(ToolArgumentError) -> LogRequest.Kind {
        let text = try r.requiredText("kind", maxLength: 16)
        guard let kind = LogRequest.Kind(rawValue: text.lowercased()) else {
            throw ToolArgumentError("Argument 'kind' must be \"container\" or \"pod\" (got \(ArgumentReader.quoted(text))).")
        }
        return kind
    }

    private static func checkContainerOptions(_ namespace: String?, _ container: String?, _ previous: Bool) throws(ToolArgumentError) {
        if namespace != nil { throw ToolArgumentError("Argument 'namespace' only applies to kind \"pod\".") }
        if container != nil { throw ToolArgumentError("Argument 'container' only applies to kind \"pod\".") }
        if previous { throw ToolArgumentError("Argument 'previous' only applies to kind \"pod\".") }
    }
}

extension RunCommandArguments {
    static let keys = ["host", "command", "reason", "timeoutSec"]

    init(reading r: ArgumentReader) throws(ToolArgumentError) {
        self.init(host: try r.host(), command: try r.command(),
                  reason: try r.requiredText("reason", maxLength: BridgeLimits.maxReasonCharacters),
                  timeoutSeconds: try r.int("timeoutSec", range: BridgeLimits.timeoutRange) ?? BridgeLimits.defaultTimeoutSeconds)
    }
}

/// Typed, lenient-where-harmless access to an `arguments` object. `null` counts as absent;
/// integers and booleans may also arrive as strings ("100", "true") since some clients send them so.
struct ArgumentReader {
    let tool: BridgeTool
    let arguments: [String: JSONValue]

    init(_ tool: BridgeTool, _ arguments: [String: JSONValue], allowed: [String]) throws(ToolArgumentError) {
        self.tool = tool
        self.arguments = arguments.filter { !$0.value.isNull }
        let unknown = self.arguments.keys.filter { !allowed.contains($0) }.sorted()
        if let first = unknown.first {
            let allowedText = allowed.isEmpty ? "none" : allowed.joined(separator: ", ")
            let label = unknown.count == 1 ? "Unknown argument \(Self.quoted(first))" :
                "Unknown arguments \(unknown.prefix(5).map(Self.quoted).joined(separator: ", "))"
            throw ToolArgumentError("\(label) for \(tool.rawValue). Allowed: \(allowedText).")
        }
    }

    func string(_ key: String) throws(ToolArgumentError) -> String? {
        guard let value = arguments[key] else { return nil }
        guard let text = value.stringValue else {
            throw ToolArgumentError("Argument '\(key)' must be a string (got \(value.typeDescription)).")
        }
        return text
    }

    func int(_ key: String, range: ClosedRange<Int>) throws(ToolArgumentError) -> Int? {
        guard let value = arguments[key] else { return nil }
        let number: Int
        if let exact = value.intValue {
            number = exact
        } else if let text = value.stringValue, let parsed = Int(text.trimmingCharacters(in: .whitespaces)) {
            number = parsed
        } else if case .double(let d) = value {
            throw ToolArgumentError("Argument '\(key)' must be a whole number (got \(d)).")
        } else {
            let got = value.stringValue.map(Self.quoted) ?? value.typeDescription
            throw ToolArgumentError("Argument '\(key)' must be an integer (got \(got)).")
        }
        guard range.contains(number) else {
            throw ToolArgumentError("Argument '\(key)' must be between \(range.lowerBound) and \(range.upperBound) (got \(number)).")
        }
        return number
    }

    func bool(_ key: String) throws(ToolArgumentError) -> Bool? {
        guard let value = arguments[key] else { return nil }
        if let flag = value.boolValue { return flag }
        switch value.stringValue?.lowercased() {
        case "true": return true
        case "false": return false
        default:
            let got = value.stringValue.map(Self.quoted) ?? value.typeDescription
            throw ToolArgumentError("Argument '\(key)' must be true or false (got \(got)).")
        }
    }

    /// Optional free text: no control or invisible characters, at most `maxLength` characters.
    func text(_ key: String, maxLength: Int) throws(ToolArgumentError) -> String? {
        guard let text = try string(key) else { return nil }
        if text.isEmpty { throw ToolArgumentError("Argument '\(key)' must not be empty.") }
        if text.count > maxLength {
            throw ToolArgumentError("Argument '\(key)' is \(text.count) characters long; the limit is \(maxLength).")
        }
        try Self.checkCharacters(text, key: key, allowNewlines: false)
        return text
    }

    func requiredText(_ key: String, maxLength: Int) throws(ToolArgumentError) -> String {
        guard let text = try text(key, maxLength: maxLength) else {
            throw ToolArgumentError("Missing required argument '\(key)'.")
        }
        if text.allSatisfy(\.isWhitespace) { throw ToolArgumentError("Argument '\(key)' must not be blank.") }
        return text
    }

    func host() throws(ToolArgumentError) -> String {
        guard let text = try string("host") else { throw ToolArgumentError("Missing required argument 'host'.") }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw ToolArgumentError("Argument 'host' must not be empty. Use a name or id from list_hosts.") }
        if trimmed.utf8.count > BridgeLimits.maxHostQueryBytes {
            throw ToolArgumentError("Argument 'host' is \(trimmed.utf8.count) bytes long; the limit is \(BridgeLimits.maxHostQueryBytes).")
        }
        try Self.checkCharacters(trimmed, key: "host", allowNewlines: false)
        return trimmed
    }

    /// A container, pod, namespace or container name: ``ShellQuote/isSafeName(_:)`` and ≤ 253 characters.
    func safeName(_ key: String) throws(ToolArgumentError) -> String? {
        guard let text = try string(key) else { return nil }
        if text.isEmpty { throw ToolArgumentError("Argument '\(key)' must not be empty.") }
        if text.utf8.count > BridgeLimits.maxNameLength {
            throw ToolArgumentError("Argument '\(key)' is \(text.utf8.count) bytes long; the limit is \(BridgeLimits.maxNameLength).")
        }
        guard ShellQuote.isSafeName(text) else {
            throw ToolArgumentError(
                "Argument '\(key)' may only contain letters, digits, '.', '_' and '-' and must not start with '-' (got \(Self.quoted(text))).")
        }
        return text
    }

    /// `since`: whole seconds, or a number followed by s, m, h or d.
    func duration(_ key: String, range: ClosedRange<Int>) throws(ToolArgumentError) -> Int? {
        guard let value = arguments[key] else { return nil }
        let seconds: Int
        if let exact = value.intValue {
            seconds = exact
        } else if let text = value.stringValue {
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            let multiplier: Int
            let digits: Substring
            switch trimmed.last {
            case "s": multiplier = 1; digits = trimmed.dropLast()
            case "m": multiplier = 60; digits = trimmed.dropLast()
            case "h": multiplier = 3600; digits = trimmed.dropLast()
            case "d": multiplier = 86400; digits = trimmed.dropLast()
            default: multiplier = 1; digits = Substring(trimmed)
            }
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
                  let number = Int(digits) else {
                throw ToolArgumentError(
                    "Argument '\(key)' must be seconds or a number with s, m, h or d, like \"90\" or \"15m\" (got \(Self.quoted(text))).")
            }
            let (product, overflow) = number.multipliedReportingOverflow(by: multiplier)
            seconds = overflow ? Int.max : product
        } else {
            throw ToolArgumentError("Argument '\(key)' must be a string like \"15m\" or an integer number of seconds (got \(value.typeDescription)).")
        }
        guard range.contains(seconds) else {
            throw ToolArgumentError("Argument '\(key)' must be between \(range.lowerBound) second and 30 days (got \(seconds) seconds).")
        }
        return seconds
    }

    /// `run_command`'s command: non-empty, ≤ 16 KiB, no NUL, controls or invisible characters
    /// (so the Activity tab shows exactly what runs).
    func command() throws(ToolArgumentError) -> String {
        guard let command = try string("command") else { throw ToolArgumentError("Missing required argument 'command'.") }
        if command.allSatisfy(\.isWhitespace) { throw ToolArgumentError("Argument 'command' must not be empty.") }
        let bytes = command.utf8.count
        if bytes > BridgeLimits.maxCommandBytes {
            throw ToolArgumentError("Argument 'command' is \(bytes) bytes long; the limit is \(BridgeLimits.maxCommandBytes).")
        }
        if command.unicodeScalars.contains("\u{0}") {
            throw ToolArgumentError("Argument 'command' must not contain NUL characters.")
        }
        try Self.checkCharacters(command, key: "command", allowNewlines: true)
        return command
    }

    /// Rejects C0/C1 controls (except tab, and newline when allowed), DEL, and invisible or
    /// direction-changing characters that could make the Activity tab show something other
    /// than what runs.
    static func checkCharacters(_ text: String, key: String, allowNewlines: Bool) throws(ToolArgumentError) {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isControl = v < 0x20 || (0x7F...0x9F).contains(v)
            if isControl {
                if v == 0x09 || (allowNewlines && v == 0x0A) { continue }
                throw ToolArgumentError(
                    "Argument '\(key)' contains control character \(hex(v)); only tab\(allowNewlines ? " and newline are" : " is") allowed.")
            }
            if isInvisible(v) {
                throw ToolArgumentError(
                    "Argument '\(key)' contains invisible or direction-changing character \(hex(v)), which could hide what it says.")
            }
        }
    }

    static func isInvisible(_ v: UInt32) -> Bool {
        switch v {
        case 0x00AD, 0x061C, 0x180E, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF,
             0xFFF9...0xFFFB, 0xE0000...0xE007F:
            true
        default:
            false
        }
    }

    static func hex(_ v: UInt32) -> String {
        let digits = String(v, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// At most 64 characters of `text`.
    static func clip(_ text: String) -> String {
        text.count > 64 ? String(text.prefix(64)) + "…" : text
    }

    /// `text` clipped and quoted with escapes, for echoing back in messages.
    static func quoted(_ text: String) -> String {
        String(reflecting: clip(text))
    }
}

/// Makes untrusted text safe to show in the app's UI (activity list): control
/// characters become spaces, invisible and direction-changing characters are removed, and the
/// result is capped.
public enum DisplayText {
    public static func sanitized(_ text: String, maxLength: Int = 200) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || (0x7F...0x9F).contains(v) {
                scalars.append(" ")
            } else if !ArgumentReader.isInvisible(v) {
                scalars.append(scalar)
            }
        }
        let result = String(scalars).trimmingCharacters(in: .whitespaces)
        return result.count > maxLength ? String(result.prefix(maxLength)) + "…" : result
    }
}
