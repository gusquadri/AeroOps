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

/// One terminal tab: a ``TerminalLaunchSpec`` running on a pseudo-terminal, shown in a
/// libghostty surface.
///
/// Created by ``TerminalSessionManager/open(_:appearance:)``. The session owns its AppKit
/// surface view, so scrollback survives SwiftUI re-creating ``TerminalSurfaceView``. The
/// surface is the memory-heavy part and can be freed while the tab is hidden
/// (``suspend()``); the program keeps running, and the next time the tab is shown a new surface
/// is rebuilt from the program's recent output.
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
    /// The surface was freed to save memory while the tab is hidden; the program still runs.
    /// Showing the session again rebuilds it.
    public private(set) var isSuspended = false
    /// A clipboard request waiting for the user (an unsafe multi-line paste). Shown by
    /// ``TerminalSurfaceView``; answer it with ``TerminalClipboardPrompt/allow()`` or
    /// ``TerminalClipboardPrompt/deny()``.
    public internal(set) var clipboardPrompt: TerminalClipboardPrompt?

    /// The surface view while the session has one (created when first shown, freed by
    /// ``suspend()`` and ``close()``).
    @ObservationIgnored private(set) var terminalView: AppTerminalView?
    @ObservationIgnored private var bridge: SurfaceDelegateBridge?
    @ObservationIgnored private var controller: TerminalController?
    @ObservationIgnored private var surface: TerminalSurface?
    /// The surface's I/O and its token with ``process``.
    @ObservationIgnored private var surfaceIO: InMemoryTerminalSession?
    @ObservationIgnored private var surfaceToken = 0
    /// `nil` when the session failed before it could start.
    @ObservationIgnored private var process: TerminalProcess?
    /// PID of the program, the root of its process tree.
    @ObservationIgnored private var rootPID: pid_t?
    @ObservationIgnored private var reportedExitCode: Int32?
    /// libghostty asked to close the surface because the program ended.
    @ObservationIgnored private var programEndedCloseSeen = false
    /// Called when the terminal asks to be closed: libghostty's `close_surface` key binding
    /// while the program runs, or a key press after it ended ("Press any key to close the
    /// terminal", which libghostty prints on every exit). The manager handles it.
    @ObservationIgnored var onCloseRequest: ((TerminalSession) -> Void)?
    /// Called when the surface goes on screen (`true`) or leaves it (`false`). The manager
    /// uses it to free the surfaces of the least recently shown sessions.
    @ObservationIgnored var onVisibilityChange: ((TerminalSession, Bool) -> Void)?
    @ObservationIgnored package private(set) var lastReapReport: ReapReport?

    init(spec: TerminalLaunchSpec, appearance: TerminalAppearance) {
        id = UUID()
        self.spec = spec
        self.appearance = appearance
        title = spec.title
        fontSize = appearance.clampedFontSize

        do throws(TerminalLaunchError) {
            try spec.validate()
        } catch {
            state = .failed(message: error.description)
            return
        }

        // Checked once here; the first surface uses this controller.
        let controller = Self.makeController(appearance: appearance)
        if let issue = controller.lastConfigurationIssue {
            state = .failed(message: "terminal configuration rejected: \(issue)")
            return
        }
        self.controller = controller
        // Events arrive on the process's queues; main.async keeps their order.
        process = TerminalProcess(spec: spec) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.processEvent(event)
                }
            }
        }
    }

    private static func makeController(appearance: TerminalAppearance) -> TerminalController {
        TerminalController(
            configuration: GhosttyConfig.configuration(appearance: appearance),
            theme: GhosttyConfig.theme(appearance: appearance)
        )
    }

    // MARK: - Surface

    /// The surface view, created on first use and again after ``suspend()``; `nil` once
    /// closed or when the session failed to start. The program starts once the first
    /// surface's size has settled.
    func surfaceView() -> AppTerminalView? {
        if let terminalView { return terminalView }
        guard !isClosed, let process else { return nil }

        let controller = controller ?? Self.makeController(appearance: appearance)
        let token = process.makeToken()
        let io = InMemoryTerminalSession(
            write: { [weak process] data in process?.write(data, token: token) },
            resize: { [weak process] viewport in process?.resize(viewport, token: token) }
        )
        let bridge = SurfaceDelegateBridge()
        bridge.session = self
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // Delegate before controller and configuration, so the surface's first callbacks land.
        view.delegate = bridge
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(io),
            // A zoom carries over to the rebuilt surface.
            fontSize: fontSize == appearance.clampedFontSize ? nil : fontSize
        )
        // The surface starts once the view is in a window with a size.
        view.controller = controller

        self.controller = controller
        self.bridge = bridge
        surfaceIO = io
        surfaceToken = token
        terminalView = view
        isSuspended = false
        return view
    }

    /// Whether the session holds a surface view now.
    var hasSurface: Bool { terminalView != nil }

    /// Whether the surface view is in a window.
    var isOnScreen: Bool { terminalView?.window != nil }

    /// Frees the surface, its libghostty app and its view (the memory-heavy part) while the
    /// program keeps running; its output keeps being recorded. Showing the session again
    /// rebuilds the surface. Does nothing while the surface is on screen.
    public func suspend() {
        guard !isClosed, hasSurface, !isOnScreen else { return }
        tearDownSurface()
        isSuspended = true
    }

    private func tearDownSurface() {
        clipboardPrompt?.deny()
        clipboardPrompt = nil
        process?.detach(token: surfaceToken)
        if let terminalView {
            terminalView.delegate = nil
            // Synchronous: tears down and frees the surface.
            terminalView.controller = nil
            terminalView.removeFromSuperview()
        }
        bridge?.session = nil
        bridge = nil
        terminalView = nil
        controller = nil
        surface = nil
        surfaceIO = nil
        isFocused = false
    }

    func visibilityChanged(_ visible: Bool) {
        onVisibilityChange?(self, visible)
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
        return terminalView?.copySelectedTextToPasteboard() ?? false
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
        guard !isClosed, let terminalView else { return false }
        return terminalView.acquireProgrammaticFocus()
    }

    /// Ends the session: frees the surface and makes sure the program's process tree is gone.
    ///
    /// The program's process group gets SIGHUP and its terminal is closed. Anything of ours
    /// that is still alive afterwards (e.g. an ssh `ProxyCommand` that ignores SIGHUP) gets
    /// SIGTERM and then SIGKILL on a background thread. An ssh `ControlPersist` master has
    /// detached into its own session by design and is left alone.
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

        tearDownSurface()
        process?.terminate()
        if !state.isFinished {
            state = .exited(code: reportedExitCode)
        }
        return targets
    }

    private func performBindingAction(_ action: String) {
        guard !isClosed else { return }
        _ = terminalView?.performBindingAction(action)
    }

    // MARK: - Surface callbacks (via SurfaceDelegateBridge)

    fileprivate func surfaceAttached(_ surface: TerminalSurface) {
        self.surface = surface
        // A new surface reports the end of an exited program again.
        programEndedCloseSeen = false
        if let surfaceIO {
            process?.attach(surfaceIO, token: surfaceToken)
        }
    }

    fileprivate func surfaceDetached() {
        surface = nil
        process?.detach(token: surfaceToken)
    }

    fileprivate func titleChanged(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else { return }
        title = trimmed
    }

    private func processEvent(_ event: TerminalProcess.Event) {
        guard !isClosed else { return }
        switch event {
        case let .started(pid):
            guard rootPID == nil else { return }
            rootPID = pid
            if state == .starting {
                state = .running
            }
        case let .failed(message):
            if !state.isFinished {
                state = .failed(message: message)
            }
        case let .exited(code):
            guard reportedExitCode == nil else { return }
            reportedExitCode = code
            if !state.isFinished {
                state = .exited(code: code)
            }
        }
    }

    fileprivate func closeRequested(processAlive: Bool) {
        guard !isClosed else { return }
        // While the program runs this is the close binding. After it ended, libghostty asks
        // once when it ends and again on each key press: those are the user's. Both come from
        // inside libghostty's key handling, so act once it has returned.
        if processAlive || programEndedCloseSeen {
            Task { [weak self] in
                guard let self, !isClosed else { return }
                if let onCloseRequest {
                    onCloseRequest(self)
                } else {
                    close()
                }
            }
            return
        }
        // The program ended. Keep the surface so its last output stays readable. The exit
        // event reaches the main thread on its own path, so it can come after this close:
        // give it a moment before settling without a code.
        programEndedCloseSeen = true
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

// MARK: - Self-test hooks

/// Drive a session without a keyboard. SPI, so only code that opts in with
/// `@_spi(AeroSelfTest) import TerminalKit` (the package self-test and the app's DEBUG
/// self-tests) sees them.
extension TerminalSession {
    /// PID of the program once it started.
    @_spi(AeroSelfTest) public var processRootPID: pid_t? { rootPID }

    /// Types `text` as key presses (US layout); `\n` presses Return, `\u{7f}` Backspace.
    @discardableResult
    @_spi(AeroSelfTest) public func type(_ text: String) -> Bool {
        guard !isClosed, let terminalView else { return false }
        for character in text {
            let sent: Bool
            if character == "\n" {
                sent = terminalView.sendKey(.enter)
            } else if character == "\u{7f}" {
                sent = terminalView.sendKey(.backspace)
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
    @_spi(AeroSelfTest) public func pressEscape() -> Bool {
        guard !isClosed, let terminalView else { return false }
        return terminalView.sendKey(.escape)
    }

    /// Screen plus scrollback as text (selects all, reads the selection).
    @_spi(AeroSelfTest) public func screenText() -> String? {
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
