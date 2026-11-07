import SwiftUI
internal import GhosttyTerminal

/// The libghostty surface of an ``EmbeddedTerminalSession``, kept between screens and across
/// reconnects, and rebuilt only when a connect follows a shell that exited. On iOS the software keyboard comes with libghostty's accessory bar (Esc, Tab, Ctrl, Alt, arrows,
/// common symbols, paste).
public struct EmbeddedTerminalView: View {
    let session: EmbeddedTerminalSession

    public init(session: EmbeddedTerminalSession) {
        self.session = session
    }

    public var body: some View {
        let connection = session.connection
        if let state = session.surfaceState() {
            TerminalSurfaceView(context: state)
                .id(connection)
        } else {
            Color.clear
        }
    }
}
