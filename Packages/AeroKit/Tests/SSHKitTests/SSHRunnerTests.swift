import AeroCore
import Darwin
import Foundation
import Synchronization
import Testing
@testable import SSHKit

/// Runner and process tests against fake `ssh` scripts (no server needed).
@Suite("SSHRunner")
struct SSHRunnerTests {
    let scratch: ScratchDirectory
    let runner: SSHRunner

    init() throws {
        scratch = try ScratchDirectory()
        let fake = try scratch.script("ssh", fakeSSHBody)
        runner = SSHRunner(context: SSHContext(paths: scratch.paths(), sshExecutable: fake))
    }

    @Test("passes -F, BatchMode=yes, -- and the alias, and sets SSH_AUTH_SOCK")
    func argv() async throws {
        let echo = try scratch.script("echo-ssh", #"printf '%s\n' "$@"; printf 'SSH_AUTH_SOCK=%s\n' "$SSH_AUTH_SOCK""#)
        let paths = scratch.paths()
        let runner = SSHRunner(context: SSHContext(paths: paths, sshExecutable: echo))
        let host = RemoteHost.test()
        let result = try await runner.run("-oProxyCommand=evil 'x y'", on: host)
        #expect(result.succeeded)
        #expect(result.stdoutString.split(separator: "\n").map(String.init) == [
            "-F", paths.sshConfig.filePath, "-o", "BatchMode=yes", "--", host.sshAlias, "-oProxyCommand=evil 'x y'",
            "SSH_AUTH_SOCK=" + paths.agentSocket.filePath,
        ])
        #expect(runner.commandLine("true", on: host).argv.first == echo.filePath)
    }

    @Test("collects stdout, stderr, exit status and duration")
    func collects() async throws {
        let result = try await runner.run("echo out; echo err >&2; exit 3", alias: "aero-test")
        #expect(result.stdoutString == "out\n")
        #expect(result.stderrString == "err\n")
        #expect(result.exitCode == 3)
        #expect(result.signal == nil)
        #expect(!result.timedOut)
        #expect(result.transportError == nil)
        #expect(!result.succeeded)
        #expect(result.duration > .zero && result.duration < .seconds(5))
        #expect(throws: SSHError.remoteCommandFailed(exitCode: 3, stderr: "err")) { try result.checked() }
    }

    @Test("quotes argument arrays with ShellQuote")
    func argumentsAreQuoted() async throws {
        let host = RemoteHost.test()
        let result = try await runner.run(arguments: ["printf", "%s|", "a b", "it's", "$(id)", ";rm -rf /"], on: host)
        #expect(result.stdoutString == "a b|it's|$(id)|;rm -rf /|")
    }

    @Test("feeds stdin and closes it; nil stdin reads as empty")
    func stdin() async throws {
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let echoed = try await runner.run("cat", alias: "aero-test", stdin: payload, outputLimit: 1 << 20)
        #expect(echoed.stdout == payload)
        #expect(!echoed.stdoutTruncated)

        let empty = try await runner.run("cat; echo done", alias: "aero-test")
        #expect(empty.stdoutString == "done\n")

        let ignored = try await runner.run("exit 0", alias: "aero-test", stdin: payload)
        #expect(ignored.exitCode == 0)
    }

    @Test("delivers live output while the command runs, capped like the collected output")
    func liveOutput() async throws {
        let chunks = Mutex<[(SSHOutputStream, Data)]>([])
        let host = RemoteHost.test()
        let runner = self.runner
        let task = Task {
            try await runner.run("echo first; echo warn >&2; sleep 30", on: host, timeout: .seconds(60)) { stream, data in
                chunks.withLock { $0.append((stream, data)) }
            }
        }
        #expect(await eventually(timeout: .seconds(5)) {
            chunks.withLock { list in
                list.contains { $0.0 == .stdout && $0.1 == Data("first\n".utf8) }
                    && list.contains { $0.0 == .stderr && $0.1 == Data("warn\n".utf8) }
            }
        })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let capped = Mutex(Data())
        let result = try await runner.run("head -c 5000 /dev/zero; echo done", on: host, outputLimit: 1000) { stream, data in
            if stream == .stdout { capped.withLock { $0.append(data) } }
        }
        #expect(result.exitCode == 0 && result.stdout.count == 1000 && result.stdoutTruncated)
        #expect(capped.withLock { $0 } == result.stdout)
    }

    @Test("caps each stream and flags truncation, while draining everything")
    func outputCaps() async throws {
        let result = try await runner.run(
            "head -c 200000 /dev/zero; head -c 5000 /dev/zero >&2; echo tail",
            alias: "aero-test", outputLimit: 1000
        )
        #expect(result.stdout.count == 1000)
        #expect(result.stdoutTruncated)
        #expect(result.stderr.count == 1000)
        #expect(result.stderrTruncated)
        #expect(result.exitCode == 0)

        let small = try await runner.run("printf 12345", alias: "aero-test", outputLimit: 5)
        #expect(small.stdoutString == "12345")
        #expect(!small.stdoutTruncated)
    }

    @Test("timeout kills the whole process group, including children that ignore SIGTERM")
    func timeoutKillsGroup() async throws {
        let pidFile = scratch.file("child.pid").filePath
        let start = ContinuousClock.now
        let result = try await runner.run(
            "trap '' TERM; sleep 30 & echo $! > \(ShellQuote.quote(pidFile)); wait",
            alias: "aero-test", timeout: .milliseconds(1500)
        )
        #expect(result.timedOut)
        #expect(result.signal == SIGKILL)
        #expect(result.transportError == .timeout)
        #expect(throws: SSHError.timeout) { try result.checked() }
        #expect(ContinuousClock.now - start < .seconds(5))
        let grandchild = try #require(scratch.read("child.pid").flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        #expect(await waitUntilGone(grandchild))
    }

    @Test("the child is reaped: no zombie remains")
    func noZombie() async throws {
        let spec = ChildSpec(executable: "/bin/sh", arguments: ["-c", "exit 7"], environment: [:])
        let outcome = try await ChildProcess.run(spec)
        #expect(outcome.termination == .exited(7))
        #expect(kill(outcome.pid, 0) == -1 && errno == ESRCH)

        let timed = try await ChildProcess.run(ChildSpec(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [:], timeout: .milliseconds(100)
        ))
        #expect(timed.timedOut)
        #expect(timed.termination == .signaled(SIGTERM))
        #expect(kill(timed.pid, 0) == -1 && errno == ESRCH)
    }

    @Test("an exit reported before the child is waitable still reaps it")
    func exitReportedEarly() async throws {
        let outcome = Mutex<ChildOutcome?>(nil)
        let spec = ChildSpec(executable: "/bin/sh", arguments: ["-c", "sleep 1; exit 5"], environment: [:])
        let child = try ChildProcess.launch(spec, watchesExit: false) { result in outcome.withLock { $0 = result } }
        child.reportExitForTesting()
        let finished = await eventually(timeout: .seconds(15)) { outcome.withLock { $0 != nil } }
        if !finished {
            kill(-child.pid, SIGKILL)
            var status: Int32 = 0
            waitpid(child.pid, &status, 0)
        }
        #expect(finished, "the child was never reaped")
        let result = try #require(outcome.withLock { $0 })
        #expect(result.termination == .exited(5))
        #expect(kill(result.pid, 0) == -1 && errno == ESRCH)
    }

    @Test("does not wait for background descendants that keep the pipes open")
    func drainGrace() async throws {
        let start = ContinuousClock.now
        let result = try await runner.run("sleep 5 & echo started", alias: "aero-test")
        #expect(result.stdoutString == "started\n")
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("cancelling the task kills ssh and throws CancellationError")
    func cancelRun() async throws {
        let pidFile = scratch.file("run.pid").filePath
        let runner = self.runner
        let task = Task {
            try await runner.run("echo $$ > \(ShellQuote.quote(pidFile)); exec sleep 30", alias: "aero-test")
        }
        #expect(await eventually { scratch.read("run.pid")?.hasSuffix("\n") == true })
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        let pid = try #require(scratch.read("run.pid").flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        #expect(await waitUntilGone(pid))
    }

    @Test("classifies ssh's own failures from exit 255 + stderr")
    func transportErrors() async throws {
        let refused = try await runner.run(
            #"printf 'ssh: connect to host localhost port 1: Connection refused\r\n' >&2; exit 255"#, alias: "aero-test"
        )
        #expect(refused.transportError == .connectionRefused)
        #expect(throws: SSHError.connectionRefused) { try refused.checked() }

        let silent = try await runner.run("exit 255", alias: "aero-test")
        #expect(silent.transportError == .other(""))
    }

    @Test("refuses empty commands, NUL bytes and bad aliases; reports launch failures")
    func invalidRequests() async throws {
        await #expect(throws: SSHError.self) { try await runner.run("", alias: "aero-test") }
        await #expect(throws: SSHError.self) { try await runner.run("echo \0", alias: "aero-test") }
        await #expect(throws: SSHError.self) { try await runner.run("true", alias: "-oProxyCommand=x") }
        await #expect(throws: SSHError.self) { try await runner.run("true", alias: "Aero-Upper") }

        let missing = SSHRunner(context: SSHContext(paths: scratch.paths(), sshExecutable: scratch.file("nope")))
        do {
            _ = try await missing.run("true", alias: "aero-test")
            Issue.record("expected a launch failure")
        } catch let error as SSHError {
            guard case .launchFailed = error else { Issue.record("unexpected \(error)"); return }
        }
    }

    @Test("streams stdout lines and finishes on exit 0")
    func streamLines() async throws {
        let stream = try runner.stream(#"printf 'a\nb\r\n\nlast'"#, alias: "aero-test")
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        #expect(lines == ["a", "b", "", "last"])
    }

    @Test("a failing remote command ends the stream with an error")
    func streamFailure() async throws {
        let stream = try runner.stream("echo one; echo boom >&2; exit 4", alias: "aero-test")
        var lines: [String] = []
        do {
            for try await line in stream { lines.append(line) }
            Issue.record("expected an error")
        } catch {
            #expect(error as? SSHError == .remoteCommandFailed(exitCode: 4, stderr: "boom"))
        }
        #expect(lines == ["one"])

        let auth = try runner.stream(#"printf 'dev@localhost: Permission denied (publickey).\r\n' >&2; exit 255"#, alias: "aero-test")
        await #expect(throws: SSHError.authFailed) { for try await _ in auth {} }
    }

    @Test("breaking out of the loop and dropping the stream kills ssh")
    func streamDropKills() async throws {
        let pidFile = scratch.file("stream.pid").filePath
        do {
            let stream = try runner.stream(
                "echo $$ > \(ShellQuote.quote(pidFile)); i=0; while :; do echo line$i; i=$((i+1)); sleep 0.05; done",
                alias: "aero-test"
            )
            var received: [String] = []
            for try await line in stream {
                received.append(line)
                if received.count == 3 { break }
            }
            #expect(received == ["line0", "line1", "line2"])
        }
        let pid = try #require(scratch.read("stream.pid").flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        #expect(await waitUntilGone(pid))
    }

    @Test("cancelling the consuming task kills ssh")
    func streamCancelKills() async throws {
        let pidFile = scratch.file("cancel.pid").filePath
        let stream = try runner.stream(
            "echo $$ > \(ShellQuote.quote(pidFile)); while :; do echo tick; sleep 0.05; done",
            alias: "aero-test"
        )
        let firstLine = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var count = 0
            for try await _ in stream {
                count += 1
                if count == 1 { firstLine.continuation.yield() }
            }
            return count
        }
        for await _ in firstLine.stream { break }
        consumer.cancel()
        _ = try? await consumer.value
        let pid = try #require(scratch.read("cancel.pid").flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        #expect(await waitUntilGone(pid))
    }

    @Test("stream timeout ends with SSHError.timeout")
    func streamTimeout() async throws {
        let start = ContinuousClock.now
        let stream = try runner.stream("echo first; sleep 30", alias: "aero-test", timeout: .seconds(3))
        var lines: [String] = []
        do {
            for try await line in stream { lines.append(line) }
            Issue.record("expected a timeout")
        } catch {
            #expect(error as? SSHError == .timeout)
        }
        let elapsed = ContinuousClock.now - start
        #expect(lines == ["first"])
        #expect(elapsed >= .seconds(3), "ended after \(elapsed), before the deadline")
        #expect(elapsed < .seconds(10), "took \(elapsed): the timeout did not cut sleep 30 short")
    }

    @Test("long lines are split at maxLineLength")
    func lineSplitter() {
        var splitter = LineSplitter(maxLength: 4)
        var lines: [String] = []
        let bytes = Array("abcdefg\nhi\r\n".utf8)
        bytes.withUnsafeBytes { splitter.append($0) { lines.append($0) } }
        splitter.finish { lines.append($0) }
        #expect(lines == ["abcd", "efg", "hi"])
    }
}
