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
/// ends it. Each ``connect()`` opens a new channel and a new surface; nothing survives a
/// dropped connection (iOS closes every socket in the background), so the screen offers
/// ``reconnect()``.
@MainActor
@Observable
public final class EmbeddedTerminalSession {
    public enum State: Sendable, Hashable {
        case connecting
        case running
        /// The shell ended; `exitStatus` is `nil` when it reported none.
        case ended(exitStatus: Int32?)
        /// The connection closed under the shell (the app went to the background, the network
        /// dropped, the server restarted).
        case disconnected
        /// The terminal could not be opened (unknown or changed host key, failed login, timeout).
        case failed(SSHError)

        public var isOver: Bool {
            switch self {
            case .connecting, .running: false
            case .ended, .disconnected, .failed: true
            }
        }
    }

    /// Opens the channel with the terminal's size, e.g. with
    /// ``EmbeddedSSHClient/openTerminal(on:term:size:command:timeout:)`` and ``term``.
    public typealias Opener = @Sendable (PseudoTerminalSize) async throws -> any TerminalChannel

    /// `TERM` for the remote shell: every host has its terminfo.
    public static let term = GhosttyConfig.defaultTerm
    /// The size a channel opens with before the surface reported its own.
    public static let initialSize = PseudoTerminalSize(columns: 80, rows: 24)
    /// The Mac's palette, with a font every iOS device has, small enough for about 50 columns
    /// on an iPhone held upright.
    static let appearance: TerminalAppearance = {
        var appearance = TerminalAppearance.aero
        appearance.fontFamily = "Menlo"
        appearance.fontSize = 10
        return appearance
    }()

    public private(set) var state: State = .connecting
    /// Bumped by every connect: the view builds a new surface for each one.
    public private(set) var connection = 0

    @ObservationIgnored private let open: Opener
    @ObservationIgnored private(set) var link: TerminalLink?
    @ObservationIgnored private(set) var io: InMemoryTerminalSession?
    @ObservationIgnored private var viewState: TerminalViewState?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by connect and close, so a finishing connection that was replaced is dropped.
    @ObservationIgnored private var generation = 0

    public init(open: @escaping Opener) {
        self.open = open
    }

    /// Opens a new channel and surface. Does nothing while one is opening or running.
    public func connect() {
        guard task == nil else { return }
        generation += 1
        connection += 1
        let token = generation
        let size = link?.size ?? Self.initialSize
        let link = TerminalLink(size: size)
        let io = InMemoryTerminalSession(
            write: { data in link.write(data) },
            resize: { viewport in link.resize(PseudoTerminalSize(viewport)) }
        )
        self.link = link
        self.io = io
        viewState = nil
        state = .connecting
        task = Task { [open] in
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
            link.attach(channel, openedWith: size)
            state = .running
            let error = await Self.pump(channel, into: io)
            let status = channel.exitStatus
            // 255 like ssh when the connection, not the shell, ended.
            io.finish(exitCode: status.map { UInt32(bitPattern: $0) } ?? 255, runtimeMilliseconds: Self.milliseconds(since: started))
            guard token == generation else { return }
            state = error == nil ? .ended(exitStatus: status) : .disconnected
            task = nil
        }
    }

    /// Ends the current channel, if any, and opens a new one.
    public func reconnect() {
        close()
        connect()
    }

    /// Ends the channel; the surface keeps its last screen until the next connect.
    public func close() {
        generation += 1
        link?.close()
        task?.cancel()
        task = nil
        if !state.isOver { state = .disconnected }
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
