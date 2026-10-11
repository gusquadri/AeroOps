import AppKit
import Foundation
import Observation
internal import GhosttyTerminal

/// Terminal grid size in character cells.
public struct TerminalGridSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// One terminal tab: a libghostty surface running a ``TerminalLaunchSpec``.
///
/// Created by ``TerminalSessionManager/open(_:appearance:)``. The session owns its AppKit
/// surface view, so scrollback survives SwiftUI re-creating ``TerminalSurfaceView``.
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public enum State: Sendable, Hashable {
        /// The surface or the program has not started yet.
        case starting
        /// The program is running.
        case running
        /// The program ended. `code` is its exit status (255 for an ssh connection or auth
        /// failure, 128+N when killed by signal N); `nil` when it ended without reporting one,
        /// e.g. because the tab was closed while it was running.
        case exited(code: Int32?)
        /// The session could not start (invalid spec, rejected configuration, ...).
        case failed(message: String)

        public var isFinished: Bool {
            switch self {
            case .starting, .running: false
            case .exited, .failed: true
            }
        }
    }

    public nonisolated let id: UUID
    public nonisolated let spec: TerminalLaunchSpec
    public nonisolated let appearance: TerminalAppearance

    /// The program's title (OSC 0/2), or ``TerminalLaunchSpec/title`` until it sets one.
    public private(set) var title: String
    public private(set) var state: State = .starting
    /// Current font size in points.
    public private(set) var fontSize: Float
    /// Current grid size; `nil` until the surface is laid out.
    public private(set) var gridSize: TerminalGridSize?
    /// Whether the surface has keyboard focus.
    public private(set) var isFocused = false
    /// `true` once ``close()`` ran; the surface is gone and the session is inert.
    public private(set) var isClosed = false
    /// A clipboard request waiting for the user (an unsafe multi-line paste). Shown by
    /// ``TerminalSurfaceView``; answer it with ``TerminalClipboardPrompt/allow()`` or
    /// ``TerminalClipboardPrompt/deny()``.
    public internal(set) var clipboardPrompt: TerminalClipboardPrompt?

    @ObservationIgnored let commandLine: TerminalCommandLine
    @ObservationIgnored let terminalView: AppTerminalView
    @ObservationIgnored private let bridge: SurfaceDelegateBridge
    @ObservationIgnored private var controller: TerminalController?
    @ObservationIgnored private var surface: TerminalSurface?
    /// PID of the wrapper `sh`, the root of the program's process tree.
    @ObservationIgnored private var rootPID: pid_t?
    @ObservationIgnored private var reportedExitCode: Int32?
    /// Called when libghostty asks to close a surface whose program is still running
    /// (its `close_surface` key binding); the manager removes the tab.
    @ObservationIgnored var onCloseRequest: ((TerminalSession) -> Void)?
    @ObservationIgnored package private(set) var lastReapReport: ReapReport?

    init(spec: TerminalLaunchSpec, appearance: TerminalAppearance) {
        id = UUID()
        self.spec = spec
        self.appearance = appearance
        title = spec.title
        fontSize = appearance.clampedFontSize
        commandLine = TerminalCommandLine(spec: spec)
        terminalView = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        bridge = SurfaceDelegateBridge()
        bridge.session = self
        // Delegate before controller and configuration, so the surface's first callbacks land.
        terminalView.delegate = bridge

        do throws(TerminalLaunchError) {
            try spec.validate()
        } catch {
            state = .failed(message: error.description)
            return
        }

        let controller = TerminalController(
            configuration: GhosttyConfig.configuration(appearance: appearance, command: commandLine.command),
            theme: GhosttyConfig.theme(appearance: appearance)
        )
        // A rejected config falls back to libghostty's defaults, which would start the user's
        // login shell instead of the spec. Never attach such a controller.
        if let issue = controller.lastConfigurationIssue {
            state = .failed(message: "terminal configuration rejected: \(issue)")
            return
        }
        self.controller = controller
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: spec.workingDirectory,
            envVars: spec.environment
        )
        // The surface (and the process) starts once the view is in a window with a size.
        terminalView.controller = controller
    }

    // MARK: - Commands

    public func increaseFontSize() {
        performBindingAction("increase_font_size:1")
    }

    public func decreaseFontSize() {
        performBindingAction("decrease_font_size:1")
    }

    /// Back to ``TerminalAppearance/fontSize``.
    public func resetFontSize() {
        performBindingAction("reset_font_size")
    }

    /// Copies the selection to the general pasteboard; `false` when nothing is selected.
    @discardableResult
    public func copySelection() -> Bool {
        guard !isClosed else { return false }
        return terminalView.copySelectedTextToPasteboard()
    }

    /// Pastes the general pasteboard (with libghostty's unsafe-paste protection).
    public func paste() {
        performBindingAction("paste_from_clipboard")
    }

    public func selectAll() {
        performBindingAction("select_all")
    }

    /// Gives the surface keyboard focus; `false` while it is not in a window.
    @discardableResult
    public func focus() -> Bool {
        guard !isClosed else { return false }
        return terminalView.acquireProgrammaticFocus()
    }

    /// Ends the session: frees the surface and makes sure the program's process tree is gone.
    ///
    /// Freeing the surface makes libghostty SIGHUP the process group and wait for its direct
    /// child (the `login` wrapper, which waits for the program). Anything of ours that is
    /// still alive afterwards (e.g. an ssh `ProxyCommand` that ignores SIGHUP) gets SIGTERM and
    /// then SIGKILL on a background thread. An ssh `ControlPersist` master has detached into
    /// its own session by design and is left alone.
    public func close() {
        let targets = shutDown()
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let report = ProcessReaper.reap(targets)
            await self?.recordReap(report)
        }
    }

    /// ``close()``, but reaps on the calling thread (bounded to about a second in the worst
    /// case). Used on app quit, when a background reaper would not get to run.
    func closeAndWait() {
        let targets = shutDown()
        lastReapReport = ProcessReaper.reap(targets)
    }

    private func recordReap(_ report: ReapReport) {
        lastReapReport = report
    }

    /// Frees the surface and returns the processes that must be gone afterwards.
    private func shutDown() -> [ProcessEntry] {
        guard !isClosed else { return [] }
        isClosed = true
        let targets = rootPID.map { ProcessTable.tree(rootedAt: $0, in: ProcessTable.snapshot()) } ?? []

        clipboardPrompt?.deny()
        clipboardPrompt = nil
        terminalView.delegate = nil
        // Synchronous: tears down and frees the surface (SIGHUP + wait, see above).
        terminalView.controller = nil
        terminalView.removeFromSuperview()
        controller = nil
        surface = nil
        isFocused = false
        if !state.isFinished {
            state = .exited(code: reportedExitCode)
        }
        return targets
    }

    private func performBindingAction(_ action: String) {
        guard !isClosed else { return }
        _ = terminalView.performBindingAction(action)
    }

    // MARK: - Surface callbacks (via SurfaceDelegateBridge)

    fileprivate func surfaceAttached(_ surface: TerminalSurface) {
        self.surface = surface
    }

    fileprivate func surfaceDetached() {
        surface = nil
    }

    fileprivate func titleChanged(_ newTitle: String) {
        if commandLine.isReport(newTitle) {
            reportReceived(commandLine.decode(title: newTitle))
            return
        }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else { return }
        title = trimmed
    }

    private func reportReceived(_ report: TerminalCommandLine.Report?) {
        switch report {
        case let .started(pid):
            guard rootPID == nil else { return }
            rootPID = pid
            if state == .starting {
                state = .running
            }
        case let .exited(code):
            guard reportedExitCode == nil else { return }
            reportedExitCode = code
            if !state.isFinished {
                state = .exited(code: code)
            }
        case nil:
            break
        }
    }

    fileprivate func closeRequested(processAlive: Bool) {
        guard !isClosed else { return }
        if processAlive {
            if let onCloseRequest {
                onCloseRequest(self)
            } else {
                close()
            }
            return
        }
        // The program ended. Keep the surface so its last output stays readable. The exit
        // report is output and this close is a process event, so they can arrive in either
        // order: give a late report a moment before settling without a code.
        guard !state.isFinished else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.settleAfterExit()
        }
    }

    private func settleAfterExit() {
        guard !state.isFinished else { return }
        if rootPID == nil, reportedExitCode == nil {
            state = .failed(message: "the terminal process ended before the command started")
        } else {
            state = .exited(code: reportedExitCode)
        }
    }

    fileprivate func gridResized(_ metrics: TerminalGridMetrics) {
        let size = TerminalGridSize(columns: Int(metrics.columns), rows: Int(metrics.rows))
        // Arrives during AppKit layout, possibly inside a SwiftUI update: publish next turn.
        Task { [weak self] in
            guard let self, gridSize != size else { return }
            gridSize = size
        }
    }

    fileprivate func focusChanged(_ focused: Bool) {
        Task { [weak self] in
            guard let self, isFocused != focused else { return }
            isFocused = focused
        }
    }

    fileprivate func fontSizeChanged(_ size: Float) {
        guard fontSize != size else { return }
        fontSize = size
    }

    fileprivate func clipboardConfirmationRequested(_ request: TerminalClipboardConfirmationRequest) {
        guard !isClosed else {
            request.respond(allow: false)
            return
        }
        clipboardPrompt?.deny()
        clipboardPrompt = TerminalClipboardPrompt(request: request) { [weak self] prompt in
            guard let self, clipboardPrompt === prompt else { return }
            clipboardPrompt = nil
        }
    }
}

