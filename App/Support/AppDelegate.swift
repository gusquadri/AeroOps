import AppKit
import Synchronization

/// Launch and quit hooks for work SwiftUI's `App` has no place for: starting the SSH services
/// and shutting them down (closing ControlMaster connections, removing the agent socket) before
/// the process exits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Runs once after launch. Set by `AeroOpsApp.init`.
    static var launchHandler: (@MainActor () async -> Void)?
    /// Called on the main actor when the app is about to quit. Does the main-actor part of
    /// shutting down synchronously and returns the rest (closing connections, stopping the agent),
    /// which must not need the main actor; `nil` when there is nothing to do.
    static var shutdownHandler: (@MainActor () -> (@Sendable () async -> Void)?)?
    /// Quitting never waits longer than this for the shutdown work.
    static let shutdownDeadline: Duration = .seconds(6)

    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let launch = Self.launchHandler else { return }
        Task { await launch() }
    }

    /// Replies `.terminateLater` and finishes the shutdown off the main actor.
    ///
    /// `terminate(_:)` may be called from inside a main-queue job (e.g. a `Task` on the main
    /// actor). AppKit then waits for the reply in a nested run loop while that job is still on the
    /// stack, so the main queue, and with it every main-actor task, is stuck until we reply. The
    /// shutdown work therefore runs detached, and the reply is posted as a run-loop block, which
    /// the nested loop does service.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second Quit while shutting down: the first one's reply still ends the app.
        guard !isTerminating else { return .terminateCancel }
        guard let work = Self.shutdownHandler?() else { return .terminateNow }
        isTerminating = true
        let reply = TerminationReply()
        Task.detached {
            await work()
            reply.send()
        }
        Task.detached {
            try? await Task.sleep(for: Self.shutdownDeadline)
            reply.send()
        }
        return .terminateLater
    }
}

/// Sends `reply(toApplicationShouldTerminate: true)` once, from any thread.
private final class TerminationReply: Sendable {
    private let sent = Atomic<Bool>(false)

    func send() {
        guard sent.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
}
