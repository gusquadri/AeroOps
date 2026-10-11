import AppKit
import Foundation
import GhosttyTerminal
import Observation

/// Owns the one terminal surface and, in self-test mode, drives it.
@MainActor
@Observable
final class SpikeSession {
    let options: SpikeOptions
    let terminal: TerminalViewState
    let exitNonce = UUID().uuidString.prefix(8).lowercased()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var closeEvent: (processAlive: Bool, at: Date)?
    @ObservationIgnored private var report = SelfTestReport()
    @ObservationIgnored private let debugLog: DebugLogFile?

    init(options: SpikeOptions) {
        self.options = options

        // Ghostty debug log (actions + lifecycle) next to the result file:
        // evidence of which C actions fire (e.g. show_child_exited).
        if let result = options.selftestResult {
            let log = DebugLogFile(path: result + ".ghostty.log")
            debugLog = log
            TerminalDebugLog.sink = { log.write($0) }
            TerminalDebugLog.enable([.lifecycle, .actions])
        } else {
            debugLog = nil
        }

        let command = Self.buildCommand(options: options, nonce: String(exitNonce))
        // Colours go through TerminalTheme: the theme is layered over the base
        // config, so a background set in the base config is overridden by it.
        let aero = TerminalConfiguration {
            $0.withBackground("0B3D5C")
            $0.withForeground("E6F4FF")
            $0.withCursorColor("7FDBFF")
        }
        let theme = TerminalTheme(light: aero, dark: aero)
        let controller: TerminalController
        if options.exitMode.commandInAppConfig {
            // Command lives in the app-level config so `wait-after-command = false`
            // is honoured (a per-surface command forces it to true upstream).
            controller = TerminalController(theme: theme) {
                $0.withCustom("command", command)
                $0.withCustom("wait-after-command", "false")
                if let ms = options.abnormalRuntime { $0.withCustom("abnormal-command-exit-runtime", ms) }
            }
        } else {
            controller = TerminalController(theme: theme) {
                if let ms = options.abnormalRuntime { $0.withCustom("abnormal-command-exit-runtime", ms) }
            }
        }
        terminal = TerminalViewState(controller: controller)

        var env: [String: String] = [
            "TERM": "xterm-256color",
            "AERO_SPIKE_MARKER": "surface-1",
        ]
        if let sock = options.agentSock { env["SSH_AUTH_SOCK"] = sock }

        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: 13,
            workingDirectory: NSTemporaryDirectory(),
            envVars: env,
            command: options.exitMode.commandInAppConfig ? nil : command,
            waitAfterCommand: false
        )
        report.mode = options.exitMode.rawValue
        report.command = command
        report.env = env

