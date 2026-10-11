import Foundation

// Shared helpers for the parsers in this folder. Everything here is pure: no I/O, no shell.

// MARK: - Lenient JSON decoding

/// A JSON array decoded element by element; elements that fail to decode are dropped
/// instead of failing the whole array (one odd pod must not hide every other pod).
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            let before = container.currentIndex
            if let value = try? container.decode(Element.self) {
                result.append(value)
                continue
            }
            // A failed decode may or may not advance the container; make sure it does.
            if container.currentIndex == before {
                if (try? container.decodeNil()) == true { continue }
                if (try? container.decode(Discarded.self)) == nil { break }
            }
        }
        elements = result
    }
}

/// Accepts any JSON value and keeps nothing. Used to step over undecodable array elements.
struct Discarded: Decodable {
    init(from decoder: any Decoder) throws {}
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `nil` when it is missing, `null` or of an unexpected type.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    /// A non-empty string for `key`, or `nil`.
    func nonEmptyString(_ key: Key) -> String? {
        guard let value = lenient(String.self, key), !value.isEmpty else { return nil }
        return value
    }
}

/// Decodes `T` from `data`, retrying from the first line that starts with `{` or `[` when the
/// output has junk in front of the JSON (a login banner, a k3s warning merged into stdout).
func decodeJSONTolerantly<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    let decoder = JSONDecoder()
    if let value = try? decoder.decode(type, from: data) { return value }
    let bytes = [UInt8](data)
    var lineStart = 0
    for index in bytes.indices {
        if index == lineStart, index > 0, bytes[index] == UInt8(ascii: "{") || bytes[index] == UInt8(ascii: "[") {
            return try? decoder.decode(type, from: Data(bytes[index...]))
        }
        if bytes[index] == UInt8(ascii: "\n") { lineStart = index + 1 }
    }
    return nil
}

// MARK: - Command error text

/// Helpers for classifying the stderr of a failed remote command.
enum CommandErrorText {
    /// Non-empty, trimmed lines, without the `[exit status N]` markers that `dev/fixtures/capture.sh`
    /// appends to captured error files.
    static func meaningfulLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[exit status ") && $0.hasSuffix("]")) }
    }

    /// The first meaningful line, capped at 500 characters, for a generic error message.
    static func summary(_ text: String) -> String {
        String((meaningfulLines(text).first ?? "").prefix(500))
    }

    /// `true` when `sudo -n` refused to run the command (no NOPASSWD rule, not in sudoers, ...).
    static func isSudoRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("sudo: a password is required")
            || lower.contains("sudo: a terminal is required")
            || lower.contains("sudo: no tty present")
            || lower.contains("sorry, you must have a tty")
            || lower.contains("is not in the sudoers file")
            || lower.contains("is not allowed to execute")
            || (lower.contains("sudo:") && lower.contains("may not run sudo"))
    }

    /// `true` when the shell reported that `command` does not exist
    /// (`sh: docker: not found`, `bash: kubectl: command not found`, `sudo: k3s: command not found`).
    static func isCommandNotFound(_ text: String, commands: [String]) -> Bool {
        meaningfulLines(text).contains { line in
            commands.contains { line.hasSuffix("\($0): not found") || line.hasSuffix("\($0): command not found") }
        }
    }

    /// The strings between double quotes in `text`, in order.
    static func quoted(_ text: some StringProtocol) -> [String] {
        let parts = text.split(separator: "\"", omittingEmptySubsequences: false)
        return stride(from: 1, to: parts.count - 1, by: 2).map { String(parts[$0]) }
    }
}

// MARK: - Timestamps

