import Foundation
import Testing
@testable import AeroCore
import AeroTestSupport

/// An in-memory, read-only file system for `Include` tests.
private struct MemoryFiles: SSHConfigFileReading {
    var files: [String: String] = [:]
    var failures: [String: SSHConfigFileError] = [:]

    func contents(ofFile path: String) throws(SSHConfigFileError) -> String? {
        if let failure = failures[path] { throw failure }
        return files[path]
    }

    func paths(matching pattern: String) -> [String] {
        Set(files.keys).union(failures.keys)
            .filter { fnmatch(pattern, $0, FNM_PATHNAME | FNM_PERIOD) == 0 }
            .sorted()
    }
}

private let testLocations = SSHConfigLocations(
    configFile: "/home/tester/.ssh/config", sshDirectory: "/home/tester/.ssh", homeDirectory: "/home/tester"
)

private func parse(_ text: String, files: [String: String] = [:], failures: [String: SSHConfigFileError] = [:]) -> SSHClientConfig {
    SSHClientConfig(text: text, locations: testLocations, files: MemoryFiles(files: files, failures: failures))
}

private func messages(_ config: SSHClientConfig) -> [String] {
    config.issues.map(\.message)
}

@Suite("SSH config lexer")
struct SSHConfigLexerTests {
    private func arguments(_ line: String) throws -> [String]? {
        try SSHConfigLexer.directive(in: line.unicodeScalars)?.arguments
    }

    @Test("blank and comment lines are skipped")
    func blankAndComments() throws {
        #expect(try SSHConfigLexer.directive(in: "".unicodeScalars) == nil)
        #expect(try SSHConfigLexer.directive(in: "   \t ".unicodeScalars) == nil)
        #expect(try SSHConfigLexer.directive(in: "# Host web".unicodeScalars) == nil)
        #expect(try SSHConfigLexer.directive(in: "\t  # indented".unicodeScalars) == nil)
    }

    @Test("key value, key=value and key = value are the same")
    func separators() throws {
        for line in ["Port 22", "Port=22", "Port = 22", "Port =22", "Port\t\t22", "  port 22  ", "PORT 22\u{0C}"] {
            let directive = try #require(try SSHConfigLexer.directive(in: line.unicodeScalars), "\(line)")
            #expect(directive.keyword == "port", "\(line)")
            #expect(directive.arguments == ["22"], "\(line)")
        }
    }

    @Test("quotes, escapes and comments follow argv_split")
    func quoting() throws {
        #expect(try arguments(#"IdentityFile "~/.ssh/my key""#) == ["~/.ssh/my key"])
        #expect(try arguments("IdentityFile '~/.ssh/my key'") == ["~/.ssh/my key"])
        #expect(try arguments(#"IdentityFile ~/.ssh/my\ key"#) == ["~/.ssh/my key"])
        #expect(try arguments(#"User "a\"b""#) == [#"a"b"#])
        #expect(try arguments(#"User "de""ploy""#) == ["deploy"])
        #expect(try arguments(#"User 'it"s'"#) == [#"it"s"#])
        #expect(try arguments(#"HostName a\b"#) == [#"a\b"#])
        #expect(try arguments("HostName a#b") == ["a#b"])
        #expect(try arguments("HostName example.com # a comment") == ["example.com"])
        #expect(try arguments("HostName example.com #") == ["example.com"])
        #expect(try arguments(#"Host one "two three" # trailing"#) == ["one", "two three"])
        #expect(try arguments(#"Host """#) == [""])
    }

    @Test("the raw value keeps the line as written, for ProxyCommand")
    func rawValue() throws {
        let directive = try #require(try SSHConfigLexer.directive(in: "ProxyCommand  ssh -W %h:%p 'jump host'".unicodeScalars))
        #expect(directive.rawValue == "ssh -W %h:%p 'jump host'")
    }

