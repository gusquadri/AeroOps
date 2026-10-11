import Foundation

// The bridge protocol between `aeroops-mcp` and the app:
// one JSON object per line over `~/.aeroops/bridge.sock`, in both directions.
//
//   CLI -> app  request   {"id":7,"tool":"get_logs","arguments":{…},"client":{"name":"claude-code","version":"2.1.296"},"toolUseId":"toolu_…"}
//   CLI -> app  cancel    {"id":7,"cancel":true}
//   app -> CLI  reply     {"id":7,"ok":true,"content":[{"type":"text","text":"…"}],"structuredContent":{…}}
//                         {"id":7,"ok":false,"error":{"code":"denied","message":"…"}}
//   app -> CLI  progress  {"id":7,"progress":{"message":"Waiting for approval"}}
//
// Request ids are minted by the CLI, start at 1 and are unique per connection. A reply with
// id 0 is a connection-level failure (e.g. the peer check refused the CLI): every pending call
// fails with its message, and the app closes the connection.

/// The MCP client as it described itself in `initialize`. Self-reported: any process can claim
/// any name, so the approval panel labels it that way.
public struct BridgeClientInfo: Codable, Sendable, Hashable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    /// `claude-code 2.1.296`.
    public var displayName: String { version.isEmpty ? name : "\(name) \(version)" }
}

/// A tool call forwarded by the CLI.
public struct BridgeRequest: Codable, Sendable, Hashable {
    /// Unique per connection, ≥ 1.
    public var id: Int
    /// MCP tool name, e.g. `get_logs`.
    public var tool: String
    /// The MCP `arguments` object, unvalidated.
    public var arguments: [String: JSONValue]
    /// The MCP client (self-reported), if the CLI saw `initialize`.
    public var client: BridgeClientInfo?
    /// Claude Code's `_meta["claudecode/toolUseId"]`, for correlating the audit log.
    public var toolUseId: String?

    public init(id: Int, tool: String, arguments: [String: JSONValue] = [:], client: BridgeClientInfo? = nil, toolUseId: String? = nil) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
        self.client = client
        self.toolUseId = toolUseId
    }

    private enum CodingKeys: String, CodingKey {
        case id, tool, arguments, client, toolUseId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        tool = try c.decode(String.self, forKey: .tool)
        arguments = try c.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
        client = try c.decodeIfPresent(BridgeClientInfo.self, forKey: .client)
        toolUseId = try c.decodeIfPresent(String.self, forKey: .toolUseId)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tool, forKey: .tool)
        try c.encode(arguments, forKey: .arguments)
        try c.encodeIfPresent(client, forKey: .client)
        try c.encodeIfPresent(toolUseId, forKey: .toolUseId)
    }
}

/// One content block of a reply. Only text for now (MCP `TextContent`).
public struct BridgeContent: Codable, Sendable, Hashable {
    public var type: String
    public var text: String

    public init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }

    public static func text(_ text: String) -> BridgeContent {
        BridgeContent(text: text)
    }
}

/// Machine-readable reason of a failed call. Unknown codes from a newer app decode fine.
public struct BridgeErrorCode: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The tool name is not in the catalog.
    public static let unknownTool = BridgeErrorCode(rawValue: "unknown_tool")
    /// Missing, extra or invalid arguments; the message says which.
    public static let invalidArguments = BridgeErrorCode(rawValue: "invalid_arguments")
    /// No host matches the `host` argument.
    public static let hostNotFound = BridgeErrorCode(rawValue: "host_not_found")
    /// The host's MCP tier is Off.
    public static let hostNotShared = BridgeErrorCode(rawValue: "host_not_shared")
    /// `run_command` on a host whose tier is Read.
    public static let execNotAllowed = BridgeErrorCode(rawValue: "exec_not_allowed")
    /// The user denied the approval.
    public static let denied = BridgeErrorCode(rawValue: "denied")
    /// Nobody answered the approval in time; treated as a denial.
    public static let approvalTimedOut = BridgeErrorCode(rawValue: "approval_timed_out")
    /// The call was cancelled (by the agent or by the user in AeroOps).
    public static let cancelled = BridgeErrorCode(rawValue: "cancelled")
    /// ssh could not reach the host or run the command.
    public static let sshFailed = BridgeErrorCode(rawValue: "ssh_failed")
    /// The command hit its `timeoutSec` and was killed.
    public static let timedOut = BridgeErrorCode(rawValue: "timed_out")
    /// The data is not available (no metrics yet, Docker not installed, …).
    public static let unavailable = BridgeErrorCode(rawValue: "unavailable")
    /// Too many calls in flight on one connection.
    public static let busy = BridgeErrorCode(rawValue: "busy")
    /// The request line was not a valid bridge message.
    public static let malformedRequest = BridgeErrorCode(rawValue: "malformed_request")
    /// The app refused the CLI process (code-signature check); sent with id 0.
    public static let peerRejected = BridgeErrorCode(rawValue: "peer_rejected")
    /// Anything else.
    public static let internalError = BridgeErrorCode(rawValue: "internal")
}

/// A failed call: a code plus one line the model can act on.
public struct BridgeError: Codable, Sendable, Hashable, Error {
    public var code: BridgeErrorCode
    public var message: String

