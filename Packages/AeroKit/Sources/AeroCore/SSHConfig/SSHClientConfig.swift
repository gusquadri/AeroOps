import Foundation

/// A parsed OpenSSH client config (`~/.ssh/config`), for importing hosts.
///
/// It follows `ssh_config(5)` and OpenSSH's `readconf.c` where it matters for import:
///
/// - Keywords are case-insensitive; `key value`, `key=value` and `key = value` all work;
///   arguments may be quoted (see ``SSHConfigLexer``); `#` starts a comment.
/// - `Host` blocks match with `*`, `?` and `!` patterns, case-sensitively. Settings before the
///   first `Host` apply to every host. For each setting the **first** value obtained wins, so a
///   `Host *` block at the top overrides later blocks and one at the bottom only fills gaps.
///   `IdentityFile` accumulates instead.
/// - `Include` reads more files in place: `~/` expands to the home directory, relative paths
///   resolve against `~/.ssh`, and globs are expanded in sorted order. An `Include` inside a
///   `Host` block only applies to hosts that block matches. Nesting stops at
///   ``maxIncludeDepth``, a file that includes itself is skipped, and at most ``maxFiles``
///   files are read.
/// - `Match` blocks are not evaluated: their settings are ignored and an ``Issue`` says so.
///   `Match all`, which returns to settings for every host, is the one exception.
/// - Only concrete `Host` names become ``hostAliases``; patterns with `*`, `?` or a leading `!`
///   are never hosts of their own.
///
/// Only `HostName`, `User`, `Port`, `IdentityFile`, `ProxyJump` and `ProxyCommand` are kept.
/// Problems never stop the parse: a malformed line is skipped and reported in ``issues``
/// (which name keywords and line numbers but never quote file contents). A malformed `Host`
/// line starts a block that matches nothing, so its settings can't leak into another host.
///
/// Files are read through ``SSHConfigFileReading`` and never written. Included files named like
/// keys (`id_*` but not `*.pub`, `*.pem`, `*.key`, ...) are never opened, and a file whose text
/// looks like a private key is dropped without being parsed.
public struct SSHClientConfig: Sendable {
    /// `Include` files may nest this deep (OpenSSH's `READCONF_MAX_DEPTH`).
    public static let maxIncludeDepth = 16
    /// At most this many files, top-level included, are read.
    public static let maxFiles = 256
    /// At most this many host names are collected.
    public static let maxHosts = 1_000

    /// A problem found while reading the config.
    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        /// Absolute path of the file.
        public var file: String
        /// 1-based line number, if the problem is on one line.
        public var line: Int?
        /// What happened, e.g. "“Match” blocks aren't evaluated; their settings were ignored."
        public var message: String

        public init(file: String, line: Int?, message: String) {
            self.file = file
            self.line = line
            self.message = message
        }

