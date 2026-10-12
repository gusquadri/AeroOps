import Foundation
import Testing
@testable import KeyAgent

/// The parent walk behind ``PeerIdentity/startedByApp``.
@Suite("Process ancestry")
struct ProcessAncestryTests {
    /// A process tree: child → parent.
    private func tree(_ parents: [pid_t: pid_t]) -> (pid_t) -> pid_t? { { parents[$0] } }

    @Test func readsTheParentOfAProcessOwnedByAnotherUser() throws {
        // launchd is root-owned. `PROC_PIDTBSDINFO` refuses it with EPERM, which is how the walk
        // used to stop at a terminal tab's root-owned `/usr/bin/login`.
        #expect(ProcessAncestry.parentPID(of: 1) == 0)
        #expect(ProcessAncestry.parentPID(of: getpid()) == getppid())
    }

    @Test func readsRootOwnedParentsLikePs() async throws {
        let ps = try await runProcess("/bin/ps", ["-axo", "pid=,ppid=,uid="])
        #expect(ps.status == 0)
        let rootOwned = ps.stdout.split(separator: "\n").compactMap { line -> (pid: pid_t, ppid: pid_t)? in
            let fields = line.split(separator: " ").compactMap { Int32($0) }
            return fields.count == 3 && fields[2] == 0 ? (fields[0], fields[1]) : nil
        }
        try #require(rootOwned.count > 1)
        // Processes may exit between `ps` and the lookup; those return nil and are skipped.
        let read = rootOwned.compactMap { entry in ProcessAncestry.parentPID(of: entry.pid).map { (entry, $0) } }
        #expect(read.count > rootOwned.count / 2)
        for (entry, parent) in read { #expect(parent == entry.ppid, "pid \(entry.pid)") }
    }

    @Test func walksThroughALoginWrapperToTheApp() {
        // libghostty: app (500) → login (root, 501) → sh (502) → ssh (503).
        let parents = tree([503: 502, 502: 501, 501: 500, 500: 400, 400: 1])
        let chain = ProcessAncestry.ancestors(of: 503, parent: parents)
        #expect(chain == [502, 501, 500, 400])
        #expect(chain.contains(500))
    }

    @Test func failsClosedWhenAParentCannotBeRead() {
        // Before the fix the root-owned login read as nil; the app is then not an ancestor.
        let parents: (pid_t) -> pid_t? = { pid in [503: 502, 502: 501][pid] }
        #expect(ProcessAncestry.ancestors(of: 503, parent: parents) == [502, 501])
    }

    @Test func stopsBeforeLaunchdSoReparentedProcessesAreNotTheApps() {
        // A daemonized ControlMaster is reparented to launchd: the app is no longer an ancestor.
        let parents = tree([600: 1])
        #expect(ProcessAncestry.ancestors(of: 600, parent: parents).isEmpty)
    }

    @Test func boundsCyclesAndDepth() {
        #expect(ProcessAncestry.ancestors(of: 10, parent: tree([10: 11, 11: 12, 12: 11])) == [11, 12])
        #expect(ProcessAncestry.ancestors(of: 10, parent: tree([10: 10])).isEmpty)
        let line = Dictionary(uniqueKeysWithValues: (2..<200).map { (pid_t($0 + 1), pid_t($0)) })
        #expect(ProcessAncestry.ancestors(of: 199, maxDepth: 5, parent: { line[$0] }) == [198, 197, 196, 195, 194])
    }
}

/// Runs a real agent client under `/usr/bin/login -f`, as libghostty does for terminal tabs.
/// Opt-in because `login` adds a session record (visible in `last`).
@Suite("Process ancestry through login (AEROOPS_INTEGRATION=1)",
       .enabled(if: ProcessInfo.processInfo.environment["AEROOPS_INTEGRATION"] == "1"))
struct LoginAncestryIntegrationTests {
    @Test func aClientStartedThroughLoginIsStartedByTheApp() async throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let server = SSHAgentServer(
            socketURL: dir.appending("agent/agent.sock"), keyStore: try makeKeyStore(dir),
            authorizer: RecordingAuthorizer(), appProcessID: getpid())
        let recorder = EventRecorder(server.events)
        defer { recorder.stop() }
        try await server.start()

        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = server.socketURL.path
        // `login -p` keeps the environment; `exec` makes ssh-add the shell's process, a grandchild
        // of the root-owned login.
        let result = try await runProcess(
            "/usr/bin/login", ["-fpql", NSUserName(), "/bin/sh", "-c", "exec /usr/bin/ssh-add -l"], environment: environment)
        #expect(result.stdout.contains("no identities"), "status \(result.status): \(result.stderr)")

        #expect(await recorder.wait { $0.contains(.disconnected) })
        guard case .connected(let peer) = recorder.all.first else { Issue.record("no connected event"); return }
        #expect(peer.executablePath == "/usr/bin/ssh-add")
        #expect(peer.parentPID != getpid()) // login sits in between
        #expect(peer.ancestorPIDs.contains(getpid()))
        #expect(peer.startedByApp)
        await server.stop()
    }
}