    @Test("malformed lines throw with the keyword")
    func malformed() {
        #expect(throws: SSHConfigLineError.missingValue(keyword: "user")) {
            try SSHConfigLexer.directive(in: "User".unicodeScalars)
        }
        #expect(throws: SSHConfigLineError.missingValue(keyword: "user")) {
            try SSHConfigLexer.directive(in: "User =  ".unicodeScalars)
        }
        #expect(throws: SSHConfigLineError.missingValue(keyword: "user")) {
            try SSHConfigLexer.directive(in: "User # only a comment".unicodeScalars)
        }
        #expect(throws: SSHConfigLineError.unterminatedQuote(keyword: "hostname")) {
            try SSHConfigLexer.directive(in: #"HostName "a.example.com"#.unicodeScalars)
        }
        #expect(throws: SSHConfigLineError.malformedKeyword) {
            try SSHConfigLexer.directive(in: #""Host" web"#.unicodeScalars)
        }
    }

    @Test("a NUL ends the line")
    func nul() throws {
        #expect(try arguments("HostName a.example.com\0; reboot") == ["a.example.com"])
    }
}

@Suite("SSH config parser")
struct SSHClientConfigTests {
    @Test("Host blocks with HostName, User, Port and IdentityFile")
    func basicBlocks() {
        let config = parse("""
            Host web
                HostName 192.0.2.10
                User deploy
                Port 2200
                IdentityFile ~/.ssh/id_web

            Host db
                HostName db.example.com
            """)
        #expect(config.hostAliases == ["web", "db"])
        #expect(config.issues.isEmpty)
        #expect(config.resolve("web") == SSHConfigHost(
            alias: "web", hostName: "192.0.2.10", user: "deploy", port: "2200", identityFiles: ["~/.ssh/id_web"]))
        #expect(config.resolve("db") == SSHConfigHost(alias: "db", hostName: "db.example.com"))
        #expect(config.resolve("unknown") == SSHConfigHost(alias: "unknown"))
    }

    @Test("keywords are case-insensitive")
    func caseInsensitiveKeywords() {
        let config = parse("""
            HOST web
              hOsTnAmE web.example.com
              USER Deploy
              pOrT=2222
            """)
        #expect(config.resolve("web") == SSHConfigHost(alias: "web", hostName: "web.example.com", user: "Deploy", port: "2222"))
    }

    @Test("Host patterns match case-sensitively, as OpenSSH does")
    func caseSensitivePatterns() {
        let config = parse("""
            Host WEB
                User upper
            Host web
                HostName web.example.com
            """)
        #expect(config.hostAliases == ["WEB", "web"])
        #expect(config.resolve("web").user == nil)
        #expect(config.resolve("WEB").user == "upper")
    }

    @Test("several names on one Host line share the block; duplicates are listed once")
    func multipleNames() {
        let config = parse("""
            Host a b
                User shared
            Host b c
                User second
            """)
        #expect(config.hostAliases == ["a", "b", "c"])
        #expect(config.resolve("b").user == "shared")
        #expect(config.resolve("c").user == "second")
    }

    @Test("settings before the first Host apply to every host")
    func globalSettings() {
        let config = parse("""
            # comment
            User everyone
            Port 2200

            Host web
                User web-user
            """)
        #expect(config.resolve("web").user == "everyone")
        #expect(config.resolve("web").port == "2200")
    }

    // MARK: Host * and patterns

    @Test("Host * at the top wins over later blocks; at the bottom it only fills gaps")
    func hostStarFirstValueWins() {
        let top = parse("""
            Host *
                User top
            Host web
                User web
                Port 2200
            """)
        #expect(top.resolve("web").user == "top")
        #expect(top.resolve("web").port == "2200")

        let bottom = parse("""
            Host web
                User web
            Host *
                User bottom
                Port 2200
            """)
        #expect(bottom.resolve("web").user == "web")
        #expect(bottom.resolve("web").port == "2200")
    }

    @Test("a negated pattern switches the whole block off for that host")
    func negation() {
        let config = parse("""
            Host bastion
                HostName bastion.example.com
            Host web
                HostName web.example.com
            Host * !bastion
                User most
            Host !web
                User never-applies
            """)
        #expect(config.resolve("bastion").user == nil)
        #expect(config.resolve("web").user == "most")
        #expect(config.resolve("other").user == "most")
    }

    @Test("? matches one character, * any run")
    func wildcards() {
        let config = parse("""
            Host web-?
                Port 2201
            Host *.example.org
                User ops
            Host web-1 web-10 build.example.org
            """)
        #expect(config.resolve("web-1").port == "2201")
        #expect(config.resolve("web-10").port == nil)
        #expect(config.resolve("build.example.org").user == "ops")
        #expect(SSHClientConfig.matches("abc", pattern: "a*c"))
        #expect(SSHClientConfig.matches("ac", pattern: "a*c"))
        #expect(SSHClientConfig.matches("a.b.c", pattern: "*.*"))
        #expect(!SSHClientConfig.matches("abc", pattern: "a?"))
        #expect(SSHClientConfig.matches("", pattern: "*"))
        #expect(!SSHClientConfig.matches("", pattern: "?"))
    }

    @Test("patterns with *, ? or ! are never imported as hosts")
    func patternsAreNotHosts() {
        let config = parse("""
            Host * web-* db? !bastion *.example.com real
                User x
            Host !only-negated
            """)
        #expect(config.hostAliases == ["real"])
    }

    @Test("IdentityFile accumulates in order, without duplicates or none")
    func identityFiles() {
        let config = parse("""
            Host web
                IdentityFile ~/.ssh/id_web
                IdentityFile none
            Host *
                IdentityFile ~/.ssh/id_default
                IdentityFile ~/.ssh/id_web
            """)
        #expect(config.resolve("web").identityFiles == ["~/.ssh/id_web", "~/.ssh/id_default"])
    }

    // MARK: Proxies

    @Test("ProxyJump and ProxyCommand share one slot; the first wins, and none fills it")
    func proxies() {
        let config = parse("""
            Host jump
                ProxyJump bastion # through the bastion
            Host chain
                ProxyJump deploy@jump1.example.com:2222,jump2
            Host command
                ProxyCommand ssh -W %h:%p jump
                ProxyJump ignored
            Host direct
                ProxyJump none
            Host *
                ProxyJump fallback
            """)
        #expect(config.resolve("jump").proxy == .jump("bastion"))
        #expect(config.resolve("chain").proxy == .jump("deploy@jump1.example.com:2222,jump2"))
        #expect(config.resolve("command").proxy == .command("ssh -W %h:%p jump"))
        #expect(config.resolve("direct").proxy == nil)
        #expect(config.resolve("other").proxy == .jump("fallback"))
    }

    // MARK: Match

    @Test("Match blocks are skipped and reported")
    func matchSkipped() {
        let config = parse("""
            Match host web exec "touch /tmp/pwned"
                User from-match
                HostName evil.example.com
            Host web
                User web
            Match originalhost db
                Port 9999
            """)
        #expect(config.resolve("web").user == "web")
        #expect(config.resolve("web").hostName == nil)
        #expect(config.resolve("web").port == nil)
        #expect(config.issues.count == 2)
        #expect(config.issues.map(\.line) == [1, 6])
        #expect(messages(config).allSatisfy { $0.contains("“Match”") && !$0.contains("touch") })
    }

    @Test("Match all applies to every host")
    func matchAll() {
        let config = parse("""
            Host web
                User web
            Match all
                Port 2222
            """)
        #expect(config.resolve("web").port == "2222")
        #expect(config.resolve("other").port == "2222")
        #expect(config.issues.isEmpty)
    }

    @Test("a malformed Match line still ends the previous block")
    func malformedMatch() {
        let config = parse("""
            Host web
                HostName web.example.com
            Match exec "unclosed
                User leaked
            """)
        #expect(config.resolve("web").user == nil)
        #expect(config.issues.count == 1)
    }

    // MARK: Include

    @Test("relative Include resolves against ~/.ssh; ~/ against home; absolute stays")
    func includePaths() {
        let config = parse("""
            Include relative.conf
            Include ~/elsewhere/home.conf
            Include /etc/ssh/absolute.conf
            """, files: [
                "/home/tester/.ssh/relative.conf": "Host relative\n  HostName r.example.com",
                "/home/tester/elsewhere/home.conf": "Host home\n  HostName h.example.com",
                "/etc/ssh/absolute.conf": "Host absolute\n  HostName a.example.com",
            ])
        #expect(config.hostAliases == ["relative", "home", "absolute"])
        #expect(config.resolve("home").hostName == "h.example.com")
        #expect(config.filesRead == [
            "/home/tester/.ssh/config", "/home/tester/.ssh/relative.conf",
            "/home/tester/elsewhere/home.conf", "/etc/ssh/absolute.conf",
        ])
        #expect(config.issues.isEmpty)
    }

    @Test("Include globs are read in sorted order, and several arguments in order")
    func includeGlobs() {
        let config = parse("""
            Include conf.d/*.conf last.conf
            """, files: [
                "/home/tester/.ssh/conf.d/b.conf": "Host bravo\nHost *\n  User from-b",
                "/home/tester/.ssh/conf.d/a.conf": "Host alpha\nHost *\n  User from-a",
                "/home/tester/.ssh/conf.d/.hidden.conf": "Host hidden",
                "/home/tester/.ssh/conf.d/c.txt": "Host txt",
                "/home/tester/.ssh/last.conf": "Host last",
            ])
        #expect(config.hostAliases == ["alpha", "bravo", "last"])
        #expect(config.resolve("last").user == "from-a")
    }

    @Test("a missing Include is silent, like OpenSSH")
    func includeMissing() {
        let config = parse("Include nope.conf conf.d/*\nHost web")
        #expect(config.hostAliases == ["web"])
        #expect(config.issues.isEmpty)
    }

    @Test("Include inside a Host block applies only to that host")
    func includeInsideHost() {
        let config = parse("""
            Host a
                Include a-settings.conf
                Port 2200
            Host b
                HostName b.example.com
            """, files: [
                "/home/tester/.ssh/a-settings.conf": "User only-a\nHostName a.example.com\nHost other\n  User other",
            ])
        #expect(config.resolve("a").user == "only-a")
        #expect(config.resolve("a").hostName == "a.example.com")
        // The Host line inside the include doesn't end Host a's block in the including file.
        #expect(config.resolve("a").port == "2200")
        #expect(config.resolve("b").user == nil)
        // An Include in an inactive block never matches anything, even its own Host lines.
        #expect(config.hostAliases == ["a", "other", "b"])
        #expect(config.resolve("other").user == nil)
    }

    @Test("a file that includes itself is read once and reported")
    func includeLoop() {
        let top = "Include loop.conf\nHost top"
        let config = parse(top, files: [
            "/home/tester/.ssh/config": top,
            "/home/tester/.ssh/loop.conf": "Host looped\nInclude loop.conf\nInclude config",
        ])
        #expect(config.hostAliases == ["looped", "top"])
        #expect(config.filesRead == ["/home/tester/.ssh/config", "/home/tester/.ssh/loop.conf"])
        #expect(config.issues.count == 2)
        #expect(messages(config).allSatisfy { $0.contains("loop") })
    }

    @Test("Include nesting stops at 16 levels")
    func includeDepth() {
        var files: [String: String] = [:]
        for level in 0..<20 {
            files["/home/tester/.ssh/f\(level).conf"] = "Host h\(level)\nInclude f\(level + 1).conf"
        }
        let config = parse("Include f0.conf", files: files)
        // config is depth 0, f0 depth 1, ..., f15 depth 16.
        #expect(config.hostAliases == (0..<16).map { "h\($0)" })
        #expect(config.issues.count == 1)
        #expect(config.issues.first?.file == "/home/tester/.ssh/f15.conf")
        #expect(config.issues.first?.message.contains("16") == true)
    }

    @Test("at most 256 files are read")
    func includeFileLimit() {
        var files: [String: String] = [:]
        for index in 0..<300 {
            files[String(format: "/home/tester/.ssh/many/%03ld.conf", index)] = "Host many-\(index)"
        }
        let config = parse("Include many/*.conf", files: files)
        #expect(config.filesRead.count == SSHClientConfig.maxFiles)
        #expect(config.hostAliases.count == SSHClientConfig.maxFiles - 1)
        #expect(config.issues.count == 1)
    }

    @Test("at most 1000 hosts are collected")
    func hostLimit() {
        let text = (0..<1_005).map { "Host h\($0)" }.joined(separator: "\n")
        let config = parse(text)
        #expect(config.hostAliases.count == SSHClientConfig.maxHosts)
        #expect(config.issues.count == 1)
    }

    @Test("~user includes and unreadable files are reported")
    func includeProblems() {
        let config = parse("""
            Include ~root/.ssh/config
            Include broken.conf
            Host web
            """, failures: ["/home/tester/.ssh/broken.conf": .notARegularFile])
        #expect(config.hostAliases == ["web"])
        #expect(config.issues.map(\.line) == [1, 2])
        #expect(config.issues[1].message.contains("not a regular file"))
    }

    // MARK: Malformed and hostile input

    @Test("malformed lines are skipped and reported with their line number")
    func malformedLines() {
        let config = parse("""
            Host web
                User
                HostName "web.example.com
                Port 22 23
                IdentityFile a b
                "Quoted keyword" value
                ServerAliveInterval
                UnknownKeyword some value
                HostName web.example.com
            """)
        #expect(config.resolve("web") == SSHConfigHost(alias: "web", hostName: "web.example.com"))
        #expect(config.issues.map(\.line) == [2, 3, 4, 5, 6, 7])
        #expect(config.issues[0].message == "“User” has no value; the line was ignored.")
        #expect(config.issues[1].message == "“HostName” has an unclosed quote; the line was ignored.")
        #expect(config.issues[2].message == "“Port” takes one value; the line was ignored.")
        #expect(config.issues[5].message == "The line has no value; it was ignored.")
        #expect(config.issues[0].description == "config:2: “User” has no value; the line was ignored.")
    }

    @Test("a broken Host line ends the previous block and matches nothing")
    func brokenHostIsABarrier() {
        let config = parse("""
            Host web
            Host ""
                User leaked-empty
            Host "unclosed
                Port 9999
            Host db
            """)
        #expect(config.hostAliases == ["web", "db"])
        #expect(config.resolve("web").user == nil)
        #expect(config.resolve("web").port == nil)
        #expect(config.issues.count == 2)
    }

    @Test("CRLF line endings, tabs and form feeds")
    func lineEndings() {
        let config = parse("Host web\r\n\tHostName\tweb.example.com\r\n\tUser deploy\u{0C}\r\n")
        #expect(config.resolve("web") == SSHConfigHost(alias: "web", hostName: "web.example.com", user: "deploy"))
        #expect(config.issues.isEmpty)
    }

    @Test("a NUL byte truncates the line and is reported")
    func nulByte() {
        let config = parse("Host web\nHostName web.example.com\0 evil\n")
        #expect(config.resolve("web").hostName == "web.example.com")
        #expect(config.issues.map(\.line) == [2])
    }

    @Test("issues never echo what a line contains")
    func issuesDoNotEchoContents() {
        let secret = "hunter2" + "SuperSecret"
        let config = parse("""
            \(secret)
            password \(secret.lowercased()) "unclosed
            "\(secret)" x
            Host \(secret)\u{1B}[2J "
            """)
        #expect(config.issues.count == 4)
        for issue in config.issues {
            #expect(!issue.description.lowercased().contains(secret.lowercased()))
            #expect(!issue.description.contains("\u{1B}"))
        }
    }

    @Test("files named like keys are never opened; files that look like keys are dropped")
    func privateKeys() {
        // Built at run time, so no key-shaped text sits in the repo. Not a real key.
        let begin = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
        let end = "-----END OPENSSH " + "PRIVATE KEY-----"
        let body = "b3BlbnNzaC1rZXktdjEAAAAAnotarealkeyAAAA"
        let keyText = "\(begin)\n\(body)\n\(end)\n"
        let config = parse("""
            Include *
            Host web
            """, files: [
                "/home/tester/.ssh/id_ed25519": keyText,
                "/home/tester/.ssh/id_ed25519.pub": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAInotarealkey test",
                "/home/tester/.ssh/server.pem": keyText,
                "/home/tester/.ssh/stray": keyText,
                "/home/tester/.ssh/work.conf": "Host work",
            ])
        #expect(config.hostAliases == ["work", "web"])
        #expect(!config.filesRead.contains("/home/tester/.ssh/id_ed25519"))
        #expect(!config.filesRead.contains("/home/tester/.ssh/server.pem"))
        #expect(config.filesRead.contains("/home/tester/.ssh/stray"))
        #expect(config.resolve("work").identityFiles.isEmpty)
        let text = config.issues.map(\.description).joined(separator: "\n")
        #expect(!text.contains(body))
        #expect(!text.contains("BEGIN"))
        #expect(text.contains("“id_ed25519” looks like a key file"))
        #expect(text.contains("“server.pem” looks like a key file"))
        #expect(text.contains("stray: Skipped: this looks like a private key"))

        let topLevel = parse(keyText)
        #expect(topLevel.hostAliases.isEmpty)
        #expect(topLevel.issues.count == 1)
    }
}