// MARK: - Test and self-test hooks (same package only)

extension TerminalSession {
    /// PID of the wrapper shell once the program started.
    package var processRootPID: pid_t? { rootPID }

    /// Types `text` as key presses (US layout); `\n` presses Return.
    @discardableResult
    package func type(_ text: String) -> Bool {
        guard !isClosed else { return false }
        for character in text {
            let sent: Bool
            if character == "\n" {
                sent = terminalView.sendKey(.enter)
            } else if let press = TerminalKeyPress(typing: character) {
                sent = terminalView.sendKey(press)
            } else {
                sent = terminalView.paste(text: String(character))
            }
            guard sent else { return false }
        }
        return true
    }

    /// Presses Escape.
    @discardableResult
    package func pressEscape() -> Bool {
        guard !isClosed else { return false }
        return terminalView.sendKey(.escape)
    }

    /// Screen plus scrollback as text (selects all, reads the selection).
    package func screenText() -> String? {
        guard !isClosed, let surface else { return nil }
        _ = surface.performBindingAction("select_all")
        return surface.readSelection()
    }
}

/// Receives libghostty's callbacks and forwards them to the session. A separate object so the
/// session's public API does not expose libghostty's delegate protocols.
@MainActor
private final class SurfaceDelegateBridge:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceFontSizeDelegate,
    TerminalSurfaceClipboardConfirmationDelegate
{
    weak var session: TerminalSession?

    func terminalDidChangeTitle(_ title: String) {
        session?.titleChanged(title)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        session?.gridResized(size)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        session?.focusChanged(focused)
    }

    func terminalDidClose(processAlive: Bool) {
        session?.closeRequested(processAlive: processAlive)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        session?.surfaceAttached(surface)
    }

    func terminalDidDetachSurface() {
        session?.surfaceDetached()
    }

    func terminalDidChangeFontSize(_ fontSize: Float) {
        session?.fontSizeChanged(fontSize)
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        if let session {
            session.clipboardConfirmationRequested(request)
        } else {
            request.respond(allow: false)
        }
    }
}