        terminal.onClose = { [weak self] alive in
            guard let self else { return }
            closeEvent = (alive, Date())
            report.log("close callback fired processAlive=\(alive)")
        }
    }

    func start() {
        guard !started else { return }
        started = true
        terminal.requestFocus()
        if options.selftestResult != nil {
            Task { await runSelfTest() }
        }
    }

    // MARK: - Command

    static func buildCommand(options: SpikeOptions, nonce: String) -> String {
        var args = ["/usr/bin/ssh"]
        let selftest = options.selftestResult != nil
        if let key = options.key {
            // -F /dev/null keeps the user's ~/.ssh/config (and any IdentityAgent) out.
            args += ["-F", "/dev/null",
                     "-o", "IdentityFile=\(key)", "-o", "IdentitiesOnly=yes",
                     "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                     "-o", "LogLevel=ERROR"]
        }
        args += ["-p", options.port]
        if selftest { args += ["-tt"] }
        args += ["dev@localhost"]
        var command = args.map(shq).joined(separator: " ")

        guard selftest else { return command }

        // Expanded locally by the bash -c that ghostty wraps the command in:
        // proves the per-surface env and cwd reached the spawned process.
        command += #" "echo LOCAL_MARKER=$AERO_SPIKE_MARKER LOCAL_SOCK=$SSH_AUTH_SOCK LOCAL_PWD=$PWD;" "#
        // Runs on the remote shell.
        let remote = [
            #"printf "\033]2;AERO_TITLE\007""#,
            #"printf "SIZE1=%s\n" "$(stty size)""#,
            #"echo "REMOTE_TERM=$TERM""#,
            "echo AERO_READY1",
            "read -r a",
            #"printf "SIZE2=%s\n" "$(stty size)""#,
            #"echo "PASTE=$a""#,
            "echo AERO_READY2",
            "read -r b",
            #"printf "SIZE3=%s\n" "$(stty size)""#,
            "echo AERO_OK",
            "exit 3",
        ].joined(separator: "; ")
        command += shq(remote)

        if options.exitMode.reportsExitCode {
            let report = #"rc=$?; printf '\033]777;notify;aeroops-exit-"# + nonce
                + #";%d\007' "$rc"; exit "$rc""#
            command = "/bin/sh -c " + shq(command + "; " + report)
        }
        return command
    }

    // MARK: - Self-test

    private func screenText() -> String {
        terminal.performBindingAction("select_all")
        return terminal.surface?.readSelection() ?? ""
    }

    private func waitFor(_ what: String, timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        report.log("timeout waiting for \(what)")
        return condition()
    }

    private func value(after prefix: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix(prefix) { return String(l.dropFirst(prefix.count)) }
        }
        return nil
    }

    private func runSelfTest() async {
        let t0 = Date()
        report.log("selftest start mode=\(options.exitMode.rawValue)")
        if options.expectFail { return await runFailTest(t0) }

        // 1. Process starts, remote prints sizes and READY1.
        _ = await waitFor("surface", timeout: 10) { terminal.surface != nil }
        let ready1 = await waitFor("AERO_READY1", timeout: 20) {
            screenText().contains("AERO_READY1") || closeEvent != nil
        }
        var text = screenText()
        report.snapshots["ready1"] = text
        report.processTree = ProcessProbe.descendants(of: getpid())
        report.sshEnvironment = ProcessProbe.environmentOfFirstSSH(in: report.processTree)
        guard ready1, text.contains("AERO_READY1") else {
            report.check("spawn", false, "AERO_READY1 never appeared")
            return await finish(t0)
        }
        let grid1 = terminal.surfaceSize
        let size1 = value(after: "SIZE1=", in: text) ?? "?"
        report.check("spawn", true, "ssh ran remote script; process tree captured")
        let localMarker = value(after: "LOCAL_MARKER=", in: text) ?? ""
        report.check("env.marker", localMarker.hasPrefix("surface-1"), "LOCAL_MARKER line: \(localMarker)")
        let remoteTerm = value(after: "REMOTE_TERM=", in: text) ?? "?"
        report.check("env.TERM", remoteTerm == "xterm-256color", "remote $TERM=\(remoteTerm)")
        report.check("env.SSH_AUTH_SOCK", text.contains("LOCAL_SOCK=\(options.agentSock ?? "<none>")"),
                     "login used agent at per-surface SSH_AUTH_SOCK (key file is .pub only)")
        let localPwd = localMarker.components(separatedBy: "LOCAL_PWD=").last ?? ""
        report.check("cwd", URL(fileURLWithPath: localPwd).standardizedFileURL.path
                     == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path,
                     "LOCAL_PWD=\(localPwd) workingDirectory=\(NSTemporaryDirectory())")
        report.check("title", terminal.title == "AERO_TITLE", "title=\(terminal.title)")
        report.check("colours", terminal.backgroundColor == TerminalColor(red: 0x0B, green: 0x3D, blue: 0x5C),
                     "backgroundColor=\(terminal.backgroundColor)")

        // 2. Resize the window, then a font-size change; both must reach the remote.
        // Relative to the current size: SwiftUI restores the last frame, so an
        // absolute target can be a no-op.
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            let current = window.contentLayoutRect.size
            let grow = current.width < 1000
            window.setContentSize(NSSize(width: current.width + (grow ? 300 : -300),
                                         height: current.height + (grow ? 200 : -150)))
        }
        _ = await waitFor("grid resize", timeout: 5) { terminal.surfaceSize?.columns != grid1?.columns }
        try? await Task.sleep(for: .milliseconds(800))
        let grid2 = terminal.surfaceSize

        // 3. Paste: put a string on the pasteboard, paste_from_clipboard, then Enter.
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString("aero-paste-42", forType: .string)
        let pasted = terminal.performBindingAction("paste_from_clipboard")
        try? await Task.sleep(for: .milliseconds(300))
        terminal.sendKey(.enter)
        let ready2 = await waitFor("AERO_READY2", timeout: 10) { screenText().contains("AERO_READY2") }
        text = screenText()
        report.snapshots["ready2"] = text
        let size2 = value(after: "SIZE2=", in: text) ?? "?"
        report.check("resize.window", ready2 && size1 != size2 && size2 == "\(grid2?.rows ?? 0) \(grid2?.columns ?? 0)",
                     "remote stty size \(size1) -> \(size2); grid \(desc(grid1)) -> \(desc(grid2))")
        report.check("paste", value(after: "PASTE=", in: text) == "aero-paste-42",
                     "paste_from_clipboard returned \(pasted); remote read PASTE=\(value(after: "PASTE=", in: text) ?? "?")")

        // 4. Copy: select_all + copy_to_clipboard lands on NSPasteboard.
        pasteboard.clearContents()
        terminal.performBindingAction("select_all")
        let copied = terminal.performBindingAction("copy_to_clipboard")
        try? await Task.sleep(for: .milliseconds(300))
        let clip = pasteboard.string(forType: .string) ?? ""
        report.check("copy", clip.contains("AERO_READY2"),
                     "copy_to_clipboard returned \(copied); pasteboard has \(clip.count) chars")
        pasteboard.clearContents()
        if let savedClipboard { pasteboard.setString(savedClipboard, forType: .string) }

        // 5. Font size: increase by 4pt; the grid shrinks and the remote sees it.
        let gridBeforeFont = terminal.surfaceSize
        terminal.performBindingAction("increase_font_size:4")
        _ = await waitFor("font grid change", timeout: 5) { terminal.surfaceSize?.columns != gridBeforeFont?.columns }
        try? await Task.sleep(for: .milliseconds(500))
        let grid3 = terminal.surfaceSize
        report.fontSize = terminal.fontSize

        // 6. Let the remote finish: SIZE3, AERO_OK, exit 3.
        terminal.sendKey(.enter)
        let okSeen = await waitFor("AERO_OK", timeout: 10) { closeEvent != nil || screenText().contains("AERO_OK") }
        let okAt = Date()
        if closeEvent == nil { text = screenText(); report.snapshots["ok"] = text }
        let size3 = value(after: "SIZE3=", in: report.snapshots["ok"] ?? "") ?? "?"
        report.check("resize.font", grid3?.columns != gridBeforeFont?.columns
                     && (size3 == "?" || size3 == "\(grid3?.rows ?? 0) \(grid3?.columns ?? 0)"),
                     "fontSize=\(terminal.fontSize.map { "\($0)" } ?? "nil"); grid \(desc(gridBeforeFont)) -> \(desc(grid3)); remote SIZE3=\(size3)")

        // 7. Exit callback. Wait long enough to see whether ghostty closes a
        // surface whose command exited without a keypress.
        _ = await waitFor("close callback", timeout: 20) { closeEvent != nil }
        if closeEvent == nil {
            report.snapshots["after-exit"] = screenText()
            report.log("no close callback 20 s after exit; process exited flag visible=\(report.snapshots["after-exit"]?.contains("Process exited") ?? false)")
            if options.exitMode.reportsExitCode {
                report.exitCodeFromOSC = terminal.lastDesktopNotificationTitle == "aeroops-exit-\(exitNonce)"
                    ? terminal.lastDesktopNotificationBody : nil
            }
            // Ghostty closes a waiting surface on any key that encodes a character.
            terminal.sendKey(TerminalKeyPress(typing: "q")!)
            _ = await waitFor("close callback after keypress", timeout: 5) { closeEvent != nil }
            report.closeNeededKeypress = closeEvent != nil
        } else {
            report.closeNeededKeypress = false
        }
        if options.exitMode.reportsExitCode, report.exitCodeFromOSC == nil {
            report.exitCodeFromOSC = terminal.lastDesktopNotificationTitle == "aeroops-exit-\(exitNonce)"
                ? terminal.lastDesktopNotificationBody : nil
        }
        report.closeSecondsAfterOK = closeEvent.map { $0.at.timeIntervalSince(okAt) }
        report.check("exit.callback", okSeen && closeEvent?.processAlive == false,
                     "closeEvent=\(closeEvent.map { "processAlive=\($0.processAlive)" } ?? "none"); needed keypress=\(report.closeNeededKeypress ?? false)")
        if options.exitMode.reportsExitCode {
            report.check("exit.code", report.exitCodeFromOSC == "3", "OSC 777 exit code=\(report.exitCodeFromOSC ?? "nil")")
        }
        await finish(t0)
    }

    /// The command exits within milliseconds (connection refused). Records
    /// whether the close callback fires, what the surface shows, and the
    /// OSC exit code, then closes with a keypress if still open.
    private func runFailTest(_ t0: Date) async {
        _ = await waitFor("surface", timeout: 10) { terminal.surface != nil }
        let closed = await waitFor("close callback", timeout: 10) { closeEvent != nil }
        if !closed { report.snapshots["after-exit"] = screenText() }
        report.exitCodeFromOSC = terminal.lastDesktopNotificationTitle == "aeroops-exit-\(exitNonce)"
            ? terminal.lastDesktopNotificationBody : nil
        if !closed {
            terminal.sendKey(TerminalKeyPress(typing: "q")!)
            _ = await waitFor("close callback after keypress", timeout: 5) { closeEvent != nil }
            report.closeNeededKeypress = closeEvent != nil
        } else {
            report.closeNeededKeypress = false
        }
        report.check("fail.closeWithoutKey", closed && closeEvent?.processAlive == false,
                     "closed=\(closed) abnormalRuntime=\(options.abnormalRuntime ?? "default 250") screen=\(report.snapshots["after-exit"]?.split(separator: "\n").filter { !$0.isEmpty }.suffix(3).joined(separator: " | ") ?? "-")")
        if options.exitMode.reportsExitCode {
            report.check("fail.exitCode", report.exitCodeFromOSC == "255", "OSC 777 exit code=\(report.exitCodeFromOSC ?? "nil")")
        }
        await finish(t0)
    }

    private func desc(_ g: TerminalGridMetrics?) -> String {
        g.map { "\($0.columns)x\($0.rows)" } ?? "nil"
    }

    private func finish(_ t0: Date) async {
        report.seconds = Date().timeIntervalSince(t0)
        report.processTreeAtEnd = ProcessProbe.descendants(of: getpid())
        report.ghosttyLogPath = debugLog?.path
        if let path = options.selftestResult {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? encoder.encode(report).write(to: URL(fileURLWithPath: path))
        }
        exit(report.checks.allSatisfy(\.pass) ? 0 : 1)
    }
}

