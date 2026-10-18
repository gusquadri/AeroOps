import SwiftUI
internal import GhosttyTerminal

/// The libghostty surface of an ``EmbeddedTerminalSession``, rebuilt for each connection. On
/// iOS the software keyboard comes with libghostty's accessory bar (Esc, Tab, Ctrl, Alt, arrows,
/// common symbols, paste).
public struct EmbeddedTerminalView: View {
    let session: EmbeddedTerminalSession

    public init(session: EmbeddedTerminalSession) {
        self.session = session
    }

    public var body: some View {
        // Reading `connection` redraws this view when a connect makes a new surface.
        let connection = session.connection
        if let state = session.surfaceState() {
            TerminalSurfaceView(context: state)
                .id(connection)
        } else {
            // Until the first connect: still a view, so the screen's modifiers apply.
            Color.clear
        }
    }
}