@Suite("SSH config import planner")
struct SSHConfigImportTests {
    private func plan(
        _ text: String, existing: [RemoteHost] = [], localUser: String = "tester"
    ) -> [SSHConfigImportCandidate] {
        var counter = 0
        return SSHConfigImport.candidates(from: parse(text), existingHosts: existing, localUser: localUser) {
            counter += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", counter))!
        }
    }

    @Test("a plain host becomes a ready RemoteHost with no key and the default MCP tier")
    func readyHost() throws {
        let candidates = plan("""
            Host web
                HostName 192.0.2.10
                User deploy
                Port 2200
            """)
        let web = try #require(candidates.first)
        #expect(web.status == .ready)
        #expect(web.isSelectable && web.isSelectedByDefault && !web.isRenamed && !web.usesLocalUser)
        #expect(web.host == RemoteHost(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "web", address: "192.0.2.10", port: 2200, user: "deploy"))
        #expect(web.host.keyId == nil && web.host.tags.isEmpty && web.host.mcpTier == .default)
    }

    @Test("the alias is the address without HostName; %h and %% expand")
    func addresses() {
        let candidates = plan("""
            Host web.example.com
            Host pi
                HostName %h.local
            Host pct
                HostName %%h.example.com
            Host other
                HostName %d.example.com
            """)
        #expect(candidates.map(\.host.address) == ["web.example.com", "pi.local", "%h.example.com", "%d.example.com"])
        // "%h.example.com" (from %%h) contains a "%" but passes the editor's character rule.
        #expect(candidates[2].status == .ready)
        #expect(candidates[3].status == .unsupported(reason: "HostName “%d.example.com” uses a % token AeroOps can't expand."))
    }