        /// `config.d/work:12: message`, using the file's last path component.
        public var description: String {
            let name = (file as NSString).lastPathComponent
            return line.map { "\(name):\($0): \(message)" } ?? "\(name): \(message)"
        }
    }

    /// The locations the config was read from.
    public let locations: SSHConfigLocations
    /// Concrete `Host` names, in order of first appearance, without duplicates.
    public let hostAliases: [String]
    /// Problems found, in file order.
    public let issues: [Issue]
    /// Every file read, top-level first.
    public let filesRead: [String]

    let nodes: [Node]

    /// Reads and parses the config at `locations.configFile`.
    ///
    /// - Throws: ``SSHConfigLoadError/notFound(path:)`` if the top-level file doesn't exist, or
    ///   ``SSHConfigLoadError/unreadable(path:reason:)`` if it can't be read.
    public static func load(
        _ locations: SSHConfigLocations,
        files: some SSHConfigFileReading = LocalSSHConfigFiles()
    ) throws(SSHConfigLoadError) -> SSHClientConfig {
        let text: String?
        do {
            text = try files.contents(ofFile: locations.configFile)
        } catch {
            throw .unreadable(path: locations.configFile, reason: error.reason)
        }
        guard let text else { throw .notFound(path: locations.configFile) }
        return SSHClientConfig(text: text, locations: locations, files: files)
    }

    /// Parses `text` as the contents of `locations.configFile`. `Include`s are read through
    /// `files`.
    public init(text: String, locations: SSHConfigLocations, files: some SSHConfigFileReading) {
        var parser = Parser(locations: locations, files: files)
        let top = Self.normalize(locations.configFile)
        nodes = parser.parse(text: text, path: top, chain: [top])
        self.locations = locations
        hostAliases = parser.aliases
        issues = parser.issues
        filesRead = parser.filesRead
    }

    /// The settings OpenSSH would use for `ssh <alias>`.
    public func resolve(_ alias: String) -> SSHConfigHost {
        var resolver = Resolver(alias: alias)
        var active = true
        resolver.walk(nodes, active: &active, neverMatch: false)
        return resolver.host
    }

    /// Every concrete host, resolved, in ``hostAliases`` order.
    public func resolvedHosts() -> [SSHConfigHost] {
        hostAliases.map(resolve)
    }

    static func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    // MARK: - Tree

    /// The parsed structure. `Include` is expanded at parse time, but the matching state is only
    /// known per host, so resolving walks the tree.
    indirect enum Node: Sendable {
        /// `Host` patterns. An empty list (from a malformed line) matches nothing.
        case host([String])
        /// A `Match` line other than `Match all`: never active.
        case match
        /// `Match all`: active for every host.
        case matchAll
        /// The parsed contents of the files one `Include` line matched, in order.
        case include([[Node]])
        /// A kept setting, from an active-or-not block.
        case setting(Setting)
    }

    struct Setting: Sendable, Hashable {
        enum Keyword: String, Sendable, CaseIterable {
            case hostname, user, port, identityfile, proxyjump, proxycommand
        }

        var keyword: Keyword
        /// The single argument (or, for the proxy keywords, the raw remainder of the line).
        var value: String
    }

    // MARK: - Pattern matching

    /// OpenSSH's `match_pattern`: `*` matches any run, `?` any one character, everything else
    /// itself, case-sensitively.
    static func matches(_ text: String, pattern: String) -> Bool {
        let text = Array(text.unicodeScalars)
        let pattern = Array(pattern.unicodeScalars)
        var t = 0, p = 0
        var star: Int?, starText = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" {
                star = p
                starText = t
                p += 1
            } else if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if let star {
                p = star + 1
                starText += 1
                t = starText
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// A `Host` line applies when some pattern matches and no negated (`!`) pattern does.
    static func hostLineMatches(_ alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if matches(alias, pattern: String(pattern.dropFirst())) { return false }
            } else if matches(alias, pattern: pattern) {
                matched = true
            }
        }
        return matched
    }

    /// A pattern that names one host: no wildcard and no negation.
    static func isConcreteHost(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
    }
}

/// The settings OpenSSH would use for one host alias.
public struct SSHConfigHost: Sendable, Hashable {
    /// The `Host` name, as typed after `ssh`.
    public var alias: String
    /// `HostName`, unexpanded (it may contain `%h`); `nil` means the alias is the address.
    public var hostName: String?
    /// `User`; `nil` means ssh would use the local account name.
    public var user: String?
    /// `Port`, as written; `nil` means 22.
    public var port: String?
    /// Every `IdentityFile` that applies, in order, as written. Never read.
    public var identityFiles: [String]
    /// How ssh would reach the host, if not directly.
    public var proxy: Proxy?

    public enum Proxy: Sendable, Hashable {
        /// `ProxyJump` hosts, as written.
        case jump(String)
        /// `ProxyCommand`, as written.
        case command(String)
    }

    public init(
        alias: String, hostName: String? = nil, user: String? = nil, port: String? = nil,
        identityFiles: [String] = [], proxy: Proxy? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxy = proxy
    }
}

/// The top-level config could not be read.
public enum SSHConfigLoadError: Error, Sendable, Hashable, LocalizedError {
    /// There is no file at `path`.
    case notFound(path: String)
    /// The file exists but could not be read.
    case unreadable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "There is no SSH config at \((path as NSString).abbreviatingWithTildeInPath)."
        case .unreadable(let path, let reason):
            "\((path as NSString).abbreviatingWithTildeInPath) could not be read: \(reason)."
        }
    }
}

// MARK: - Parser

private struct Parser {
    let locations: SSHConfigLocations
    let files: any SSHConfigFileReading
    var issues: [SSHClientConfig.Issue] = []
    var aliases: [String] = []
    var seenAliases: Set<String> = []
    var filesRead: [String] = []
    var reportedFileLimit = false
    var reportedHostLimit = false

    init(locations: SSHConfigLocations, files: some SSHConfigFileReading) {
        self.locations = locations
        self.files = files
    }