/// Timestamp parsing for remote output. Manual and locale-free, so it is fast, `Sendable` and
/// never depends on the Mac's calendar settings.
public enum Timestamps {
    /// Parses an RFC 3339 date-time as printed by Kubernetes and Docker:
    /// `2026-10-11T06:55:06Z`, `2026-10-11T06:55:07.379521Z`, `2026-10-11T04:01:14.694177452-03:00`.
    /// Any number of fractional digits is accepted. Returns `nil` for anything else.
    public static func parseRFC3339(_ text: some StringProtocol) -> Date? {
        var scanner = ByteScanner(text.trimmingCharacters(in: .whitespaces))
        guard let moment = scanner.dateTime(separators: [UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: " ")])
        else { return nil }
        let fraction = scanner.fraction()
        guard let offset = scanner.rfc3339Offset(), scanner.isAtEnd else { return nil }
        return Date(timeIntervalSince1970: Double(moment.days * 86_400 + moment.seconds - offset) + fraction)
    }

    /// Parses Docker CLI's `CreatedAt`, e.g. `2026-10-11 03:55:30 -0300 -03`. The trailing zone
    /// abbreviation is ignored; the numeric offset decides.
    public static func parseDockerCreatedAt(_ text: some StringProtocol) -> Date? {
        var scanner = ByteScanner(text.trimmingCharacters(in: .whitespaces))
        guard let moment = scanner.dateTime(separators: [UInt8(ascii: " ")]) else { return nil }
        let fraction = scanner.fraction()
        guard scanner.expect(UInt8(ascii: " ")), let offset = scanner.numericOffset() else { return nil }
        guard scanner.isAtEnd || scanner.expect(UInt8(ascii: " ")) else { return nil }
        return Date(timeIntervalSince1970: Double(moment.days * 86_400 + moment.seconds - offset) + fraction)
    }
}

/// A tiny cursor over ASCII bytes for the timestamp parsers.
private struct ByteScanner {
    let bytes: [UInt8]
    var position = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    var isAtEnd: Bool { position >= bytes.count }

    mutating func expect(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    mutating func expectAny(_ candidates: [UInt8]) -> Bool {
        guard position < bytes.count, candidates.contains(bytes[position]) else { return false }
        position += 1
        return true
    }

    /// Exactly `count` ASCII digits.
    mutating func digits(_ count: Int) -> Int? {
        guard position + count <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[position..<position + count] {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        position += count
        return value
    }

    /// `YYYY-MM-DD<sep>HH:MM:SS` as days since 1970-01-01 and seconds into that day.
    mutating func dateTime(separators: [UInt8]) -> (days: Int, seconds: Int)? {
        guard let year = digits(4), expect(UInt8(ascii: "-")),
              let month = digits(2), expect(UInt8(ascii: "-")),
              let day = digits(2), expectAny(separators),
              let hour = digits(2), expect(UInt8(ascii: ":")),
              let minute = digits(2), expect(UInt8(ascii: ":")),
              let second = digits(2)
        else { return nil }
        guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year),
              hour <= 23, minute <= 59, second <= 60
        else { return nil }
        return (Self.daysFromCivil(year: year, month: month, day: day), hour * 3600 + minute * 60 + min(second, 59))
    }

    /// Optional `.digits`; returns the fraction of a second (0 when absent).
    mutating func fraction() -> Double {
        guard expect(UInt8(ascii: ".")) else { return 0 }
        var value = 0.0
        var scale = 0.1
        while position < bytes.count, bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") {
            value += Double(bytes[position] - UInt8(ascii: "0")) * scale
            scale /= 10
            position += 1
        }
        return value
    }

    /// `Z` or `±HH:MM` (also `±HHMM`), in seconds east of UTC.
    mutating func rfc3339Offset() -> Int? {
        if expectAny([UInt8(ascii: "Z"), UInt8(ascii: "z")]) { return 0 }
        return numericOffset()
    }

    /// `±HHMM` or `±HH:MM`, in seconds east of UTC.
    mutating func numericOffset() -> Int? {
        let sign: Int
        if expect(UInt8(ascii: "+")) { sign = 1 } else if expect(UInt8(ascii: "-")) { sign = -1 } else { return nil }
        guard let hours = digits(2) else { return nil }
        _ = expect(UInt8(ascii: ":"))
        guard let minutes = digits(2), hours <= 23, minutes <= 59 else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

// MARK: - Age

/// Short age strings for list columns, like kubectl's AGE: `45s`, `5m`, `3h`, `2d`, `3y`.
public enum AgeFormat {
    /// Formats a duration in seconds. Negative durations (clock skew) show as `0s`.
    /// Days are used up to two years, as kubectl does, then whole years.
    public static func short(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let s = seconds >= Double(Int.max) ? Int.max : Int(seconds)
        switch s {
        case ..<60: return "\(s)s"
        case ..<3_600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3_600)h"
        case ..<(2 * 365 * 86_400): return "\(s / 86_400)d"
        default: return "\(s / (365 * 86_400))y"
        }
    }

    /// The age of something created at `date`, as of `now`.
    public static func short(since date: Date, now: Date = .now) -> String {
        short(now.timeIntervalSince(date))
    }
}
