import Foundation
import Observation

/// The open terminal tabs, in tab order.
@MainActor
@Observable
public final class TerminalSessionManager {
    /// Open sessions in tab order. Closed sessions are removed.
    public private(set) var sessions: [TerminalSession] = []
    /// Appearance for sessions opened without an explicit one.
    public var defaultAppearance: TerminalAppearance

    public init(defaultAppearance: TerminalAppearance = .aero) {
        self.defaultAppearance = defaultAppearance
    }

    /// Opens a session and appends it to ``sessions``. The program starts as soon as the
    /// session's ``TerminalSurfaceView`` is on screen. Check ``TerminalSession/state``: an
    /// invalid spec yields a session in `.failed`.
    @discardableResult
    public func open(_ spec: TerminalLaunchSpec, appearance: TerminalAppearance? = nil) -> TerminalSession {
        let session = TerminalSession(spec: spec, appearance: appearance ?? defaultAppearance)
        session.onCloseRequest = { [weak self] session in
            self?.close(session.id)
        }
        sessions.append(session)
        return session
    }

    public func session(id: TerminalSession.ID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    /// Closes the session (ending its process tree) and removes it from ``sessions``.
    public func close(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.close()
    }

    /// Closes every session and waits (bounded) until their processes are gone. Call it from
    /// `applicationWillTerminate`.
    public func closeAll() {
        let closing = sessions
        sessions.removeAll()
        for session in closing {
            session.closeAndWait()
        }
    }

    /// Reorders tabs, with the same semantics as `Array.move(fromOffsets:toOffset:)`.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
    }
}
