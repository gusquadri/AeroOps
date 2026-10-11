import Foundation
import Testing
import AeroCore

@Suite("ShellQuote")
struct ShellQuoteTests {
    /// Inputs that would break or inject into an unquoted or naively quoted command.
    static let hostile: [String] = [
        "",
        " ",
        "plain",
        "it's",
        "'",
        "''",
        "'\\''",
        "a'b'c",
        "'; rm -rf / #",
        "$(reboot)",
        "`id`",
        "${HOME}",
        "$HOME",
        "\"double\" quotes",
        "back\\slash\\",
        "semi;colon && and || or | pipe",
        "> /etc/passwd < in",
        "new\nline",
        "tab\tand\rcarriage",
        "glob * ? [a-z] ~",
        "-rf",
        "--help",
        "!bang !!",
        "#comment",
        "unicode ünïcødé 🚀 \u{202E}rtl",
        "'\"'\"'",
        String(repeating: "'", count: 50),
    ]

    @Test("quote wraps in single quotes and escapes embedded quotes")
    func quoteFormat() {
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("abc") == "'abc'")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.quote("'") == #"''\'''"#)
        #expect(ShellQuote.quote("$(x)") == "'$(x)'")
    }

    @Test("join quotes each value")
    func join() {
        #expect(ShellQuote.join(["a b", "c'd"]) == #"'a b' 'c'\''d'"#)
        #expect(ShellQuote.join([]) == "")
    }

    /// The real proof: /bin/sh must read every quoted value back as exactly the original string.
    @Test("hostile input round-trips through /bin/sh unchanged", arguments: hostile)
    func roundTripThroughShell(_ value: String) throws {
        let output = try runSh("printf '%s' " + ShellQuote.quote(value))
        #expect(output == value)
    }

    @Test("quoted value stays one argument")
    func staysOneArgument() throws {
        let output = try runSh("set -- " + ShellQuote.join(Self.hostile) + "; printf '%s' \"$#\"")
        #expect(output == String(Self.hostile.count))
    }

    @Test("safe names", arguments: ["nginx", "api-1", "my_app.v2", "a", "0", "kube-system", "x.y-z_9", "_svc"])
    func safeNames(_ name: String) {
        #expect(ShellQuote.isSafeName(name))
    }

    @Test("unsafe names", arguments: [
        "", " ", "a b", "a;b", "a'b", "a\"b", "$(id)", "`id`", "a|b", "a&b", "a/b", "../etc",
        "a\nb", "a\tb", "ünï", "name🚀", "-rf", "--all", "-", "a*", "a?", "~root", "a=b", "a:b",
        "a\u{0}b",
    ])
    func unsafeNames(_ name: String) {
        #expect(!ShellQuote.isSafeName(name))
    }

    /// Runs `script` with `/bin/sh -c` locally and returns stdout.
    private func runSh(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }
}