    /// Parses one file's text. `chain` is the include stack, `path` last.
    mutating func parse(text: String, path: String, chain: [String]) -> [SSHClientConfig.Node] {
        filesRead.append(path)
        if Self.looksLikePrivateKey(text) {
            issues.append(.init(file: path, line: nil, message: "Skipped: this looks like a private key, not an SSH config."))
            return []
        }
        var nodes: [SSHClientConfig.Node] = []
        // Split on scalars: as Characters, "\r\n" is one grapheme and would never match "\n".
        for (index, line) in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            if line.contains("\0") {
                issue(path, number, "The line contains a NUL byte; the text after it was ignored.")
            }
            let directive: SSHConfigDirective
            do {
                guard let parsed = try SSHConfigLexer.directive(in: line) else { continue }
                directive = parsed
            } catch {
                report(error, path, number)
                // A broken Host line still ends the previous block, and matches nothing.
                if error.keyword == "host" { nodes.append(.host([])) }
                if error.keyword == "match" { nodes.append(.match) }
                continue
            }
            if let node = node(for: directive, path: path, line: number, chain: chain) {
                nodes.append(node)
            }
        }
        return nodes
    }

    private mutating func node(
        for directive: SSHConfigDirective, path: String, line: Int, chain: [String]
    ) -> SSHClientConfig.Node? {
        let arguments = directive.arguments
        switch directive.keyword {
        case "host":
            guard !arguments.contains(where: \.isEmpty) else {
                issue(path, line, "“Host” has an empty pattern; the block was ignored.")
                return .host([])
            }
            for pattern in arguments where SSHClientConfig.isConcreteHost(pattern) {
                addAlias(pattern, path: path, line: line)
            }
            return .host(arguments)
        case "match":
            if arguments.count == 1, arguments[0].lowercased() == "all" { return .matchAll }
            issue(path, line, "“Match” blocks aren't evaluated; their settings were ignored.")
            return .match
        case "include":
            return .include(include(arguments, from: path, line: line, chain: chain))
        default:
            guard let keyword = SSHClientConfig.Setting.Keyword(rawValue: directive.keyword) else { return nil }
            switch keyword {
            case .proxyjump:
                // OpenSSH reads the raw text up to any "#".
                let value = directive.rawValue.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
                return .setting(.init(keyword: keyword, value: value))
            case .proxycommand:
                // The rest of the line, verbatim: it is a shell command.
                return .setting(.init(keyword: keyword, value: directive.rawValue))
            case .hostname, .user, .port, .identityfile:
                guard arguments.count == 1 else {
                    issue(path, line, "“\(Self.keywordName(keyword))” takes one value; the line was ignored.")
                    return nil
                }
                return .setting(.init(keyword: keyword, value: arguments[0]))
            }
        }
    }

    private mutating func addAlias(_ alias: String, path: String, line: Int) {
        guard !seenAliases.contains(alias) else { return }
        guard aliases.count < SSHClientConfig.maxHosts else {
            if !reportedHostLimit {
                reportedHostLimit = true
                issue(path, line, "Only the first \(SSHClientConfig.maxHosts) hosts were read.")
            }
            return
        }
        seenAliases.insert(alias)
        aliases.append(alias)
    }

    // MARK: Include

    private mutating func include(_ arguments: [String], from path: String, line: Int, chain: [String]) -> [[SSHClientConfig.Node]] {
        var included: [[SSHClientConfig.Node]] = []
        for argument in arguments where !argument.isEmpty {
            guard let pattern = expand(argument) else {
                issue(path, line, "“Include” paths starting with “~user” aren't supported; it was skipped.")
                continue
            }
            for match in files.paths(matching: pattern) {
                let file = SSHClientConfig.normalize(match)
                let name = (file as NSString).lastPathComponent
                if chain.contains(file) {
                    issue(path, line, "“\(name)” is included in a loop; it was read only once.")
                    continue
                }
                // `Include *` in ~/.ssh would match the keys next to the config: never open them.
                if Self.looksLikeKeyFileName(name) {
                    issue(path, line, "“\(name)” looks like a key file; it was skipped unread.")
                    continue
                }
                if chain.count > SSHClientConfig.maxIncludeDepth {
                    issue(path, line, "Includes are nested more than \(SSHClientConfig.maxIncludeDepth) deep; “\(name)” was skipped.")
                    continue
                }
                if filesRead.count >= SSHClientConfig.maxFiles {
                    if !reportedFileLimit {
                        reportedFileLimit = true
                        issue(path, line, "Only the first \(SSHClientConfig.maxFiles) files were read.")
                    }
                    return included
                }
                do {
                    guard let text = try files.contents(ofFile: file) else { continue }
                    included.append(parse(text: text, path: file, chain: chain + [file]))
                } catch {
                    issue(path, line, "“\(name)” was skipped: \(error.reason).")
                }
            }
        }
        return included
    }

    /// `~/x` → home, `/x` stays, `x` → `~/.ssh/x`. `~user/x` isn't supported.
    private func expand(_ argument: String) -> String? {
        if argument == "~" { return locations.homeDirectory }
        if argument.hasPrefix("~/") { return locations.homeDirectory + argument.dropFirst() }
        if argument.hasPrefix("~") { return nil }
        if argument.hasPrefix("/") { return argument }
        return locations.sshDirectory + "/" + argument
    }

    // MARK: Issues

    private mutating func issue(_ path: String, _ line: Int?, _ message: String) {
        issues.append(.init(file: path, line: line, message: message))
    }

    private mutating func report(_ error: SSHConfigLineError, _ path: String, _ line: Int) {
        let keyword = error.keyword.flatMap(Self.displayKeyword)
        switch error {
        case .missingValue:
            issue(path, line, keyword.map { "“\($0)” has no value; the line was ignored." } ?? "The line has no value; it was ignored.")
        case .unterminatedQuote:
            issue(path, line, keyword.map { "“\($0)” has an unclosed quote; the line was ignored." } ?? "The line has an unclosed quote; it was ignored.")
        case .malformedKeyword:
            issue(path, line, "The line doesn't start with a keyword; it was ignored.")
        }
    }

    /// The keyword's proper name if it is one the importer knows. Any other word (a stray
    /// password or a line of key material, say) is never echoed.
    private static func displayKeyword(_ keyword: String) -> String? {
        if let known = SSHClientConfig.Setting.Keyword(rawValue: keyword) { return keywordName(known) }
        return ["host": "Host", "match": "Match", "include": "Include"][keyword]
    }

    private static func keywordName(_ keyword: SSHClientConfig.Setting.Keyword) -> String {
        switch keyword {
        case .hostname: "HostName"
        case .user: "User"
        case .port: "Port"
        case .identityfile: "IdentityFile"
        case .proxyjump: "ProxyJump"
        case .proxycommand: "ProxyCommand"
        }
    }

    private static func looksLikePrivateKey(_ text: String) -> Bool {
        text.contains("PRIVATE KEY-----") || text.contains("PuTTY-User-Key-File")
    }

    /// `id_*` (but not `*.pub`), `*.pem`, `*.key`, `*.ppk`, `*.p12`, `*.pfx`.
    static func looksLikeKeyFileName(_ name: String) -> Bool {
        let name = name.lowercased()
        if name.hasSuffix(".pub") { return false }
        return name.hasPrefix("id_") || [".pem", ".key", ".ppk", ".p12", ".pfx"].contains { name.hasSuffix($0) }
    }
}

