// Phase 0 libghostty spike. Throwaway code: one window, one libghostty surface
// running /usr/bin/ssh against the dev container (dev@localhost:2222).
//
// Interactive:  GhosttySpike [--key <identity>] [--agent-sock <sock>] [--port 2222]
// Self-test:    GhosttySpike --selftest <result.json> --key <id.pub> --agent-sock <sock>
//                            [--exit-mode surface|app|osc] [--port 2222]
// See run-selftest.sh.

import AppKit
import GhosttyTerminal
import SwiftUI

@main
struct GhosttySpikeApp: App {
    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var appDelegate
    @State private var session = SpikeSession(options: SpikeOptions.parse(CommandLine.arguments))

    var body: some Scene {
        Window("Ghostty Spike", id: "main") {
            SpikeView(session: session)
                .frame(minWidth: 400, minHeight: 250)
                .onAppear { session.start() }
        }
        .defaultSize(width: 800, height: 500)
    }
}

final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

struct SpikeView: View {
    let session: SpikeSession

    var body: some View {
        TerminalSurfaceView(context: session.terminal)
            .navigationTitle(session.terminal.title.isEmpty ? "Ghostty Spike" : session.terminal.title)
    }
}

// MARK: - Options

struct SpikeOptions: Sendable {
    enum ExitMode: String, Sendable {
        /// Command passed per surface (`ghostty_surface_config_s.command`).
        case surface
        /// Command set in the app-level config with `wait-after-command = false`.
        case app
        /// Per-surface command wrapped in `/bin/sh -c` that reports `$?` via OSC 777.
        case osc
        /// `app` and `osc` combined: app-level command, wrapped to report `$?`.
        case appOsc = "app-osc"

        var commandInAppConfig: Bool { self == .app || self == .appOsc }
        var reportsExitCode: Bool { self == .osc || self == .appOsc }
    }

    var selftestResult: String?
    var exitMode: ExitMode = .surface
    var key: String?
    var agentSock: String?
    var port = "2222"
    /// Self-test a command that fails fast (e.g. `--port 1`): only the exit path is checked.
    var expectFail = false
    /// Overrides ghostty's `abnormal-command-exit-runtime` (ms, default 250).
    var abnormalRuntime: String?

    static func parse(_ args: [String]) -> SpikeOptions {
        var o = SpikeOptions()
        var i = 1
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--selftest": o.selftestResult = next()
            case "--exit-mode": o.exitMode = next().flatMap(ExitMode.init(rawValue:)) ?? .surface
            case "--key": o.key = next()
            case "--agent-sock": o.agentSock = next()
            case "--port": o.port = next() ?? "2222"
            case "--expect-fail": o.expectFail = true
            case "--abnormal-runtime": o.abnormalRuntime = next()
            default: break
            }
            i += 1
        }
        return o
    }
}

/// POSIX single-quote quoting.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