// MARK: - Report

struct SelfTestReport: Codable {
    struct Check: Codable {
        var name: String
        var pass: Bool
        var detail: String
    }

    var mode = ""
    var command = ""
    var env: [String: String] = [:]
    var checks: [Check] = []
    var events: [String] = []
    var snapshots: [String: String] = [:]
    var processTree: [String] = []
    var processTreeAtEnd: [String] = []
    var sshEnvironment: [String] = []
    var fontSize: Float?
    var closeNeededKeypress: Bool?
    var closeSecondsAfterOK: Double?
    var exitCodeFromOSC: String?
    var seconds: Double = 0
    var ghosttyLogPath: String?

    mutating func check(_ name: String, _ pass: Bool, _ detail: String) {
        checks.append(Check(name: name, pass: pass, detail: detail))
    }

    mutating func log(_ message: String) {
        events.append(message)
    }
}

final class DebugLogFile: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private let handle: FileHandle?

    init(path: String) {
        self.path = path
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        handle?.write(Data((line + "\n").utf8))
    }
}

// MARK: - Process probing (evidence only)

enum ProcessProbe {
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `pid ppid user args` for every descendant of `root`.
    static func descendants(of root: pid_t) -> [String] {
        let rows = run("/bin/ps", ["-axww", "-o", "pid=,ppid=,user=,args="])
            .split(separator: "\n").map { String($0) }
        var parent: [Int32: Int32] = [:]
        var line: [Int32: String] = [:]
        for row in rows {
            let f = row.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            parent[pid] = ppid
            line[pid] = row.trimmingCharacters(in: .whitespaces)
        }
        func isDescendant(_ pid: Int32) -> Bool {
            var p = parent[pid]
            while let cur = p, cur > 1 {
                if cur == root { return true }
                p = parent[cur]
            }
            return false
        }
        return line.keys.sorted().filter(isDescendant).compactMap { line[$0] }
            .filter { !$0.contains("/bin/ps -axww") }
    }

    /// Environment entries of interest from the first ssh process in `tree`.
    static func environmentOfFirstSSH(in tree: [String]) -> [String] {
        guard let row = tree.first(where: {
            let args = $0.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).last ?? ""
            return args.hasPrefix("-/usr/bin/ssh") || args.hasPrefix("/usr/bin/ssh")
        }),
              let pid = row.split(separator: " ").first.map(String.init) else { return [] }
        let out = run("/bin/ps", ["-E", "-ww", "-o", "command=", "-p", pid])
        return out.split(separator: " ").map(String.init).filter {
            $0.hasPrefix("SSH_AUTH_SOCK=") || $0.hasPrefix("TERM=") || $0.hasPrefix("AERO_SPIKE_MARKER=")
                || $0.hasPrefix("TERMINFO=") || $0.hasPrefix("TERM_PROGRAM=") || $0.hasPrefix("PWD=")
        }
    }
}
