import AeroCore
import EmbeddedSSH
import Foundation
import Observation
import SSHKit
import TerminalStyle
internal import GhosttyTerminal

/// One iOS terminal: a shell on an EmbeddedSSH terminal channel, shown in a libghostty surface
/// (``EmbeddedTerminalView``).
///
/// The surface talks to an `InMemoryTerminalSession`: keys and size changes go to the channel
/// (``TerminalLink``), the channel's output goes to the surface, and the shell's exit status
/// ends it. A dropped connection leaves the surface open: ``reconnect()`` opens a new shell in
/// it, below the old one's output and scrollback, and ``resume()`` does that by itself when the
/// app comes back from the background. Only after the shell exited does a connect build a new
/// surface.
@MainActor
@Observable
public final class EmbeddedTerminalSession {
    public enum State: Sendable, Hashable {
        case connecting
        /// Opening a new shell in the surface of one whose connection dropped.
        case reconnecting
        case running
        /// The shell ended; `exitStatus` is `nil` when it reported none.
        case ended(exitStatus: Int32?)
        /// The connection closed under the shell (the network dropped, the server restarted, iOS
        /// suspended the app long enough for the socket to die).
        case disconnected
        /// The terminal could not be opened (unknown or changed host key, failed login, timeout).
        case failed(SSHError)

        public var isOver: Bool {
            switch self {
            case .connecting, .reconnecting, .running: false
            case .ended, .disconnected, .failed: true
            }
        }
    }

    /// What the current surface has shown.
    enum Surface {
        /// None was built yet.
        case none
        /// No shell ran in it yet.
        case fresh
        /// A shell ran in it and its connection dropped; the next shell continues below it.
        case used
        /// It was told the shell exited and takes no more output or keys.
        case finished
    }

    /// Opens the channel with the terminal's size, e.g. with
    /// ``EmbeddedSSHClient/openTerminal(on:term:size:command:timeout:)`` and ``term``.
    public typealias Opener = @Sendable (PseudoTerminalSize) async throws -> any TerminalChannel

    /// `TERM` for the remote shell: every host has its terminfo.
    public static let term = GhosttyConfig.defaultTerm
    /// The size a channel opens with before the surface reported its own.
    public static let initialSize = PseudoTerminalSize(columns: 80, rows: 24)
    /// How long ``resume()`` waits for a running shell's connection to answer.
    public static let probeTimeout: Duration = .seconds(3)
    /// The Mac's palette, with a font every iOS device has, small enough for about 50 columns
    /// on an iPhone held upright.
    static let appearance: TerminalAppearance = {
        var appearance = TerminalAppearance.aero
        appearance.fontFamily = "Menlo"
        appearance.fontSize = 10
        return appearance
    }()
    /// Written into the surface before a new shell's first output: puts back the modes a program
    /// of the old shell may have left on (alternate screen, DECSTR soft reset, mouse and focus
    /// reports, bracketed paste, kitty keyboard flags), then says the shell is new. Leaving the
    /// alternate screen restores the saved cursor even when it is not on, so the cursor is saved
    /// first and stays below the old output.
    static let reconnectedNote = Data(
        ("\u{1B}7\u{1B}[?1049l\u{1B}[!p\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1004l"
            + "\u{1B}[?2004l\u{1B}[=0;1u\r\n\u{1B}[2m── Reconnected: this is a new shell ──\u{1B}[0m\r\n").utf8
    )

    public private(set) var state: State = .connecting
    /// Bumped by every connect that builds a new surface (the first, and those after the shell
    /// exited): the view builds a new surface for each one.
    public private(set) var connection = 0

    @ObservationIgnored private let open: Opener
    @ObservationIgnored private(set) var link: TerminalLink?
    @ObservationIgnored private(set) var io: InMemoryTerminalSession?
    /// The running shell's channel.
    @ObservationIgnored private var channel: (any TerminalChannel)?
    @ObservationIgnored private(set) var surface: Surface = .none
    @ObservationIgnored private var viewState: TerminalViewState?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by connect and close, so a finishing connection that was replaced is dropped.
    @ObservationIgnored private var generation = 0

    public init(open: @escaping Opener) {
        self.open = open
    }

    /// Opens a new channel, in the current surface unless the shell in it exited. Does nothing
    /// while one is opening or running.
    public func connect() {
        guard task == nil else { return }
        generation += 1
        if surface == .none || surface == .finished { makeSurface() }
        guard let link, let io else { return }
        let reconnecting = surface == .used
        link.expectChannel()
        state = reconnecting ? .reconnecting : .connecting
        task = Task { [token = generation, size = link.size] in
            await run(token: token, size: size, link: link, io: io, reconnected: reconnecting)
        }
    }