    @Test("without a User, the local account name is used and flagged")
    func localUser() {
        let candidates = plan("Host web\nHost bad", localUser: "tester")
        #expect(candidates[0].host.user == "tester")
        #expect(candidates[0].usesLocalUser)
        let invalid = plan("Host web", localUser: "John Smith")
        #expect(invalid[0].status == .unsupported(reason: "The config has no User, and your account name “John Smith” can't be used."))
    }

    @Test("hosts already in AeroOps are marked and unchecked; names stay unique")
    func duplicates() {
        let existing = [
            RemoteHost(name: "web-01", address: "WEB.example.com", user: "deploy"),
            RemoteHost(name: "nas", address: "nas.local", user: "admin"),
        ]
        let candidates = plan("""
            Host web-01
                HostName web.example.com
                User deploy
            Host NAS
                HostName nas.local
                User admin
                Port 5022
            Host nas-alias
                HostName nas.local
                User admin
                Port 5022
            Host web-01-root
                HostName web.example.com
                User root
            """, existing: existing)
        #expect(candidates[0].status == .alreadyAdded(existingName: "web-01"))
        #expect(!candidates[0].isSelectedByDefault && candidates[0].isSelectable)
        #expect(candidates[0].host.name == "web-01 2")
        #expect(candidates[1].status == .ready)
        #expect(candidates[1].host.name == "NAS 2")
        #expect(candidates[1].isRenamed)
        #expect(candidates[2].status == .sameAsEarlier(alias: "NAS"))
        #expect(!candidates[2].isSelectedByDefault)
        #expect(candidates[3].status == .ready)
    }

