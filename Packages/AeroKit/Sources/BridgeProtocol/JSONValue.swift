import Foundation

/// An arbitrary JSON value: tool arguments, JSON schemas and structured tool results.
///
/// The CLI converts it to and from the MCP SDK's `Value`; the app never sees SDK types.
/// Integers and floating-point numbers stay distinct so `tail: 100` round-trips as an integer.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
    /// The string, if this is a string.
    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// The boolean, if this is a boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// The integer, if this is an integer or a floating-point number with no fractional part
    /// (some clients send `100.0` for `100`).
    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            guard value.rounded() == value, let exact = Int(exactly: value) else { return nil }
            return exact
        default:
            return nil
        }
    }

    /// The number as a `Double`, if this is a number.
    public var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// The elements, if this is an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    /// The members, if this is an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    /// `true` for `null`.
    public var isNull: Bool {
        if case .null = self { true } else { false }
    }

    /// Member `key` of an object; `nil` for other values or a missing key.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// "a string", "an integer", … for error messages.
    public var typeDescription: String {
        switch self {
        case .null: "null"
        case .bool: "a boolean"
        case .int: "an integer"
        case .double: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Converts any `Encodable` value (dates as ISO 8601) to a `JSONValue`.
    public init(encoding value: some Encodable) throws {
        let data = try BridgeWire.makeEncoder().encode(value)
        self = try BridgeWire.makeDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON text with sorted keys.
    public func jsonString(pretty: Bool = false) -> String {
        let encoder = BridgeWire.makeEncoder()
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
