#if DEBUG
import AeroCore
import AppKit
import Darwin
import Foundation
import ImageIO
import KeyAgent
import Observation
@preconcurrency import ScreenCaptureKit
import SSHKit
@_spi(AeroSelfTest) import TerminalKit
import UniformTypeIdentifiers

/// `-AeroSelfTest phase4`: drives the Terminals tab in the real main window against the three
/// dev servers and checks Phase 4's "Done when" without a keyboard.
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest phase4 \
///   -AeroSelfTestOutput /tmp/aeroops-phase4.json \
///   -AeroSelfTestAuthorizeScript dev/add-key.sh \     # dev/remove-key.sh next to it revokes the key
///   [-AeroSelfTestScreenshots build/phase4]            # window PNGs (tab strip, vi, top, banners, sheets)
///   [-AeroSelfTestKeepRoot YES]
/// ```
///
/// Needs `dev@localhost:2222`, `dev@localhost:2223` (`docker compose -f dev/compose.yml up -d`) and
/// `dev@aeroops-vm.orb.local:22` (dev/vm). Uses ``Phase2SelfTest``'s temporary root and Keychain
/// service, so `~/.aeroops`, the real hosts and the login Keychain are not touched.
///
/// Steps: a fresh Ed25519 key, authorized on all three servers (nothing connects unless all
/// three took it: sshd's PerSourcePenalties would ban this Mac after failed logins) → hosts and
/// `canOpenSSH` → argv of shell and remote-command tabs → five shell tabs (first contact goes
/// through the trust sheet, trusted automatically here only) → a remote-command tab that exits 7,
/// Reconnect → an unreachable host (exit 255) → `stty size; tput cols` per tab → vi and top →
/// window resize → copy a selection and paste it into another tab → an unsafe paste asks first →
/// menu shortcuts sent as key events → close every tab and list leftover processes → the quit
/// path (tabs close before the agent stops) → revoke the key, delete it, remove the root.
/// Writes a JSON report (`"ok": true` on success) and quits.
@MainActor
final class Phase4SelfTest {
    private static var defaults: UserDefaults { .standard }
    static var isRequested: Bool { defaults.string(forKey: "AeroSelfTest") == "phase4" }
    static var screenshotDirectory: URL? {
        defaults.string(forKey: "AeroSelfTestScreenshots").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// `remove-key.sh` next to the authorize script.
    static var deauthorizeScript: URL? {
        guard let script = Phase2SelfTest.authorizeScript?.deletingLastPathComponent().appending(path: "remove-key.sh"),
              FileManager.default.isExecutableFile(atPath: script.path(percentEncoded: false)) else { return nil }
        return script
    }

    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
    }

    struct Report: Codable {
        var ok = false
        var root = ""
        var argv: [String: [String]] = [:]
        var tabTitles: [String] = []
        var ptySizes: [String] = []
        var resize: [String] = []
        var copiedText: String?
        var pastedIntoOtherTab: Bool?
        var unsafePasteAskedFirst: Bool?
        var shortcuts: [String: Bool] = [:]
        var processesWithTabsOpen: [String] = []
        var processesAfterClosingTabs: [String] = []
        var processesAfterQuitPath: [String] = []
        var screenshots: [String] = []
        var steps: [Step] = []
    }

    let model: AppModel
    private var terminals: TerminalService { model.terminals }
    private var report = Report()
    private var window: NSWindow?
    private var key: SSHKeyRecord?
    private var publicKeyPath: String?
    private var authorizeRan = false
    private var quitPathRan = false
    private var savedPasteboard: [[NSPasteboard.PasteboardType: Data]] = []
    /// Moments the main window left the Terminals tab during the run, with who did it.
    private var tabSwitches: [String] = []

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - Run

