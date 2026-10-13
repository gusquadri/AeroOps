import Foundation
import Observation

/// The open terminal tabs, in tab order.
///
/// Every session's program keeps running while its tab is hidden, but only the
/// ``liveSurfaceLimit`` most recently shown sessions keep their libghostty surface. The others
/// are suspended (``TerminalSession/suspend()``) and get a new surface when shown again.
@MainActor
@Observable
public final class TerminalSessionManager {
    /// Open sessions in tab order. Closed sessions are removed.
    public private(set) var sessions: [TerminalSession] = []
    /// Appearance for sessions opened without an explicit one.
    public var defaultAppearance: TerminalAppearance
    /// Handles a session asking to be closed from inside the terminal: a key press after its
    /// program ended, or libghostty's close binding while it runs. `nil` closes it at once.
    @ObservationIgnored public var closeRequestHandler: ((TerminalSession) -> Void)?
    /// How many sessions keep their surface, counting the ones on screen (at least 1).
    public var liveSurfaceLimit = 3 {
        didSet { scheduleEviction() }
    }
    /// Session IDs by when they were last on screen, the most recent last.
    @ObservationIgnored private var recency: [TerminalSession.ID] = []
    @ObservationIgnored private var evictionScheduled = false

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
            guard let self else { return }
            if let closeRequestHandler {
                closeRequestHandler(session)
            } else {
                close(session.id)
            }
        }
        session.onVisibilityChange = { [weak self] session, visible in
            self?.visibilityChanged(session, visible: visible)
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
        recency.removeAll { $0 == id }
        session.close()
    }

    /// Closes every session and waits (bounded) until their processes are gone. Call it from
    /// `applicationWillTerminate`.
    public func closeAll() {
        let closing = sessions
        sessions.removeAll()
        recency.removeAll()
        for session in closing {
            session.closeAndWait()
        }
    }

    /// Reorders tabs, with the same semantics as `Array.move(fromOffsets:toOffset:)`.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Surface LRU

    private func visibilityChanged(_ session: TerminalSession, visible: Bool) {
        if visible {
            recency.removeAll { $0 == session.id }
            recency.append(session.id)
        }
        scheduleEviction()
    }

    /// Evicts on the next main-actor turn: visibility changes arrive during AppKit and SwiftUI
    /// updates, and a tab switch hides one session and shows another in the same update.
    private func scheduleEviction() {
        guard !evictionScheduled else { return }
        evictionScheduled = true
        Task { [weak self] in
            guard let self else { return }
            evictionScheduled = false
            evictSurfaces()
        }
    }

    /// Suspends the least recently shown sessions that are off screen until at most
    /// ``liveSurfaceLimit`` sessions hold a surface.
    func evictSurfaces() {
        let open = Set(sessions.map(\.id))
        recency.removeAll { !open.contains($0) }
        var live = sessions.filter(\.hasSurface)
        let limit = max(1, liveSurfaceLimit)
        guard live.count > limit else { return }
        // Never shown sessions first (their surface was built but not used), then by recency.
        live.sort { rank($0.id) < rank($1.id) }
        var excess = live.count - limit
        for session in live where excess > 0 && !session.isOnScreen {
            session.suspend()
            excess -= 1
        }
    }

    private func rank(_ id: TerminalSession.ID) -> Int {
        recency.firstIndex(of: id) ?? -1
    }
}
