import Foundation

/// The distribution a host runs, from the `@@os` section of `Scripts/remote/metrics.sh`: the
/// `ID`, `ID_LIKE`, `NAME`, `PRETTY_NAME` and `VERSION_ID` lines of os-release(5).
///
/// Cards pick the distribution logo from ``id`` and ``idLike``; ``displayName`` is for text.
public struct OSRelease: Codable, Sendable, Hashable {
    /// Lower-case identifier, e.g. `ubuntu`, `debian`, `alpine`, `rhel`.
    public var id: String?
    /// Identifiers of the distributions this one is derived from, closest first, e.g.
    /// `["rhel", "centos", "fedora"]` for Rocky Linux.
    public var idLike: [String]
    /// `NAME`, e.g. `Ubuntu`.
    public var name: String?
    /// `PRETTY_NAME`, e.g. `Ubuntu 24.04.1 LTS`.
    public var prettyName: String?
    /// `VERSION_ID`, e.g. `24.04`.
    public var versionID: String?

    /// Creates a release description.
    public init(id: String? = nil, idLike: [String] = [], name: String? = nil, prettyName: String? = nil, versionID: String? = nil) {
        self.id = id
        self.idLike = idLike
        self.name = name
        self.prettyName = prettyName
        self.versionID = versionID
    }

    /// `PRETTY_NAME`, else `NAME` and `VERSION_ID`, else `ID`.
    public var displayName: String? {
        if let prettyName { return prettyName }
        if let name { return [name, versionID].compactMap(\.self).joined(separator: " ") }
        return id
    }

    /// Parses os-release lines (`KEY=value`, values optionally quoted). Unknown keys, comments
    /// and malformed lines are skipped; a repeated key keeps its first value. `nil` when none of
    /// the five keys has a value.
    public init?(lines: some Sequence<some StringProtocol>) {
        var values: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals])
            guard values[key] == nil, let value = Self.unquote(trimmed[trimmed.index(after: equals)...]), !value.isEmpty
            else { continue }
            values[key] = value
        }
        let idLike = (values["ID_LIKE"] ?? "").split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let release = OSRelease(
            id: values["ID"]?.lowercased(),
            idLike: idLike,
            name: values["NAME"],
            prettyName: values["PRETTY_NAME"],
            versionID: values["VERSION_ID"]
        )
        guard release.id != nil || !idLike.isEmpty || release.name != nil || release.prettyName != nil || release.versionID != nil
        else { return nil }
        self = release
    }

    /// An os-release value without its shell quoting: `"Ubuntu 24.04 LTS"`, `'Alpine'` or a bare
    /// word. Inside double quotes, a backslash escapes `"`, `\`, `$` and `` ` ``. `nil` for an
    /// unterminated quote.
    static func unquote(_ raw: Substring) -> String? {
        guard let quote = raw.first, quote == "\"" || quote == "'" else {
            return String(raw)
        }
        var result = ""
        var escaped = false
        for character in raw.dropFirst() {
            if escaped {
                if !"\"\\$`".contains(character) { result.append("\\") }
                result.append(character)
                escaped = false
            } else if character == "\\" && quote == "\"" {
                escaped = true
            } else if character == quote {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }
}
