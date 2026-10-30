import CryptoKit
import Foundation

/// An OpenSSH known_hosts file, edited line by line.
///
/// Lines SSHKit does not understand (comments, blank lines, `@cert-authority`, `@revoked`,
/// unknown key types) are kept verbatim. Matching follows OpenSSH: comma-separated patterns
/// with `*`/`?` wildcards and `!` negation, case-insensitive, and hashed `|1|salt|hmac` names.
/// Marker lines never count as trusted keys.
public struct KnownHostsFile: Sendable, Hashable {
    struct Entry: Sendable, Hashable {
        /// `@cert-authority` or `@revoked`, if present.
        var marker: String?
        /// The comma-separated host field, or a single `|1|...` hashed name.
        var hosts: String
        var key: HostKey
        var comment: String?

        var line: String {
            var fields = [hosts, key.type, key.base64]
            if let marker { fields.insert(marker, at: 0) }
            if let comment { fields.append(comment) }
            return fields.joined(separator: " ")
        }
    }

    enum Line: Sendable, Hashable {
        case entry(Entry)
        case other(String)
    }

    private(set) var lines: [Line]

    /// An empty file.
    public init() {
        lines = []
    }

    /// Parses file contents.
    public init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            return Self.parse(line).map(Line.entry) ?? .other(line)
        }
        // A trailing newline produces one empty element; it is re-added by `text`.
        if case .other("")? = lines.last { lines.removeLast() }
    }

    /// The file contents, newline-terminated.
    public var text: String {
        lines.map { line in
            switch line {
            case .entry(let entry): entry.line
            case .other(let raw): raw
            }
        }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// The name ssh looks up: the lower-cased address, as `[address]:port` unless the port is 22.
    public static func hostName(address: String, port: Int) -> String {
        let name = address.lowercased()
        return port == 22 ? name : "[\(name)]:\(port)"
    }

    /// Trusted keys for `name` (as produced by ``hostName(address:port:)``).
    public func keys(for name: String) -> [HostKey] {
        var keys: [HostKey] = []
        for case .entry(let entry) in lines where entry.marker == nil && Self.matches(entry.hosts, name: name) {
            if !keys.contains(entry.key) { keys.append(entry.key) }
        }
        return keys
    }

    /// Appends `name key` unless that exact key is already trusted for `name`.
    /// Returns whether the file changed.
    @discardableResult
    public mutating func add(_ key: HostKey, for name: String) -> Bool {
        guard !keys(for: name).contains(key) else { return false }
        lines.append(.entry(Entry(marker: nil, hosts: name.lowercased(), key: key, comment: nil)))
        return true
    }

    /// Removes `name` from every unmarked entry that lists it literally (or as a hashed name);
    /// entries left without names are deleted. Wildcard patterns are left alone.
    /// Returns the number of entries changed or deleted.
    @discardableResult
    public mutating func remove(name: String) -> Int {
        let target = name.lowercased()
        var changed = 0
        var result: [Line] = []
        for line in lines {
            guard case .entry(var entry) = line, entry.marker == nil else {
                result.append(line)
                continue
            }
            if entry.hosts.hasPrefix("|") {
                if Self.matchesHashed(entry.hosts, name: target) {
                    changed += 1
                } else {
                    result.append(line)
                }
                continue
            }
            let patterns = entry.hosts.split(separator: ",").map(String.init)
            let kept = patterns.filter { $0.lowercased() != target }
            if kept.count == patterns.count {
                result.append(line)
            } else {
                changed += 1
                if !kept.isEmpty {
                    entry.hosts = kept.joined(separator: ",")
                    result.append(.entry(entry))
                }
            }
        }
        lines = result
        return changed
    }

    /// The names unmarked entries list literally.
    var plainNames: [String] {
        let listed = lines.flatMap { line -> [String] in
            guard case .entry(let entry) = line, entry.marker == nil else { return [] }
            return entry.hosts.lowercased().split(separator: ",").map(String.init)
        }
        return Set(listed.filter(Self.isPlainName)).sorted()
    }

    /// The file without ``plainNames``, comments or blank lines: what only ssh can use (markers,
    /// patterns, hashed names, key types SSHKit does not know).
    var withoutPlainNames: KnownHostsFile {
        var rest = KnownHostsFile()
        rest.lines = lines.compactMap { line in
            switch line {
            case .other(let text): Self.isNote(text) ? nil : line
            case .entry(let entry): Self.withoutPlainNames(entry).map(Line.entry)
            }
        }
        return rest
    }

    private static func isNote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func withoutPlainNames(_ entry: Entry) -> Entry? {
        guard entry.marker == nil else { return entry }
        let rest = entry.hosts.split(separator: ",").map(String.init).filter { !isPlainName($0) }
        guard !rest.isEmpty else { return nil }
        var kept = entry
        kept.hosts = rest.joined(separator: ",")
        return kept
    }

    /// Whether `name` is one literal host: no wildcards, negations, hashing, lists or field breaks.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains { "*?!,|#@".contains($0) || $0.isWhitespace }
    }

    // MARK: - Parsing and matching

    static func parse(_ line: String) -> Entry? {
        var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = fields.first, !first.hasPrefix("#") else { return nil }
        var marker: String?
        if first.hasPrefix("@") {
            marker = first
            fields.removeFirst()
        }
        guard fields.count >= 3, let key = try? HostKey(type: fields[1], base64: fields[2]) else { return nil }
        let comment = fields.count > 3 ? fields[3...].joined(separator: " ") : nil
        return Entry(marker: marker, hosts: fields[0], key: key, comment: comment)
    }

    static func matches(_ hosts: String, name: String) -> Bool {
        let target = name.lowercased()
        if hosts.hasPrefix("|") { return matchesHashed(hosts, name: target) }
        var matched = false
        for pattern in hosts.lowercased().split(separator: ",") {
            if pattern.hasPrefix("!") {
                if glob(Array(pattern.dropFirst().utf8), Array(target.utf8)) { return false }
            } else if glob(Array(pattern.utf8), Array(target.utf8)) {
                matched = true
            }
        }
        return matched
    }

    /// `|1|base64(salt)|base64(HMAC-SHA1(salt, name))`, as written by `HashKnownHosts`.
    static func matchesHashed(_ hosts: String, name: String) -> Bool {
        let parts = hosts.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "1",
              let salt = Data(base64Encoded: String(parts[2])),
              let expected = Data(base64Encoded: String(parts[3])) else { return false }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
        return Data(mac) == expected
    }

    /// OpenSSH `match_pattern`: `*` any run, `?` any one byte.
    static func glob(_ pattern: [UInt8], _ text: [UInt8]) -> Bool {
        var p = 0, t = 0
        var star: Int?, resume = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == UInt8(ascii: "?") || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == UInt8(ascii: "*") {
                star = p
                resume = t
                p += 1
            } else if let s = star {
                p = s + 1
                resume += 1
                t = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == UInt8(ascii: "*") { p += 1 }
        return p == pattern.count
    }
}