// MARK: - Resolver

private struct Resolver {
    let alias: String
    private(set) var host: SSHConfigHost
    private var proxySet = false

    init(alias: String) {
        self.alias = alias
        host = SSHConfigHost(alias: alias)
    }

    /// OpenSSH's activation rules: `Host` and `Match` lines switch `active`; each included file
    /// starts with the state at its `Include` line, which is restored afterwards; inside an
    /// inactive `Include` nothing ever matches.
    mutating func walk(_ nodes: [SSHClientConfig.Node], active: inout Bool, neverMatch: Bool) {
        for node in nodes {
            switch node {
            case .host(let patterns):
                active = !neverMatch && SSHClientConfig.hostLineMatches(alias, patterns: patterns)
            case .match:
                active = false
            case .matchAll:
                active = !neverMatch
            case .include(let files):
                let outer = active
                for file in files {
                    var inner = outer
                    walk(file, active: &inner, neverMatch: neverMatch || !outer)
                }
                active = outer
            case .setting(let setting):
                if active { apply(setting) }
            }
        }
    }

    /// First value wins, except `IdentityFile`, which accumulates. `ProxyJump` and
    /// `ProxyCommand` share one slot, and `none` fills it without setting a proxy.
    private mutating func apply(_ setting: SSHClientConfig.Setting) {
        switch setting.keyword {
        case .hostname:
            if host.hostName == nil { host.hostName = setting.value }
        case .user:
            if host.user == nil { host.user = setting.value }
        case .port:
            if host.port == nil { host.port = setting.value }
        case .identityfile:
            if setting.value.lowercased() != "none", !host.identityFiles.contains(setting.value) {
                host.identityFiles.append(setting.value)
            }
        case .proxyjump:
            guard !proxySet else { return }
            proxySet = true
            if setting.value.lowercased() != "none" { host.proxy = .jump(setting.value) }
        case .proxycommand:
            guard !proxySet else { return }
            proxySet = true
            if setting.value != "none" { host.proxy = .command(setting.value) }
        }
    }
}
