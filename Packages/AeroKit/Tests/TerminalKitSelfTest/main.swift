// TerminalKit self-test: drives real libghostty surfaces against the dev SSH container.
// Not shipped; run through run-selftest.sh, which prepares a throwaway key and ssh config.
//
//   TerminalKitSelfTest --ssh-config PATH --host ALIAS --closed-host ALIAS --agent-sock PATH
//
// AEROOPS_TK_DEBUG=1 turns on libghostty's lifecycle/action log and view-tree dumps;
// AEROOPS_TK_STOP=1 stops after the first tab if it never reaches the prompt.

import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import SwiftUI
@_spi(AeroSelfTest) import TerminalKit

struct Options {
    var sshConfig = ""
    var host = ""
    var closedHost = ""
    var agentSocket = ""

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            let value = iterator.next() ?? ""
            switch flag {
            case "--ssh-config": sshConfig = value
            case "--host": host = value
            case "--closed-host": closedHost = value
            case "--agent-sock": agentSocket = value
            default: break
            }
        }
    }

    func spec(host: String, title: String) -> TerminalLaunchSpec {
        TerminalLaunchSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-F", sshConfig, host],
            environment: ["SSH_AUTH_SOCK": agentSocket, "AEROOPS_SELFTEST": "1"],
            title: title
        )
    }
}

struct GridView: View {
    let manager: TerminalSessionManager

    var body: some View {
        let sessions = manager.sessions
        let rows = stride(from: 0, to: sessions.count, by: 2).map { Array(sessions[$0..<min($0 + 2, sessions.count)]) }
        VStack(spacing: 2) {
            ForEach(rows, id: \.first!.id) { row in
                HStack(spacing: 2) {
                    ForEach(row) { session in
                        TerminalSurfaceView(session: session, focusOnAppear: false)
                    }
                }
            }
        }
    }
}

@MainActor
final class SelfTest {
    let options: Options
    let manager = TerminalSessionManager()
    let window: NSWindow
    var failures: [String] = []