    @Test("jump hosts and proxy commands are unsupported, not dropped")
    func proxiesUnsupported() {
        let candidates = plan("""
            Host inner
                HostName 10.0.0.5
                ProxyJump bastion
            Host legacy
                ProxyCommand nc -X connect -x proxy:8080 %h %p
            Host direct
                ProxyJump none
            Host inner
            """)
        #expect(candidates[0].status == .unsupported(reason: "Connects through ProxyJump “bastion”. AeroOps can't use jump hosts yet."))
        #expect(candidates[1].status == .unsupported(reason: "Connects through a ProxyCommand. AeroOps can't use proxy commands yet."))
        #expect(!candidates[0].isSelectable && !candidates[0].isSelectedByDefault)
        #expect(candidates[2].status == .ready)
        #expect(candidates.count == 3)
    }

    @Test("unsupported hosts neither take a name nor count as earlier entries")
    func unsupportedTakesNoName() {
        let candidates = plan("""
            Host first
                HostName web.example.com
                ProxyJump bastion
            Host FIRST
                HostName web.example.com
            """)
        #expect(candidates[1].status == .ready)
        #expect(candidates[1].host.name == "FIRST")
    }

    @Test("IdentityFile paths are carried as a note only")
    func identityFilesAreNotes() {
        let candidates = plan("""
            Host web
                IdentityFile ~/.ssh/id_web
            """)
        #expect(candidates[0].identityFiles == ["~/.ssh/id_web"])
        #expect(candidates[0].host.keyId == nil)
    }