    func runAndQuit() async {
        savePasteboard()
        await run()
        await finish()
        restorePasteboard()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                try? data.write(to: url, options: .atomic)
            }
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED")")
        NSApp.terminate(nil)
    }

    private func run() async {
        let ssh = model.ssh
        report.root = Phase2SelfTest.root.path(percentEncoded: false)

        guard case .running = ssh.agentStatus else {
            return step("agent running", false, "status \(ssh.agentStatus)")
        }
        step("agent running", true, ssh.paths.agentSocket.path(percentEncoded: false))

        // 1. A fresh key, authorized on every dev server.
        let key: SSHKeyRecord
        do {
            key = try await ssh.generateKey(.ed25519, name: "AeroOps phase 4 self-test", policy: .always)
        } catch {
            return step("generate key", false, error.localizedDescription)
        }
        self.key = key
        let publicKeyPath = ssh.paths.publicKeysDirectory.appending(path: "\(key.id.uuidString).pub").path(percentEncoded: false)
        self.publicKeyPath = publicKeyPath
        step("generate key", true, "\(key.algorithm.displayName) \(key.fingerprint)")

        guard let script = Phase2SelfTest.authorizeScript else {
            return step("authorize key", false, "-AeroSelfTestAuthorizeScript dev/add-key.sh is required")
        }
        authorizeRan = true
        let (status, output) = await Phase2SelfTest.runProcess(script, arguments: [publicKeyPath])
        let authorized = output.components(separatedBy: "authorized:").count - 1
        step("authorize key", status == 0 && authorized == 3, "\(authorized) of 3 servers: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        // Never connect to a server that did not take the key (PerSourcePenalties).
        guard status == 0, authorized == 3 else { return }

        // 2. Hosts.
        let keyID = key.id.uuidString
        let hosts = [
            RemoteHost(name: "dev-ssh", address: "localhost", port: 2222, user: "dev", keyId: keyID),
            RemoteHost(name: "dev-alpine", address: "localhost", port: 2223, user: "dev", keyId: keyID),
            RemoteHost(name: "dev-vm", address: "aeroops-vm.orb.local", port: 22, user: "dev", keyId: keyID),
        ]
        // Port 1 refuses connections: ssh fails before authenticating, so no penalty.
        let down = RemoteHost(name: "dev-down", address: "localhost", port: 1, user: "dev", keyId: keyID)
        let keyless = RemoteHost(name: "no-key", address: "localhost", port: 2222, user: "dev")
        do {
            for host in hosts + [down, keyless] {
                try model.addHost(host)
            }
        } catch {
            return step("add hosts", false, error.localizedDescription)
        }
        let openable = await wait(5) { (hosts + [down]).allSatisfy { self.model.canOpenSSH($0.id) } }
        let keylessReason = terminals.unavailableReason(keyless) ?? ""
        step(
            "canOpenSSH", openable && !model.canOpenSSH(keyless.id) && !keylessReason.isEmpty,
            "hosts with the key \(openable); keyless host refused: \(keylessReason)"
        )
        guard openable else { return }

        checkLaunchSpecs(hosts[0])

        // 3. The real main window, Terminals tab.
        guard let window = await mainWindow() else {
            return step("main window", false, "no main window")
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 1180, height: 760))
        model.selection = hosts[0].id
        model.selectedTab = .terminals
        watchSelectedTab()
        await pause(1.0)
        await capture("terminals-empty")
        let windowSize = window.frame.size

        // 4. Five shell tabs: each host once (first contact), then two repeats.
        var shells: [TerminalSession] = []
        for (index, host) in (hosts + hosts.prefix(2)).enumerated() {
            guard let session = await openShell(host, firstContact: index < 3, connectingShot: index == 2 ? "tabs-connecting" : nil) else { return }
            let ready = await wait(25) { session.state == .running && self.hasPrompt(session) }
            let title = terminals.tab(for: session.id)?.title ?? "?"
            step(
                "tab \(index + 1) \(title)", ready,
                ready ? "remote prompt" : "state \(session.state); screen \(lines(session).filter { !$0.isEmpty }.suffix(4)); "
                    + "surface \(session.screenText() != nil), selected \(terminals.selectedSession?.id == session.id), "
                    + "app tab \(model.selectedTab), window visible \(window.occlusionState.contains(.visible)), active \(NSApp.isActive)"
            )
            guard ready else { return }
            shells.append(session)
        }
        let rootPIDs = shells.map(\.processRootPID)

        // 5. A remote-command tab.
        guard await checkRemoteCommand(on: hosts[2]) != nil else { return }
        await checkUnreachable(down)

        report.tabTitles = terminals.sessions.map { terminals.tab(for: $0.id)?.title ?? $0.title }
        let expected = ["dev-ssh", "dev-alpine", "dev-vm", "dev-ssh (2)", "dev-alpine (2)", "dev-vm · exit test"]
        step("tab titles", report.tabTitles == expected, report.tabTitles.joined(separator: " | "))

        await show(shells[2])
        clearSelection(shells[2])
        await pause(0.5)
        await capture("tabs")
        step("window keeps its size", window.frame.size == windowSize, "\(windowSize) -> \(window.frame.size) with \(terminals.sessions.count) tabs")

        // 6. stty size and tput cols in every shell tab, against the surface grid.
        for (index, session) in shells.enumerated() {
            await checkSize(session, label: "SZ_\(index + 1)")
        }
        let alive = zip(shells, rootPIDs).allSatisfy { session, pid in
            session.state == .running && pid != nil && session.processRootPID == pid && kill(pid!, 0) == 0
        }
        step("hidden tabs keep running", alive, "all \(shells.count) shells still on their first process after switching tabs")

        // 7. Full-screen programs.
        await checkVi(shells[2])
        await checkTop(shells[0])

        // 8. Resize.
        await checkResize(shown: shells[2], hidden: shells[3], window: window)

        // 9. Copy and paste between tabs; an unsafe paste asks first.
        await checkCopyPaste(from: shells[2], to: shells[3])
        await checkUnsafePaste(into: shells[1], window: window)

        // 10. Shortcuts through the menus while a terminal has focus.
        await checkShortcuts(focus: shells[2], vm: hosts[2], window: window, windowSize: windowSize)

        // 11. Close every tab: only ControlPersist masters may remain.
        await checkCloseAll()

        // 12. Quit path: a running tab closes before the agent stops.
        await checkQuitPath(hosts[1])

        step("stays on Terminals", tabSwitches.isEmpty, tabSwitches.isEmpty ? "the window never left the Terminals tab" : tabSwitches.joined(separator: " | "))
    }

    // MARK: - Steps

    private func checkLaunchSpecs(_ host: RemoteHost) {
        let context = model.ssh.context
        let config = context.configFile.path(percentEncoded: false)
        let socket = context.agentSocket.path(percentEncoded: false)
        let shell = TerminalService.launchSpec(for: host, kind: .shell, context: context, title: "t")
        let payload = "it's $HOME; `id`"
        let remoteCommand = "printf '%s\\n' \(ShellQuote.quote(payload))"
        let remote = TerminalService.launchSpec(for: host, kind: .remoteCommand(remoteCommand, title: "x"), context: context, title: "t")
        var systemContext = context
        systemContext.agent = .system
        let system = TerminalService.launchSpec(for: host, kind: .shell, context: systemContext, title: "t")
        let inherited = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        report.argv = [
            "shell": [shell.executable] + shell.arguments,
            "remoteCommand": [remote.executable] + remote.arguments,
        ]
        let ok = shell.executable == "/usr/bin/ssh"
            && shell.arguments == ["-F", config, host.sshAlias]
            && shell.environment["SSH_AUTH_SOCK"] == socket
            && remote.arguments == ["-F", config, "-t", host.sshAlias, "--", remoteCommand]
            && remote.environment["SSH_AUTH_SOCK"] == socket
            && system.environment["SSH_AUTH_SOCK"] == inherited
            && TerminalService.baseTitle(hostName: "web", kind: .remoteCommand("x", title: "logs")) == "web · logs"
        step("launch argv", ok, "shell \(report.argv["shell"]!); remote \(report.argv["remoteCommand"]!); system agent socket inherited \(system.environment["SSH_AUTH_SOCK"] == inherited)")
    }

    /// Opens a shell tab through ``AppModel/openSSH(_:)``; first contact goes through the trust
    /// sheet, accepted here as a click on Trust would.
    private func openShell(_ host: RemoteHost, firstContact: Bool, connectingShot: String?) async -> TerminalSession? {
        let before = Set(terminals.sessions.map(\.id))
        func newSession() -> TerminalSession? { terminals.sessions.first { !before.contains($0.id) } }
        model.openSSH(host.id)
        let answered = await wait(20) { self.terminals.trustRequest != nil || newSession() != nil || self.terminals.openError != nil }
        guard answered, terminals.openError == nil else {
            step("open \(host.name)", false, terminals.openError ?? "nothing happened")
            return nil
        }
        if let request = terminals.trustRequest {
            let sheet = await wait(5) { self.window?.attachedSheet != nil }
            if host.port == 2222 { await capture("trust-sheet", sheet: true) }
            do {
                try await terminals.trustAndOpen(request)
            } catch {
                step("first contact \(host.name)", false, "trust failed: \(error.localizedDescription)")
                return nil
            }
            let dismissed = await wait(5) { self.window?.attachedSheet == nil }
            step(
                "first contact \(host.name)", firstContact && sheet && dismissed && request.host.id == host.id,
                "\(request.offered.count) key(s) offered; trust sheet shown \(sheet), dismissed \(dismissed)"
            )
        } else if firstContact {
            step("first contact \(host.name)", false, "opened without asking to trust the host key")
        }
        guard let session = newSession() else {
            step("open \(host.name)", false, "no tab")
            return nil
        }
        if let connectingShot {
            let state = session.state
            await capture(connectingShot)
            print("[selftest] \(connectingShot): tab state \(state) when captured")
        }
        return session
    }

    /// `openSSH(_:remoteCommand:title:)`: one argument after `--`, exit status shown, Reconnect.
    private func checkRemoteCommand(on host: RemoteHost) async -> TerminalSession? {
        let payload = "aero 'quoted' $HOME"
        let command = "stty size; printf '%s\\n' \(ShellQuote.quote(payload)); exit 7"
        let before = Set(terminals.sessions.map(\.id))
        model.openSSH(host.id, remoteCommand: command, title: "exit test")
        guard await wait(10, { self.terminals.sessions.contains { !before.contains($0.id) } }),
              let session = terminals.sessions.first(where: { !before.contains($0.id) }) else {
            step("remote command", false, "no tab")
            return nil
        }
        let exited = await wait(25) { session.state == .exited(code: 7) }
        await pause(0.6)
        await capture("exited-banner")
        let screen = lines(session)
        let printed = screen.contains(payload)
        let ptyLine = screen.firstIndex(of: payload).flatMap { $0 > 0 ? screen[$0 - 1] : nil } ?? ""
        let grid = session.gridSize
        let pty = grid.map { ptyLine == "\($0.rows) \($0.columns)" } ?? false
        let status = TerminalService.status(of: session.state)
        let title = terminals.tab(for: session.id)?.title
        step(
            "remote command", exited && printed && pty && title == "dev-vm · exit test" && status.text == "Exited with code 7",
            "state \(session.state) (\"\(status.text)\"), payload printed literally \(printed), pty \(ptyLine) vs grid \(grid.map { "\($0.rows) \($0.columns)" } ?? "nil"), title \(title ?? "nil")"
        )
        guard exited else { return session }

        // Reconnect replaces the tab in place and runs the command again.
        let index = terminals.sessions.firstIndex { $0.id == session.id }
        let canReconnect = terminals.canReconnect(session.id)
        terminals.reconnect(session.id)
        let replaced = await wait(10) { self.terminals.session(id: session.id) == nil && self.terminals.sessions.count == before.count + 1 }
        guard replaced, let index, let again = terminals.sessions.indices.contains(index) ? terminals.sessions[index] : nil else {
            step("reconnect", false, "tab not replaced (can reconnect \(canReconnect))")
            return nil
        }
        let exitedAgain = await wait(25) { again.state == .exited(code: 7) }
        step(
            "reconnect", canReconnect && exitedAgain && terminals.tab(for: again.id)?.title == title && terminals.selectedID == again.id,
            "same place \(index), title \(terminals.tab(for: again.id)?.title ?? "nil"), state \(again.state)"
        )
        return again
    }

    /// A refused connection ends with 255 and the "ssh failed" hint; closing it needs no confirmation.
    private func checkUnreachable(_ host: RemoteHost) async {
        guard let session = await openShell(host, firstContact: false, connectingShot: nil) else { return }
        let finished = await wait(20) { session.state.isFinished }
        await pause(0.6)
        await capture("ssh-failed")
        let status = TerminalService.status(of: session.state)
        let text = lines(session).joined(separator: "\n")
        let shown = text.contains("Connection refused") || text.contains("connect to host")
        let pressAnyKey = text.contains("Press any key to close")
        // libghostty's "Press any key to close the terminal": a key closes the ended tab.
        let stillOpen = terminals.session(id: session.id) != nil
        session.type("x")
        let closed = await wait(5) {
            self.terminals.session(id: session.id) == nil && self.terminals.tab(for: session.id) == nil
                && self.terminals.closeConfirmation == nil && self.terminals.selectedID != session.id
        }
        step(
            "unreachable host", finished && session.state == .exited(code: 255) && status.text == "ssh failed (exit 255)" && status.hint != nil && shown && stillOpen && closed,
            "state \(session.state), \"\(status.text)\", ssh error on screen \(shown), stays open after exit \(stillOpen), \"Press any key\" shown \(pressAnyKey), a key press closed it without asking \(closed)"
        )
    }

    private func checkSize(_ session: TerminalSession, label: String) async {
        await show(session)
        let title = terminals.tab(for: session.id)?.title ?? "?"
        guard let output = await runCommand(session, "stty size; tput cols 2>/dev/null || echo no-tput", marker: label),
              let index = output.lastIndex(of: label), index >= 2 else {
            return step("pty size \(title)", false, "no output")
        }
        let tput = output[index - 1]
        let stty = output[index - 2]
        let grid = session.gridSize
        let gridText = grid.map { "\($0.rows) \($0.columns)" } ?? "nil"
        let ok = stty == gridText && (tput == "no-tput" || tput == grid.map { String($0.columns) })
        report.ptySizes.append("\(title): stty \(stty), tput cols \(tput), grid \(gridText)")
        step("pty size \(title)", ok, "stty \(stty), tput cols \(tput), grid \(gridText)")
    }

    private func checkVi(_ session: TerminalSession) async {
        await show(session)
        session.type("vi /tmp/aero-phase4-\(getpid()).txt\n")
        let drawn = await wait { self.lines(session).filter { $0 == "~" }.count >= 3 }
        // A key press clears the select-all that reading the screen leaves behind.
        session.pressEscape()
        await pause(0.8)
        await capture("vi")
        session.pressEscape()
        // A lone ESC followed at once by more keys reads as an escape sequence to vi.
        await pause(0.3)
        session.type(":q!\n")
        // Keys typed while vim still runs are encoded for it (it turns on modifyOtherKeys) and
        // it flushes typed-ahead input when it restores the tty: wait for the shell's screen.
        _ = await wait(5) { self.lines(session).filter { $0 == "~" }.count < 3 }
        await pause(0.5)
        let back = await runCommand(session, "true", marker: "VI_DONE") != nil
        let screen = back ? "" : "; screen: \(lines(session).filter { !$0.isEmpty }.suffix(6))"
        step("vi", drawn && back, "drawn \(drawn), back at the prompt \(back)\(screen)")
    }

    private func checkTop(_ session: TerminalSession) async {
        await show(session)
        session.type("top\n")
        let drawn = await wait { self.lines(session).contains { $0.hasPrefix("top - ") || $0.hasPrefix("Tasks:") || $0.hasPrefix("Mem:") } }
        // Space redraws top and clears the select-all left by reading the screen.
        session.type(" ")
        await pause(1.2)
        await capture("top")
        session.type("q")
        // top restores the tty with TCSAFLUSH, discarding input typed before it is gone.
        await pause(0.5)
        let back = await runCommand(session, "true", marker: "TOP_DONE") != nil
        step("top", drawn && back, "drawn \(drawn), back at the prompt \(back)")
    }

    /// The shown tab follows a window resize at once; a hidden one when it is shown again.
    private func checkResize(shown: TerminalSession, hidden: TerminalSession, window: NSWindow) async {
        await show(shown)
        let originalFrame = window.frame
        let original = window.contentRect(forFrameRect: originalFrame).size
        let shownBefore = shown.gridSize
        let hiddenBefore = hidden.gridSize
        window.setContentSize(NSSize(width: 1000, height: 640))
        let followed = await wait(5) { shown.gridSize != shownBefore }
        let shownSize = await stty(shown, marker: "RS_1")
        let shownGrid = shown.gridSize.map { "\($0.rows) \($0.columns)" }
        await show(hidden)
        let hiddenFollowed = await wait(5) { hidden.gridSize != hiddenBefore }
        let hiddenSize = await stty(hidden, marker: "RS_2")
        let hiddenGrid = hidden.gridSize.map { "\($0.rows) \($0.columns)" }
        report.resize = [
            "window \(Int(original.width))x\(Int(original.height)) -> 1000x640",
            "shown tab: grid \(shownBefore.map { "\($0.rows) \($0.columns)" } ?? "nil") -> \(shownGrid ?? "nil"), remote stty \(shownSize ?? "nil")",
            "hidden tab: grid \(hiddenBefore.map { "\($0.rows) \($0.columns)" } ?? "nil") -> \(hiddenGrid ?? "nil"), remote stty \(hiddenSize ?? "nil")",
        ]
        step(
            "resize", followed && shownSize != nil && shownSize == shownGrid && hiddenFollowed && hiddenSize != nil && hiddenSize == hiddenGrid,
            report.resize.joined(separator: "; ")
        )
        window.setFrame(originalFrame, display: true)
        await pause(0.8)
    }

    /// Selects all in one tab (after clearing its screen and scrollback down to one marked line),
    /// copies, and pastes into another.
    private func checkCopyPaste(from source: TerminalSession, to target: TerminalSession) async {
        await show(source)
        source.type(#"printf '\033[3J\033[H\033[2J#aero-copy-%s' 4242"# + "\n")
        let cleared = await wait {
            let screen = self.lines(source)
            return screen.contains { $0.hasPrefix("#aero-copy-4242") } && !screen.contains { $0.contains("printf") }
        }
        source.selectAll()
        let copied = source.copySelection()
        let text = NSPasteboard.general.string(forType: .string)
        report.copiedText = text
        await show(target)
        target.paste()
        let pasted = await wait(5) { self.lines(target).contains { $0.contains("#aero-copy-4242") } }
        let prompted = target.clipboardPrompt != nil
        target.clipboardPrompt?.deny()
        // Run the pasted line: a shell comment.
        target.type("\n")
        let back = await runCommand(target, "true", marker: "CP_DONE") != nil
        report.pastedIntoOtherTab = pasted
        step(
            "copy and paste", cleared && copied && (text?.contains("#aero-copy-4242") ?? false) && pasted && !prompted && back,
            "copied \(copied): \(text.map { "\"\($0)\"" } ?? "nil"); pasted into \(terminals.tab(for: target.id)?.title ?? "?") \(pasted); asked \(prompted)"
        )
    }

    /// Multi-line text into a shell without bracketed paste (BusyBox ash) asks first, as a sheet.
    private func checkUnsafePaste(into session: TerminalSession, window: NSWindow) async {
        await show(session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo aero-unsafe-1\necho aero-unsafe-2\n", forType: .string)
        session.paste()
        let prompted = await wait(5) { session.clipboardPrompt != nil }
        let sheet = await wait(5) { window.attachedSheet != nil }
        await pause(0.5)
        await capture("clipboard-sheet", sheet: true)
        session.clipboardPrompt?.deny()
        let dismissed = await wait(5) { window.attachedSheet == nil }
        let output = await runCommand(session, "true", marker: "UP_DONE")
        let ran = output?.contains("aero-unsafe-1") ?? true
        report.unsafePasteAskedFirst = prompted && sheet && !ran
        step("unsafe paste asks first", prompted && sheet && dismissed && !ran, "prompt \(prompted), sheet \(sheet), dismissed on deny \(dismissed), pasted anyway \(ran)")
    }

    /// App shortcuts reach the menus while the terminal has keyboard focus.
    private func checkShortcuts(focus session: TerminalSession, vm: RemoteHost, window: NSWindow, windowSize: NSSize) async {
        // The menus act on the key window's scene, so the app must be frontmost. Activation
        // is cooperative: ask again for a while if another app keeps it.
        let active = await wait(20) {
            if NSApp.isActive, window.isKeyWindow { return true }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return false
        }
        guard active else {
            return step("shortcuts", false, "AeroOps never became the active app (another app kept the focus), so menu shortcuts cannot reach it")
        }
        await show(session)
        func selectedIndex() -> Int? {
            terminals.sessions.firstIndex { $0.id == terminals.selectedSession?.id }
        }
        let start = selectedIndex() ?? 0
        let count = terminals.sessions.count
        var results: [String: Bool] = [:] {
            didSet {
                for (name, ok) in results where oldValue[name] == nil {
                    print("[selftest]   \(name): \(ok)")
                }
            }
        }
        print("[selftest] shortcuts: app active \(NSApp.isActive), window key \(window.isKeyWindow), tab \(model.selectedTab)")

        press("\t", keyCode: 48, [.control])
        results["⌃Tab next tab"] = await wait(2) { selectedIndex() == (start + 1) % count }
        press("\t", keyCode: 48, [.control, .shift])
        results["⌃⇧Tab previous tab"] = await wait(2) { selectedIndex() == start }
        press("¡", ignoring: "1", keyCode: 18, [.command, .option])
        results["⌘⌥1 first tab"] = await wait(2) { selectedIndex() == 0 }
        press("ª", ignoring: "9", keyCode: 25, [.command, .option])
        results["⌘⌥9 last tab"] = await wait(2) { selectedIndex() == count - 1 }

        await show(session)
        let fontSize = session.fontSize
        press("=", keyCode: 24, [.command])
        results["⌘= bigger"] = await wait(2) { session.fontSize > fontSize }
        await pause(0.5)
        let keptSize = window.frame.size == windowSize
        press("0", keyCode: 29, [.command])
        results["⌘0 actual size"] = await wait(2) { session.fontSize == fontSize }

        // ⌘W on anything but a terminal tab closes the main window, which quits the app.
        let closeItem = Self.menuItem(keyEquivalent: "w", modifiers: .command)
        if closeItem?.title == "Close Tab", model.selectedTab == .terminals, window.isKeyWindow {
            press("w", keyCode: 13, [.command])
            results["⌘W asks before closing a running tab"] = await wait(2) { self.terminals.closeConfirmation == session.id }
        } else {
            print("[selftest] ⌘W skipped: menu item \(closeItem?.title ?? "none"), tab \(model.selectedTab), window key \(window.isKeyWindow)")
            results["⌘W asks before closing a running tab"] = false
        }
        await pause(0.6)
        await capture("close-confirm", sheet: window.attachedSheet != nil)
        terminals.closeConfirmation = nil
        _ = await wait(3) { window.attachedSheet == nil }

        model.selection = vm.id
        let before = Set(terminals.sessions.map(\.id))
        press("t", keyCode: 17, [.command])
        let opened = await wait(5) { self.terminals.sessions.contains { !before.contains($0.id) } }
        let new = terminals.sessions.first { !before.contains($0.id) }
        results["⌘T new tab for the selected host"] = opened && new.flatMap { terminals.tab(for: $0.id)?.title } == "dev-vm (2)"
        if let new {
            _ = await wait(25) { new.state == .running && self.hasPrompt(new) }
            terminals.close(new.id)
        }
        report.shortcuts = results
        step(
            "shortcuts", results.values.allSatisfy { $0 } && results.count == 8 && keptSize,
            results.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "; window size kept on font change \(keptSize)"
        )
    }

    private func checkCloseAll() async {
        let rootPIDs = terminals.sessions.compactMap(\.processRootPID)
        report.processesWithTabsOpen = await processes()
        var asked = 0
        for session in terminals.sessions {
            terminals.requestClose(session.id)
            if terminals.closeConfirmation == session.id {
                asked += 1
                terminals.close(session.id)
            }
        }
        let empty = terminals.sessions.isEmpty && terminals.tabs.isEmpty && terminals.selectedID == nil
        let remaining = await processes(within: 5) { $0.allSatisfy { $0.hasSuffix("[mux]") } }
        report.processesAfterClosingTabs = remaining
        let masters = remaining.filter { $0.hasSuffix("[mux]") }
        let others = remaining.filter { !$0.hasSuffix("[mux]") }
        let rootsGone = rootPIDs.allSatisfy { kill($0, 0) != 0 }
        await pause(0.4)
        await capture("terminals-closed")
        step(
            "close every tab", empty && others.isEmpty && masters.count <= 3 && rootsGone && asked > 0,
            "\(report.processesWithTabsOpen.count) processes with tabs open; after closing: \(masters.count) ControlPersist master(s) (expected ≤ 3, one per host), \(others.count) other(s); tab wrappers gone \(rootsGone); \(asked) running tab(s) asked first"
        )
    }

    private func checkQuitPath(_ host: RemoteHost) async {
        guard let session = await openShell(host, firstContact: false, connectingShot: nil) else { return }
        let ready = await wait(25) { session.state == .running && self.hasPrompt(session) }
        let pid = session.processRootPID
        let socket = model.ssh.paths.agentSocket.path(percentEncoded: false)
        guard ready, let work = model.beginShutdown() else {
            return step("quit path", false, "tab ready \(ready)")
        }
        quitPathRan = true
        // beginShutdown closed the tabs synchronously; the agent stops in `work`.
        let tabsClosedFirst = terminals.sessions.isEmpty && pid.map { kill($0, 0) != 0 } == true
        let agentStillUp = FileManager.default.fileExists(atPath: socket)
        await work()
        let remaining = await processes(within: 5) { $0.isEmpty }
        report.processesAfterQuitPath = remaining
        let socketGone = !FileManager.default.fileExists(atPath: socket)
        let cm = model.ssh.paths.controlMasterDirectory.path(percentEncoded: false)
        let masters = (try? FileManager.default.contentsOfDirectory(atPath: cm)) ?? []
        step(
            "quit path", tabsClosedFirst && agentStillUp && remaining.isEmpty && socketGone && masters.isEmpty,
            "tab closed before the agent stopped \(tabsClosedFirst && agentStillUp), processes left \(remaining.count), agent socket removed \(socketGone), cm/ entries \(masters.count)"
        )
    }

    // MARK: - Cleanup

    private func finish() async {
        let ssh = model.ssh
        if !quitPathRan {
            terminals.closeAll()
            await model.shutdownServices()
        }
        if let key {
            let secret = try? KeychainSecretStore(service: Phase2SelfTest.keychainService).load(for: key.id)
            let found = [Phase2SelfTest.root, AeroPaths.standard.dotDirectory]
                .flatMap { Phase2SelfTest.filesContainingKeyMaterial(under: $0, secret: secret) }
            step("no private key on disk", found.isEmpty && secret != nil, found.isEmpty ? "none under the root or ~/.aeroops" : "found: \(found)")
        }
        if authorizeRan, let publicKeyPath {
            if let script = Self.deauthorizeScript {
                let (status, output) = await Phase2SelfTest.runProcess(script, arguments: [publicKeyPath])
                let revoked = output.components(separatedBy: "revoked:").count - 1
                step("revoke key", status == 0 && revoked == 3, "\(revoked) of 3 servers: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            } else {
                step("revoke key", false, "no executable remove-key.sh next to the authorize script")
            }
        }
        if let key {
            do {
                try await ssh.deleteKey(key.id)
                let remaining = try KeychainSecretStore(service: Phase2SelfTest.keychainService).load(for: key.id)
                step("delete key", remaining == nil, "Keychain item removed \(remaining == nil)")
            } catch {
                step("delete key", false, error.localizedDescription)
            }
        }
        if !Phase2SelfTest.keepsRoot {
            try? FileManager.default.removeItem(at: Phase2SelfTest.root)
        }
        report.ok = !report.steps.isEmpty && report.steps.allSatisfy(\.ok)
    }

    // MARK: - Helpers

    private func step(_ name: String, _ ok: Bool, _ detail: String) {
        report.steps.append(Step(name: name, ok: ok, detail: detail))
        print("[selftest] \(ok ? "PASS" : "FAIL") \(name): \(detail)")
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func wait(_ seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func mainWindow() async -> NSWindow? {
        for _ in 0..<100 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !$0.isSheet }) {
                return window
            }
            await pause(0.1)
        }
        return nil
    }

    /// Selects the tab and gives its terminal focus.
    private func show(_ session: TerminalSession) async {
        if model.selectedTab != .terminals {
            print("[selftest] the window shows \(model.selectedTab), not Terminals; switching back")
            model.selectedTab = .terminals
        }
        terminals.selectedID = session.id
        _ = await wait(3) { session.focus() }
        await pause(0.3)
    }

    /// Reading the screen selects all of it; typing at a prompt clears that (a space, then
    /// Backspace).
    private func clearSelection(_ session: TerminalSession) {
        session.type(" \u{7f}")
    }

    private func lines(_ session: TerminalSession) -> [String] {
        (session.screenText() ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func hasPrompt(_ session: TerminalSession) -> Bool {
        lines(session).contains { $0.hasSuffix("$") }
    }

    /// Types `command; echo <marker>` and returns the screen lines once the marker printed.
    private func runCommand(_ session: TerminalSession, _ command: String, marker: String) async -> [String]? {
        // `''` splits the marker in the echoed command line, so only the output matches.
        let split = marker.prefix(2) + "''" + marker.dropFirst(2)
        session.type("\(command); echo \(split)\n")
        var result: [String]?
        _ = await wait {
            let current = self.lines(session)
            if current.contains(marker) { result = current }
            return result != nil
        }
        return result
    }

    /// `rows columns` from `stty size` on the remote side.
    private func stty(_ session: TerminalSession, marker: String) async -> String? {
        guard let output = await runCommand(session, "stty size", marker: marker),
              let index = output.lastIndex(of: marker), index > 0 else { return nil }
        return output[index - 1]
    }

    /// Sends a key down and up to the app, as the keyboard would.
    private func press(_ characters: String, ignoring: String? = nil, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                isARepeat: false, keyCode: keyCode
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// The main-menu item with this shortcut, searched through every submenu.
    private static func menuItem(keyEquivalent: String, modifiers: NSEvent.ModifierFlags, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.keyEquivalent == keyEquivalent, item.keyEquivalentModifierMask == modifiers {
                return item
            }
            if let found = menuItem(keyEquivalent: keyEquivalent, modifiers: modifiers, in: item.submenu) {
                return found
            }
        }
        return nil
    }

    /// Records (with a call stack) every time the window leaves the Terminals tab.
    private func watchSelectedTab() {
        withObservationTracking {
            _ = model.selectedTab
        } onChange: { [weak self] in
            // Called inside the setter: the stack shows who switched.
            let stack = Thread.callStackSymbols.dropFirst(20).prefix(60).joined(separator: "\n")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let tab = self.model.selectedTab
                let after = self.report.steps.last?.name ?? "start"
                if tab != .terminals {
                    self.tabSwitches.append("\(tab) after \(after)")
                    print("[selftest] selectedTab -> \(tab) after step \(after)\n\(stack)")
                }
                self.watchSelectedTab()
            }
        }
    }

    /// `ps` lines (pid and arguments) of processes that mention the temporary root.
    private func processes() async -> [String] {
        let output = await Self.processTable()
        let root = Phase2SelfTest.root.path(percentEncoded: false)
        let own = getpid()
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(root) }
            .filter { $0.split(separator: " ").first.flatMap { Int32($0) } != own }
    }

    /// `ps -axww -o pid=,args=`, read while it runs: the whole table can be larger than a pipe
    /// buffer, so reading only after it exits would deadlock.
    private nonisolated static func processTable() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(filePath: "/bin/ps")
                process.arguments = ["-axww", "-o", "pid=,args="]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    return continuation.resume(returning: "")
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// ``processes()`` once `condition` holds, or after `seconds`.
    private func processes(within seconds: Double, until condition: ([String]) -> Bool) async -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var list = await processes()
        while !condition(list), Date() < deadline {
            await pause(0.2)
            list = await processes()
        }
        return list
    }

    // MARK: Pasteboard

    /// The user's clipboard, restored after the copy and paste checks.
    private func savePasteboard() {
        savedPasteboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                values[type] = item.data(forType: type)
            }
            return values
        }
    }

    private func restorePasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = savedPasteboard.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        savedPasteboard = []
    }

    // MARK: Screenshots

    /// Captures the main window (or its sheet) to `<screenshots>/<name>.png`.
    private func capture(_ name: String, sheet: Bool = false) async {
        guard let directory = Self.screenshotDirectory, let target = sheet ? window?.attachedSheet : window else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let image = await Self.image(of: target) else {
            return print("[selftest] screenshot \(name) failed")
        }
        let url = directory.appending(path: "\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            report.screenshots.append(url.path(percentEncoded: false))
        }
    }

    /// ScreenCaptureKit's current-process content needs no Screen Recording permission. Falls
    /// back to drawing the view tree (no glass or Metal layers).
    private static func image(of window: NSWindow) async -> CGImage? {
        do {
            let content = try await SCShareableContent.currentProcess
            if let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.showsCursor = false
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
        } catch {
            print("[selftest] ScreenCaptureKit: \(error.localizedDescription)")
        }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}
#endif