    public init(code: BridgeErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// The app's answer to one request.
public struct BridgeReply: Codable, Sendable, Hashable {
    /// The request id; 0 for a connection-level failure.
    public var id: Int
    public var ok: Bool
    /// Present when `ok`.
    public var content: [BridgeContent]?
    /// Optional structured result when `ok` (MCP `structuredContent`).
    public var structuredContent: JSONValue?
    /// Present when not `ok`.
    public var error: BridgeError?

    /// The id of connection-level failures.
    public static let connectionErrorID = 0

    public init(id: Int, ok: Bool, content: [BridgeContent]? = nil, structuredContent: JSONValue? = nil, error: BridgeError? = nil) {
        self.id = id
        self.ok = ok
        self.content = content
        self.structuredContent = structuredContent
        self.error = error
    }

    /// A successful reply.
    public static func success(id: Int, content: [BridgeContent], structuredContent: JSONValue? = nil) -> BridgeReply {
        BridgeReply(id: id, ok: true, content: content, structuredContent: structuredContent)
    }

    /// A failed reply.
    public static func failure(id: Int, _ code: BridgeErrorCode, _ message: String) -> BridgeReply {
        BridgeReply(id: id, ok: false, error: BridgeError(code: code, message: message))
    }

    /// The text of all content blocks, joined by newlines.
    public var text: String {
        (content ?? []).map(\.text).joined(separator: "\n")
    }
}

/// Progress of a pending call, e.g. while the approval panel is open.
public struct BridgeProgress: Codable, Sendable, Hashable {
    public var id: Int
    public var progress: Info

    public struct Info: Codable, Sendable, Hashable {
        public var message: String

        public init(message: String) {
            self.message = message
        }
    }

    public init(id: Int, message: String) {
        self.id = id
        self.progress = Info(message: message)
    }

    public var message: String { progress.message }
}

/// Asks the app to stop working on a request: dismiss its approval, kill its ssh.
public struct BridgeCancel: Codable, Sendable, Hashable {
    public var id: Int
    public var cancel: Bool

    public init(id: Int) {
        self.id = id
        self.cancel = true
    }
}

/// A line the CLI sends.
public enum BridgeClientMessage: Sendable, Hashable {
    case request(BridgeRequest)
    case cancel(id: Int)
}

/// A line the app sends.
public enum BridgeServerMessage: Sendable, Hashable {
    case reply(BridgeReply)
    case progress(BridgeProgress)

    /// The request id this message belongs to.
    public var id: Int {
        switch self {
        case .reply(let reply): reply.id
        case .progress(let progress): progress.id
        }
    }
}

/// A line that could not be decoded. `id` is set when at least the id was readable, so the
/// receiver can fail just that request.
public struct BridgeDecodingError: Error, Sendable, Hashable, CustomStringConvertible {
    public var id: Int?
    public var reason: String

    public init(id: Int?, reason: String) {
        self.id = id
        self.reason = reason
    }

    public var description: String {
        id.map { "request \($0): \(reason)" } ?? reason
    }
}

/// Encoding and decoding of bridge lines.
public enum BridgeWire {
    /// The JSON encoder used everywhere on the bridge: sorted keys, unescaped slashes, ISO 8601 dates.
    /// JSONEncoder never emits a raw newline (strings escape it), so one value is one line.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The matching decoder (ISO 8601 dates).
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `value` as JSON followed by `\n`.
    public static func line(_ value: some Encodable) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Encodes a client message as one line.
    public static func line(_ message: BridgeClientMessage) throws -> Data {
        switch message {
        case .request(let request): try line(request)
        case .cancel(let id): try line(BridgeCancel(id: id))
        }
    }

    /// Encodes a server message as one line.
    public static func line(_ message: BridgeServerMessage) throws -> Data {
        switch message {
        case .reply(let reply): try line(reply)
        case .progress(let progress): try line(progress)
        }
    }

    private struct Probe: Decodable {
        var id: Int?
        var cancel: Bool?
        var progress: JSONValue?
    }

    /// Decodes a line from the CLI (without its newline).
    public static func decodeClientMessage(_ line: Data) throws(BridgeDecodingError) -> BridgeClientMessage {
        let decoder = makeDecoder()
        guard let probe = try? decoder.decode(Probe.self, from: line) else {
            throw BridgeDecodingError(id: nil, reason: "not a JSON object with a numeric id")
        }
        guard let id = probe.id else { throw BridgeDecodingError(id: nil, reason: "missing id") }
        if probe.cancel == true { return .cancel(id: id) }
        do {
            return .request(try decoder.decode(BridgeRequest.self, from: line))
        } catch {
            throw BridgeDecodingError(id: id, reason: "invalid request: \(Self.describe(error))")
        }
    }

    /// Decodes a line from the app (without its newline).
    public static func decodeServerMessage(_ line: Data) throws(BridgeDecodingError) -> BridgeServerMessage {
        let decoder = makeDecoder()
        guard let probe = try? decoder.decode(Probe.self, from: line) else {
            throw BridgeDecodingError(id: nil, reason: "not a JSON object with a numeric id")
        }
        guard let id = probe.id else { throw BridgeDecodingError(id: nil, reason: "missing id") }
        do {
            if probe.progress != nil {
                return .progress(try decoder.decode(BridgeProgress.self, from: line))
            }
            let reply = try decoder.decode(BridgeReply.self, from: line)
            if !reply.ok && reply.error == nil {
                throw BridgeDecodingError(id: id, reason: "failed reply without an error")
            }
            return .reply(reply)
        } catch let error as BridgeDecodingError {
            throw error
        } catch {
            throw BridgeDecodingError(id: id, reason: "invalid reply: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            "bad value at \(context.codingPath.map(\.stringValue).joined(separator: ".").nonEmpty ?? "top level")"
        default: "\(error)"
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