    @Test("hostile values are refused before they reach ssh")
    func hostileValues() {
        let candidates = plan("""
            Host option
                HostName "-oProxyCommand=touch /tmp/pwned"
            Host subshell
                HostName $(reboot)
            Host backtick
                HostName `id`.example.com
            Host semicolon
                User root;reboot
            Host dashuser
                User -oProxyCommand=x
            Host spaceuser
                User "a b"
            Host badport
                Port 22abc
            Host bigport
                Port 70000
            Host zeroport
                Port 0
            Host dotfirst
                HostName .example.com
            Host esc\u{1B}[2Jname
            Host fine
                HostName fe80::1%%en0
            """)
        let byAlias = Dictionary(uniqueKeysWithValues: candidates.map { ($0.alias, $0) })
        for alias in ["option", "subshell", "backtick", "semicolon", "dashuser", "spaceuser", "badport", "bigport", "zeroport", "dotfirst", "esc\u{1B}[2Jname"] {
            #expect(byAlias[alias]?.isSelectable == false, "\(alias)")
        }
        #expect(byAlias["fine"]?.status == .ready)
        for candidate in candidates {
            if case .unsupported(let reason) = candidate.status {
                #expect(!reason.contains("\u{1B}"))
                #expect(!reason.contains("\n"))
            }
        }
        #expect(byAlias["option"]?.status == .unsupported(reason: "The address “-oProxyCommand=touch /tmp/pwned” isn't a plain host name or IP address."))
        #expect(byAlias["badport"]?.status == .unsupported(reason: "Port “22abc” isn't a number from 1 to 65535."))
    }

