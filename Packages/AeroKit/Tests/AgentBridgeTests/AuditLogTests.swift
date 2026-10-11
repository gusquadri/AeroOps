import AeroCore
import BridgeProtocol
import Darwin
import Foundation
import Testing
@testable import AgentBridge

@Suite("Audit log")
struct AuditLogTests {
    static func entry(_ n: Int = 0, command: String = "uptime", decision: AuditDecision = .approvedOnce,
                      outcome: AuditOutcome = .succeeded) -> AuditEntry {
        AuditEntry(time: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), client: "claude-code 2.1.296",
                   toolUseId: "toolu_\(n)", tool: "run_command", host: "staging", hostId: TestHosts.staging.id,
                   arguments: ["host": "staging", "command": .string(command), "reason": "check"],
                   decision: decision, outcome: outcome, exitCode: 0, durationMs: 42, outputBytes: 12)
    }

    @Test func writesOneJSONLinePerEntryWithPrivatePermissions() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let url = dir.appending("support/AeroOps/audit.jsonl")
        let log = AuditLog(fileURL: url)
        let entries = [Self.entry(1), Self.entry(2, decision: .denied, outcome: .notRun)]
        for entry in entries { await log.record(entry) }
        #expect(await log.lastError == nil)

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2 && text.hasSuffix("\n"))
        let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(Set(first.keys) == ["id", "time", "client", "toolUseId", "tool", "host", "hostId", "arguments",
                                    "decision", "outcome", "exitCode", "durationMs", "outputBytes"])
        #expect(first["time"] as? String == "2027-01-15T08:00:01Z")
        #expect(first["decision"] as? String == "approvedOnce")
        #expect(lines[1].contains(#""decision":"denied""#) && lines[1].contains(#""outcome":"notRun""#))
        #expect(fileMode(url.path(percentEncoded: false)).map { $0 & 0o777 } == 0o600)
        #expect(fileMode(url.deletingLastPathComponent().path(percentEncoded: false)).map { $0 & 0o777 } == 0o700)
        #expect(AuditLog.read(from: url) == entries)
        #expect(await log.recent() == entries)
    }

    @Test func fixesLoosePermissionsAndRefusesSymlinks() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let url = dir.appending("audit.jsonl")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data(), attributes: [.posixPermissions: 0o644])
        let log = AuditLog(fileURL: url)
        await log.record(Self.entry())
        #expect(fileMode(url.path(percentEncoded: false)).map { $0 & 0o777 } == 0o600)

        let target = dir.appending("elsewhere.txt")
        FileManager.default.createFile(atPath: target.path(percentEncoded: false), contents: Data("keep\n".utf8))
        let link = dir.appending("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = AuditLog(fileURL: link)
        await linked.record(Self.entry())
        #expect(await linked.lastError != nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep\n")
        #expect(await linked.recent().count == 1, "the in-memory feed still shows the call")
    }

    @Test func rotatesAtMaxBytes() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let url = dir.appending("audit.jsonl")
        let log = AuditLog(fileURL: url, maxBytes: 1024, generations: 2)
        for n in 0..<20 { await log.record(Self.entry(n)) }
        let current = AuditLog.read(from: url)
        let first = AuditLog.read(from: log.rotatedURL(1))
        let second = AuditLog.read(from: log.rotatedURL(2))
        #expect(log.rotatedURL(1).lastPathComponent == "audit.1.jsonl")
        #expect(!FileManager.default.fileExists(atPath: log.rotatedURL(3).path(percentEncoded: false)))
        #expect(!current.isEmpty && !first.isEmpty && !second.isEmpty)
        for file in [url, log.rotatedURL(1), log.rotatedURL(2)] {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int) ?? 0
            #expect(size <= 1024, "\(file.lastPathComponent) is \(size) bytes")
        }
        // Newest entries survive, in order.
        let kept = (second + first + current).compactMap(\.toolUseId)
        #expect(kept.last == "toolu_19")
        #expect(kept == kept.sorted { Int($0.dropFirst(6))! < Int($1.dropFirst(6))! })
    }

    @Test func readSkipsMalformedLinesAndKeepsTheNewest() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let url = dir.appending("audit.jsonl")
        let log = AuditLog(fileURL: url)
        await log.record(Self.entry(1))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n\n".utf8))
        try handle.close()
        await log.record(Self.entry(2))
        await log.record(Self.entry(3))
        #expect(AuditLog.read(from: url).compactMap(\.toolUseId) == ["toolu_1", "toolu_2", "toolu_3"])
        #expect(AuditLog.read(from: url, limit: 2).compactMap(\.toolUseId) == ["toolu_2", "toolu_3"])
        #expect(AuditLog.read(from: dir.appending("missing.jsonl")).isEmpty)

        let reopened = AuditLog(fileURL: url, recentCapacity: 2)
        await reopened.loadRecent()
        #expect(await reopened.recent().compactMap(\.toolUseId) == ["toolu_2", "toolu_3"])
        await reopened.record(Self.entry(4))
        #expect(await reopened.recent().compactMap(\.toolUseId) == ["toolu_3", "toolu_4"])
    }

    @Test func longArgumentsAreClipped() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let log = AuditLog(fileURL: dir.appending("audit.jsonl"))
        let long = String(repeating: "x", count: 20_000)
        await log.record(Self.entry(command: long))
        let stored = try #require(await log.recent().first?.arguments["command"]?.stringValue)
        #expect(stored.hasSuffix("…"))
        #expect(stored.utf8.count <= AuditLog.maxArgumentLength + 3)
        let accents = String(repeating: "é", count: 9_000)
        #expect(AuditLog.clipped(["c": .string(accents)])["c"]?.stringValue?.unicodeScalars.contains("\u{FFFD}") == false)
    }

    @Test func updatesStreamNewEntries() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let log = AuditLog(fileURL: dir.appending("audit.jsonl"))
        let updates = log.updates()
        await log.record(Self.entry(7))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?.toolUseId == "toolu_7")
    }
}
