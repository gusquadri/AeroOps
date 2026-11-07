import Darwin
import Foundation
import Testing
@testable import TerminalKit

@Suite("Process tree and reaper")
struct ProcessTreeTests {
    @Test("finds our own process with its parent")
    func ownProcess() throws {
        let me = try #require(ProcessTable.entry(for: getpid()))
        #expect(me.ppid == getppid())
        #expect(me.uid == getuid())
        #expect(ProcessTable.snapshot().contains { $0.pid == getpid() })
    }

    @Test("reaps a tree that ignores SIGHUP and SIGTERM")
    func reapStubbornTree() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM HUP; /bin/sleep 30 & wait"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        let root = process.processIdentifier
        var tree: [ProcessEntry] = []
        for _ in 0..<100 {
            tree = ProcessTable.tree(rootedAt: root, in: ProcessTable.snapshot())
            if tree.count >= 2 { break }
            usleep(20_000)
        }
        #expect(tree.first?.pid == root)
        #expect(tree.count == 2)

        let report = ProcessReaper.reap(tree, grace: .milliseconds(100))
        #expect(report.survivors.isEmpty)
        #expect(!report.killed.isEmpty)
        process.waitUntilExit()
        #expect(tree.allSatisfy { !ProcessTable.isAlive($0) })
    }

    @Test("does nothing for processes that already exited")
    func alreadyGone() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        let entry = ProcessTable.entry(for: process.processIdentifier)
        process.waitUntilExit()
        let report = ProcessReaper.reap(entry.map { [$0] } ?? [], grace: .milliseconds(50))
        #expect(report == ReapReport())
    }
}