    @Test("long names are shortened to fit the host editor")
    func longNames() {
        let alias = String(repeating: "a", count: 80)
        let candidates = plan("Host \(alias)\n  HostName 192.0.2.1\nHost \(alias)b\n  HostName 192.0.2.2")
        #expect(candidates[0].host.name.count == 60)
        #expect(candidates[1].host.name == String(repeating: "a", count: 60) + " 2")
    }

    @Test("displaySafe replaces control and bidi characters and shortens")
    func displaySafe() {
        #expect(SSHConfigImport.displaySafe("a\u{1B}[31mb\u{202E}c\nd") == "a\u{FFFD}[31mb\u{FFFD}c\u{FFFD}d")
        #expect(SSHConfigImport.displaySafe(String(repeating: "x", count: 10), limit: 4) == "xxxx…")
        #expect(SSHConfigImport.displaySafe("café ✓") == "café ✓")
    }
}

@Suite("SSH config files")
struct SSHConfigFilesTests {
    @Test("the fixture config, read from disk with includes")
    func fixture() throws {
        let url = try Fixtures.url("ssh-config/config")
        let locations = SSHConfigLocations.standalone(configFile: url)
        let config = try SSHClientConfig.load(locations)
        #expect(config.hostAliases == [
            "staging", "lab-1", "lab-2", "nas", "pi", "web-prod", "web-prod-alias", "db", "bastion",
            "app-behind-bastion", "legacy", "web-01", "build.example.org", "sketchy",
        ])
        #expect(config.filesRead.map { ($0 as NSString).lastPathComponent } == [
            "config", "10-work.conf", "30-lab.conf", "20-home.conf", "90-loop.conf",
        ])
        #expect(config.issues.count == 2)
        #expect(config.issues.contains { $0.message.contains("loop") })
        #expect(config.issues.contains { $0.message.contains("Match") })

        #expect(config.resolve("staging") == SSHConfigHost(
            alias: "staging", hostName: "198.51.100.20", user: "ubuntu",
            identityFiles: ["~/.ssh/id_ed25519_work", "~/.ssh/id_rsa_default"]))
        #expect(config.resolve("db") == SSHConfigHost(
            alias: "db", hostName: "db1.internal.example.com", user: "postgres", port: "2222",
            identityFiles: ["~/.ssh/id_rsa_default"]))
        #expect(config.resolve("pi").user == "fallback")
        #expect(config.resolve("web-prod").user == "deploy")
        #expect(config.resolve("bastion") == SSHConfigHost(alias: "bastion", hostName: "bastion.example.com"))
        #expect(config.resolve("build.example.org").user == "ops")

        let existing = [
            RemoteHost(name: "web-01", address: "10.0.0.12", user: "deploy"),
            RemoteHost(name: "db-primary", address: "db1.internal.example.com", port: 2222, user: "postgres"),
            RemoteHost(name: "nas", address: "nas.local", user: "admin"),
        ]
        let candidates = SSHConfigImport.candidates(from: config, existingHosts: existing, localUser: "tester")
        let status = Dictionary(uniqueKeysWithValues: candidates.map { ($0.alias, $0.status) })
        #expect(status["staging"] == .ready)
        #expect(status["lab-2"] == .ready)
        #expect(status["web-prod-alias"] == .sameAsEarlier(alias: "web-prod"))
        #expect(status["db"] == .alreadyAdded(existingName: "db-primary"))
        #expect(status["web-01"] == .alreadyAdded(existingName: "web-01"))
        #expect(status["bastion"] == .ready)
        #expect(candidates.first { $0.alias == "bastion" }?.usesLocalUser == true)
        #expect(candidates.first { $0.alias == "nas" }?.host.name == "nas 2")
        #expect(candidates.first { $0.alias == "lab-1" }?.host.address == "lab-1.lab.example.com")
        if case .unsupported = status["app-behind-bastion"] {} else { Issue.record("ProxyJump host should be unsupported") }
        if case .unsupported = status["legacy"] {} else { Issue.record("ProxyCommand host should be unsupported") }
        if case .unsupported = status["sketchy"] {} else { Issue.record("option-like HostName should be unsupported") }
    }

    @Test("standalone and user locations")
    func locations() {
        let standalone = SSHConfigLocations.standalone(configFile: URL(filePath: "/tmp/fixture/ssh/config"))
        #expect(standalone == SSHConfigLocations(
            configFile: "/tmp/fixture/ssh/config", sshDirectory: "/tmp/fixture/ssh", homeDirectory: "/tmp/fixture"))
        let user = SSHConfigLocations.user(home: URL(filePath: "/Users/someone/", directoryHint: .isDirectory))
        #expect(user == SSHConfigLocations(
            configFile: "/Users/someone/.ssh/config", sshDirectory: "/Users/someone/.ssh", homeDirectory: "/Users/someone"))
    }

    @Test("missing, directory, FIFO and oversized files are handled without hanging")
    func fileGuards() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AeroOpsSSHConfigTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = LocalSSHConfigFiles()
        let base = directory.path(percentEncoded: false).trimmingTrailingSlashes()

        #expect(try files.contents(ofFile: base + "/missing") == nil)
        #expect(try files.contents(ofFile: base + "/missing/inside") == nil)
        #expect(throws: SSHConfigFileError.notARegularFile) { try files.contents(ofFile: base) }

        let fifo = base + "/fifo"
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(throws: SSHConfigFileError.notARegularFile) { try files.contents(ofFile: fifo) }

        let big = base + "/big"
        try Data(repeating: 0x23, count: LocalSSHConfigFiles.maxFileSize + 1).write(to: URL(filePath: big))
        #expect(throws: SSHConfigFileError.tooLarge) { try files.contents(ofFile: big) }

        try "Host b".write(toFile: base + "/b.conf", atomically: true, encoding: .utf8)
        try "Host a".write(toFile: base + "/a.conf", atomically: true, encoding: .utf8)
        #expect(try files.contents(ofFile: base + "/a.conf") == "Host a")
        #expect(files.paths(matching: base + "/*.conf") == [base + "/a.conf", base + "/b.conf"])
        #expect(files.paths(matching: base + "/*.none").isEmpty)
        #expect(files.paths(matching: base + "/missing.conf").isEmpty)

        #expect(throws: SSHConfigLoadError.notFound(path: base + "/missing")) {
            try SSHClientConfig.load(.standalone(configFile: URL(filePath: base + "/missing")))
        }
        #expect(throws: SSHConfigLoadError.unreadable(path: big, reason: "it is larger than 1 MB")) {
            try SSHClientConfig.load(.standalone(configFile: URL(filePath: big)))
        }
    }
}