    /// Ends the current channel, if any, and opens a new one.
    public func reconnect() {
        close()
        connect()
    }

    /// Ends the channel; the surface keeps its screen for the next connect.
    public func close() {
        generation += 1
        link?.detach()
        channel = nil
        task?.cancel()
        task = nil
        if !state.isOver { state = .disconnected }
    }

    /// Called when the app comes back from the background: a terminal whose connection dropped
    /// reconnects, and a running one reconnects when its connection does not answer within
    /// `probeTimeout`. One attempt; a terminal that failed (a login, a host key) waits for the user.
    public func resume(probeTimeout: Duration = EmbeddedTerminalSession.probeTimeout) async {
        switch state {
        case .disconnected:
            reconnect()
        case .running:
            await reconnectIfUnresponsive(within: probeTimeout)
        case .connecting, .reconnecting, .ended, .failed:
            break
        }
    }

    private func reconnectIfUnresponsive(within timeout: Duration) async {
        guard let channel else { return }
        let token = generation
        let responsive = await channel.isResponsive(within: timeout)
        guard !responsive, token == generation else { return }
        reconnect()
    }

    private func makeSurface() {
        connection += 1
        surface = .fresh
        let link = TerminalLink(size: self.link?.size ?? Self.initialSize)
        self.link = link
        io = InMemoryTerminalSession(
            write: { data in link.write(data) },
            resize: { viewport in link.resize(PseudoTerminalSize(viewport)) }
        )
        viewState = nil
    }

    private func run(token: Int, size: PseudoTerminalSize, link: TerminalLink, io: InMemoryTerminalSession, reconnected: Bool) async {
        let started = ContinuousClock.now
        let channel: any TerminalChannel
        do {
            channel = try await open(size)
        } catch {
            guard token == generation else { return }
            state = .failed(Self.sshError(error))
            task = nil
            return
        }
        guard token == generation else { return channel.close() }
        if reconnected { io.receive(Self.reconnectedNote) }
        link.attach(channel, openedWith: size)
        self.channel = channel
        surface = .used
        state = .running
        let error = await Self.pump(channel, into: io)
        guard token == generation else { return }
        end(channel, error: error, io: io, runtime: Self.milliseconds(since: started))
    }

    /// The channel ended: a shell that exited finishes the surface; a dropped connection leaves
    /// it open for the next shell.
    private func end(_ channel: any TerminalChannel, error: SSHError?, io: InMemoryTerminalSession, runtime: UInt64) {
        link?.detach()
        self.channel = nil
        task = nil
        guard error == nil else {
            state = .disconnected
            return
        }
        let status = channel.exitStatus
        io.finish(exitCode: status.map { UInt32(bitPattern: $0) } ?? 255, runtimeMilliseconds: runtime)
        surface = .finished
        state = .ended(exitStatus: status)
    }

    /// Gives the surface keyboard focus (and shows the software keyboard).
    public func focus() {
        viewState?.requestFocus()
    }

    /// The surface state for the current connection, created when first shown. It hands SwiftUI
    /// the same view every time: libghostty frees the grid and scrollback with the view, and they
    /// have to be there when the terminal's screen opens again.
    func surfaceState() -> TerminalViewState? {
        if let viewState { return viewState }
        guard let io else { return nil }
        let appearance = Self.appearance
        let controller = TerminalController(
            configuration: GhosttyConfig.configuration(appearance: appearance, term: Self.term),
            theme: GhosttyConfig.theme(appearance: appearance)
        )
        let viewState = TerminalViewState(controller: controller)
        viewState.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
        let surfaceView = TerminalView(frame: .zero)
        viewState.makePlatformView = { surfaceView }
        self.viewState = viewState
        return viewState
    }

    /// Feeds the channel's output to the surface until the channel ends, off the main actor.
    @concurrent
    nonisolated private static func pump(_ channel: any TerminalChannel, into io: InMemoryTerminalSession) async -> SSHError? {
        for await chunk in channel.incoming {
            io.receive(chunk)
        }
        return await channel.waitForEnd()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> UInt64 {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return UInt64(max(0, seconds)) * 1000 + UInt64(max(0, attoseconds) / 1_000_000_000_000_000)
    }

    private static func sshError(_ error: any Error) -> SSHError {
        switch error {
        case let error as SSHError: error
        case is CancellationError: .connectionClosed
        default: .other(error.localizedDescription)
        }
    }
}

extension PseudoTerminalSize {
    init(_ viewport: InMemoryTerminalViewport) {
        self.init(
            columns: Int(viewport.columns),
            rows: Int(viewport.rows),
            pixelWidth: Int(viewport.widthPixels),
            pixelHeight: Int(viewport.heightPixels)
        )
    }
}
