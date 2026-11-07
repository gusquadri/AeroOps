import AppKit
import SwiftUI
internal import GhosttyTerminal

/// Hosts a session's libghostty surface.
///
/// Keyboard input, IME, mouse selection, scrolling and resizing are handled by the surface.
/// Copy, paste and select-all work through the responder chain (the Edit menu's `copy:`,
/// `paste:`, `selectAll:`) and libghostty's Cmd+C / Cmd+V / Cmd+A bindings. Unsafe pastes
/// ask for confirmation in an alert, unless the host app presents
/// ``TerminalSession/clipboardPrompt`` itself (`presentsClipboardPrompts: false`).
///
/// The surface view belongs to the session, so showing the same session again (tab switch,
/// SwiftUI re-creating this view) keeps its screen and scrollback. If the manager freed the
/// surface while the session was hidden, it is rebuilt from the program's recent output. Show
/// a session in at most one place at a time.
public struct TerminalSurfaceView: View {
    private let session: TerminalSession
    private let focusOnAppear: Bool
    private let presentsClipboardPrompts: Bool

    public init(session: TerminalSession, focusOnAppear: Bool = true, presentsClipboardPrompts: Bool = true) {
        self.session = session
        self.focusOnAppear = focusOnAppear
        self.presentsClipboardPrompts = presentsClipboardPrompts
    }

    public var body: some View {
        SurfaceHost(session: session, focusOnAppear: focusOnAppear)
            .alert(
                alertTitle,
                isPresented: Binding(
                    get: { presentsClipboardPrompts && session.clipboardPrompt != nil },
                    set: { presented in
                        if !presented { session.clipboardPrompt?.deny() }
                    }
                ),
                presenting: presentsClipboardPrompts ? session.clipboardPrompt : nil
            ) { prompt in
                Button(allowTitle(prompt.kind)) { prompt.allow() }
                Button("Cancel", role: .cancel) { prompt.deny() }
            } message: { prompt in
                Text(Self.preview(prompt.contents))
            }
    }

    private var alertTitle: String {
        switch session.clipboardPrompt?.kind {
        case .remoteRead: "Allow the remote program to read the clipboard?"
        case .remoteWrite: "Allow the remote program to set the clipboard?"
        case .paste, nil: "Paste text that may run commands?"
        }
    }

    private func allowTitle(_ kind: TerminalClipboardPrompt.Kind) -> String {
        kind == .paste ? "Paste" : "Allow"
    }

    private static func preview(_ text: String) -> String {
        let limit = 400
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

private struct SurfaceHost: NSViewRepresentable {
    let session: TerminalSession
    let focusOnAppear: Bool

    func makeNSView(context _: Context) -> SurfaceContainerView {
        let container = SurfaceContainerView()
        container.show(session, focusOnAppear: focusOnAppear)
        return container
    }

    func updateNSView(_ container: SurfaceContainerView, context _: Context) {
        container.show(session, focusOnAppear: focusOnAppear)
    }

    /// Takes whatever space is offered; with nothing offered (ideal size, e.g. a window that
    /// fits its content) it asks for roughly 80x24 cells rather than collapsing to zero, which
    /// would keep libghostty from ever creating the surface.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: SurfaceContainerView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 640, height: 400))
    }

    static func dismantleNSView(_ container: SurfaceContainerView, coordinator _: ()) {
        container.releaseSurface()
    }
}

/// Plain container that adopts the session's surface view and keeps it filling its bounds.
///
/// Tells the session when its surface goes on screen and leaves it, so the manager can free
/// the surfaces of sessions that have not been shown for a while. A freed surface is rebuilt
/// here once the container is in a window again.
final class SurfaceContainerView: NSView {
    private weak var session: TerminalSession?
    /// The session last reported as on screen.
    private weak var shownSession: TerminalSession?
    private var focusPending = false

    override var isFlipped: Bool { true }

    func show(_ session: TerminalSession, focusOnAppear: Bool) {
        if self.session !== session {
            releaseSurface()
            self.session = session
            focusPending = focusOnAppear
        }
        adoptSurface()
        focusIfPending()
    }

    private func adoptSurface() {
        guard let session, !session.isClosed else {
            releaseSurface()
            return
        }
        guard let surfaceView = window != nil ? session.surfaceView() : session.terminalView else {
            updateVisibility()
            return
        }
        if surfaceView.superview !== self {
            surfaceView.removeFromSuperview()
            surfaceView.frame = bounds
            addSubview(surfaceView)
        }
        updateVisibility()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fitSurface()
    }

    override func layout() {
        super.layout()
        fitSurface()
    }

    private func fitSurface() {
        guard let surfaceView = session?.terminalView, surfaceView.superview === self,
              surfaceView.frame != bounds else { return }
        surfaceView.frame = bounds
    }

    func releaseSurface() {
        if let surfaceView = session?.terminalView, surfaceView.superview === self {
            surfaceView.removeFromSuperview()
        }
        updateVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            adoptSurface()
        } else {
            updateVisibility()
        }
        focusIfPending()
    }

    /// Reports the session whose surface is in this container while it is in a window.
    private func updateVisibility() {
        var visible: TerminalSession?
        if window != nil, let session, let surfaceView = session.terminalView, surfaceView.superview === self {
            visible = session
        }
        guard visible !== shownSession else { return }
        let previous = shownSession
        shownSession = visible
        previous?.visibilityChanged(false)
        visible?.visibilityChanged(true)
    }

    private func focusIfPending() {
        guard focusPending, window != nil, let session else { return }
        focusPending = false
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, session.terminalView?.superview === self else { return }
            session.focus()
        }
    }
}