    init(options: Options) {
        self.options = options
        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1500, height: 960),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TerminalKit self-test"
        // Fixed geometry: by default NSHostingView sizes the window to its content, and an
        // empty grid would shrink the window to nothing before the first tab opens.
        let host = NSHostingView(rootView: GridView(manager: manager))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
    }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message)
        if !condition { failures.append(message) }
    }

    func wait(_ seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    func lines(_ session: TerminalSession) -> [String] {
        (session.screenText() ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func hasPrompt(_ session: TerminalSession) -> Bool {
        lines(session).contains { $0.hasSuffix("$") }
    }

    func dumpViews() {
        func walk(_ view: NSView, _ depth: Int) {
            print(String(repeating: "  ", count: depth), type(of: view), view.frame, "needsLayout=\(view.needsLayout)")
            if depth < 12 { view.subviews.forEach { walk($0, depth + 1) } }
        }
        print("WINDOW content", window.contentLayoutRect, "visible=\(window.isVisible) key=\(window.isKeyWindow) occlusion=\(window.occlusionState.contains(.visible))")
        if let content = window.contentView { walk(content, 1) }
    }

    func dump(_ session: TerminalSession, _ label: String) {
        if ProcessInfo.processInfo.environment["AEROOPS_TK_DEBUG"] == "1" { dumpViews() }
        print("SCREEN \(label) state=\(session.state):")
        for line in lines(session) where !line.isEmpty {
            print("   |", line.debugDescription)
        }
    }

    /// Types `command; echo <marker>` and returns the screen lines once the marker printed.
    func run(_ session: TerminalSession, _ command: String, marker: String) async -> [String]? {
        // `''` splits the marker in the echoed command line, so only the output matches.
        let split = marker.prefix(2) + "''" + marker.dropFirst(2)
        session.type("\(command); echo \(split)\n")
        var result: [String]?
        _ = await wait {
            let current = lines(session)
            if current.contains(marker) { result = current }
            return result != nil
        }
        return result
    }

    /// `rows cols` printed by `stty size` right before `marker`.
    func sttySize(in lines: [String], marker: String) -> (rows: Int, columns: Int)? {
        guard let index = lines.lastIndex(of: marker), index > 0 else { return nil }
        let parts = lines[index - 1].split(separator: " ").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    func memory() -> (footprintMB: Double, residentMB: Double) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return (0, 0) }
        return (Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_resident_size) / 1_048_576)
    }

    func format(_ m: (footprintMB: Double, residentMB: Double)) -> String {
        String(format: "footprint %.1f MB, RSS %.1f MB", m.footprintMB, m.residentMB)
    }

    /// `ps` lines (pid user args) of every process whose argv mentions the test ssh config.
    func leftovers() -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,user=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.contains(options.sshConfig) && !$0.contains(" ps -axww") }
            .filter { $0.split(separator: " ").first.flatMap { Int32($0) } != getpid() }
    }

    func run() async -> Int32 {
        try? await Task.sleep(for: .seconds(1))
        let baseline = memory()
        print("MEM baseline:", format(baseline))

        // Invalid spec fails fast and never starts anything.
        let invalid = manager.open(TerminalLaunchSpec(executable: "ssh", title: "bad"))
        if case .failed = invalid.state { check(true, "relative executable -> failed state") } else {
            check(false, "relative executable -> failed state (got \(invalid.state))")
        }
        manager.close(invalid.id)

        // 1 tab, then 5.
        let first = manager.open(options.spec(host: options.host, title: "tab 1"))
        let firstPrompt = await wait { hasPrompt(first) }
        check(firstPrompt, "tab 1 reaches the remote prompt")
        if !firstPrompt {
            dump(first, "tab 1")
            if ProcessInfo.processInfo.environment["AEROOPS_TK_STOP"] == "1" {
                manager.closeAll()
                exit(4)
            }
        }
        try? await Task.sleep(for: .seconds(1))
        let one = memory()
        print("MEM 1 tab:", format(one))

        var sessions = [first]
        for index in 2...5 {
            sessions.append(manager.open(options.spec(host: options.host, title: "tab \(index)")))
        }
        for (index, session) in sessions.enumerated() {
            let prompt = await wait { hasPrompt(session) }
            check(prompt, "tab \(index + 1) reaches the remote prompt")
            if !prompt { dump(session, "tab \(index + 1)") }
        }
        try? await Task.sleep(for: .seconds(1))
        let five = memory()
        print("MEM 5 tabs:", format(five))
        print(String(
            format: "MEM per tab: first %.1f MB footprint / %.1f MB RSS; tabs 2-5 avg %.1f MB footprint / %.1f MB RSS",
            one.footprintMB - baseline.footprintMB, one.residentMB - baseline.residentMB,
            (five.footprintMB - one.footprintMB) / 4, (five.residentMB - one.residentMB) / 4
        ))

        for (index, session) in sessions.enumerated() {
            check(session.state == .running, "tab \(index + 1) state running (\(session.state))")
            check(!lines(session).contains { $0.contains("Last login") }, "tab \(index + 1) shows no 'Last login'")
        }

        // stty size + OK in each, compared with the surface's grid.
        var before: [(rows: Int, columns: Int)] = []
        for (index, session) in sessions.enumerated() {
            let marker = "OK_\(index + 1)"
            let output = await run(session, "stty size", marker: marker)
            let size = output.flatMap { sttySize(in: $0, marker: marker) }
            let grid = session.gridSize
            check(size != nil, "tab \(index + 1): stty size; echo OK -> \(size.map { "\($0.rows) \($0.columns)" } ?? "nothing")")
            if let size, let grid {
                check(size.rows == grid.rows && size.columns == grid.columns, "tab \(index + 1): pty size matches grid \(grid.rows)x\(grid.columns)")
            }
            before.append(size ?? (0, 0))
        }

        // SSH_AUTH_SOCK reached ssh: the harness runs without one and the private key exists
        // only in the temp agent, so the logins above prove it. Environment additions and the
        // working directory, plus a short-lived local program's exit code, checked locally
        // (macOS `ps -E` no longer shows other processes' environments).
        let local = manager.open(TerminalLaunchSpec(
            executable: "/bin/sh",
            arguments: ["-c", #"printf 'ENV=%s PWD=%s\n' "$AEROOPS_SELFTEST" "$(pwd)"; exit 3"#],
            environment: ["AEROOPS_SELFTEST": "env-ok"],
            workingDirectory: "/usr",
            title: "local"
        ))
        check(await wait { local.state.isFinished }, "local program finishes")
        check(local.state == .exited(code: 3), "local 'exit 3' -> exited(code: 3) (\(local.state))")
        check(lines(local).contains("ENV=env-ok PWD=/usr"), "environment and working directory reach the program")
        // libghostty prints "Press any key to close the terminal" on every exit: the ended tab
        // stays until then, and the key press reaches the manager's close handler.
        try? await Task.sleep(for: .milliseconds(500))
        check(manager.session(id: local.id) != nil, "an ended tab stays open until asked")
        var closeRequests: [TerminalSession.ID] = []
        manager.closeRequestHandler = { [manager] session in
            closeRequests.append(session.id)
            manager.close(session.id)
        }
        local.type("x")
        check(await wait(5) { manager.session(id: local.id) == nil }, "a key press after the program ended closes the tab")
        check(closeRequests == [local.id], "the key press went through closeRequestHandler (\(closeRequests.count) request(s))")
        manager.closeRequestHandler = nil
        manager.close(local.id)

        // Resize: shrink the window, sizes must follow.
        window.setContentSize(NSSize(width: 1000, height: 640))
        try? await Task.sleep(for: .seconds(1))
        for (index, session) in sessions.enumerated() {
            let marker = "RS_\(index + 1)"
            let output = await run(session, "stty size", marker: marker)
            let size = output.flatMap { sttySize(in: $0, marker: marker) }
            let grid = session.gridSize
            let changed = size.map { $0.rows != before[index].rows || $0.columns != before[index].columns } ?? false
            check(changed, "tab \(index + 1): resize changes pty size \(before[index]) -> \(size.map { "\($0)" } ?? "nil")")
            if let size, let grid {
                check(size.rows == grid.rows && size.columns == grid.columns, "tab \(index + 1): resized pty size matches grid")
            }
        }

        // Full-screen programs: vi in tab 1, top in tab 2.
        sessions[0].type("vi /tmp/aeroops-selftest-\(getpid()).txt\n")
        check(await wait { lines(sessions[0]).filter { $0 == "~" }.count >= 3 }, "vi draws its screen")
        sessions[0].pressEscape()
        // A lone ESC followed at once by more keys reads as an escape sequence to vi.
        try? await Task.sleep(for: .milliseconds(300))
        sessions[0].type(":q!\n")
        let viDone = await run(sessions[0], "true", marker: "VI_DONE") != nil
        check(viDone, "vi quits back to the shell")
        if !viDone { dump(sessions[0], "tab 1 (vi)") }

        // procps top on the Alpine container.
        sessions[1].type("top\n")
        let topDrawn = await wait { lines(sessions[1]).contains { $0.hasPrefix("top - ") || $0.hasPrefix("Tasks:") } }
        check(topDrawn, "top draws its screen")
        if !topDrawn { dump(sessions[1], "tab 2 (top)") }
        sessions[1].type("q")
        // top restores the tty with TCSAFLUSH, discarding input typed before it is gone.
        try? await Task.sleep(for: .milliseconds(500))
        let topDone = await run(sessions[1], "true", marker: "TOP_DONE") != nil
        check(topDone, "top quits back to the shell")
        if !topDone { dump(sessions[1], "tab 2 (after top)") }

        // Title from OSC 2.
        sessions[3].type(#"printf '\033]2;AERO''_TITLE\007'"# + "\n")
        check(await wait(5) { sessions[3].title == "AERO_TITLE" }, "OSC 2 updates the title (\(sessions[3].title))")

        // Font size: increase, then reset.
        let initialFont = sessions[2].fontSize
        sessions[2].increaseFontSize()
        sessions[2].increaseFontSize()
        check(await wait(5) { sessions[2].fontSize > initialFont }, "font size increases (\(initialFont) -> \(sessions[2].fontSize))")
        sessions[2].decreaseFontSize()
        sessions[2].resetFontSize()
        check(await wait(5) { sessions[2].fontSize == initialFont }, "font size resets (\(sessions[2].fontSize))")

        // Real exit code from the remote shell.
        sessions[4].type("exit 7\n")
        check(await wait { sessions[4].state == .exited(code: 7) }, "remote 'exit 7' -> exited(code: 7) (\(sessions[4].state))")

        // Closing one tab ends its tree.
        let closedRoot = sessions[0].processRootPID
        let beforeClose = leftovers().count
        manager.close(sessions[0].id)
        _ = await wait(3) { leftovers().count <= beforeClose - 3 }
        let rootGone = closedRoot.map { kill($0, 0) != 0 } ?? false
        check(rootGone, "close() ends the tab's wrapper (pid \(closedRoot.map(String.init) ?? "?"))")
        check(sessions[0].state == .exited(code: nil), "closed tab state exited(code: nil) (\(sessions[0].state))")

        // Connection failure: closed port.
        let failing = manager.open(options.spec(host: options.closedHost, title: "closed port"))
        check(await wait { failing.state.isFinished }, "closed port session finishes")
        check(failing.state == .exited(code: 255), "closed port -> exited(code: 255) (\(failing.state))")
        let failText = lines(failing).joined(separator: "\n")
        check(failText.contains("Connection refused") || failText.contains("connect to host"), "ssh error stays on screen")
        check(!failText.contains("Last login"), "no 'Last login' on the failed tab")

        // A closed session (and its surface, controller and delegate bridge) is freed.
        weak var probe: TerminalSession?
        do {
            let session = manager.open(options.spec(host: options.host, title: "probe"))
            probe = session
            _ = await wait { session.state == .running }
            manager.close(session.id)
        }
        check(await wait(5) { probe == nil }, "a closed session is deallocated")

        // Close everything (the quit path) and look for leaks.
        let running = leftovers()
        print("PROCS before closeAll: \(running.count)")
        running.forEach { print("  ", $0.prefix(140)) }
        manager.closeAll()
        check(manager.sessions.isEmpty, "closeAll empties the manager")
        _ = await wait(2) { leftovers().isEmpty }
        let leaked = leftovers()
        leaked.forEach { print("  LEAK", $0.prefix(160)) }
        check(leaked.isEmpty, "no ssh/sh/login processes left after closeAll")

        try? await Task.sleep(for: .milliseconds(500))
        print("MEM after closeAll:", format(memory()))
        print(failures.isEmpty ? "RESULT PASS" : "RESULT FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
        return failures.isEmpty ? 0 : 1
    }
}

let options = Options(arguments: CommandLine.arguments)
guard !options.sshConfig.isEmpty, !options.host.isEmpty, !options.closedHost.isEmpty else {
    FileHandle.standardError.write(Data("usage: TerminalKitSelfTest --ssh-config PATH --host ALIAS --closed-host ALIAS --agent-sock PATH\n".utf8))
    exit(2)
}

if ProcessInfo.processInfo.environment["AEROOPS_TK_DEBUG"] == "1" {
    TerminalDebugLog.categories = [.lifecycle, .actions]
    TerminalDebugLog.isEnabled = true
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let selfTest = SelfTest(options: options)
app.activate()
Task { @MainActor in
    let status = await selfTest.run()
    exit(status)
}
// Watchdog: never hang a CI shell.
Task { @MainActor in
    try? await Task.sleep(for: .seconds(180))
    print("RESULT FAIL (timeout)")
    exit(3)
}
app.run()
