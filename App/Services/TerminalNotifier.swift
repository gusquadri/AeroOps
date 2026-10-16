import AppKit
import TerminalKit
import UserNotifications

/// Tells the user about alerts from terminal tabs they are not looking at.
///
/// - A program's notification request (OSC 9, OSC 777) and a command that ran for at least
///   ``longCommand`` (where the remote shell marks its commands, OSC 133) post a notification
///   titled with the tab. Clicking it shows the tab.
/// - A bell bounces the Dock icon once while AeroOps is in the background.
///
/// Notification texts come from the remote host: TerminalKit has removed control characters
/// and cut them short, and a tab posts at most one notification per ``interval``. macOS asks
/// for permission the first time one is posted.
@MainActor
final class TerminalNotifier {
    /// Commands that end after at least this long get a notification.
    static let longCommand = Duration.seconds(10)
    /// The shortest time between two notifications of one tab.
    static let interval = Duration.seconds(5)

    /// Shows a tab; set by ``AppModel``.
    var showTab: ((TerminalSession.ID) -> Void)?

    private var lastPosted: [TerminalSession.ID: ContinuousClock.Instant] = [:]
    private var delegate: NotificationDelegate?

    func handle(_ alert: TerminalAlert, from session: TerminalSession, tabTitle: String) {
        guard !session.isInFront else { return }
        switch alert {
        case .bell:
            if !NSApplication.shared.isActive {
                NSApplication.shared.requestUserAttention(.informationalRequest)
            }
        case let .notification(title, body):
            post(for: session.id, title: title.isEmpty ? tabTitle : "\(tabTitle): \(title)", body: body)
        case let .commandFinished(exitCode, duration):
            guard duration >= Self.longCommand else { return }
            post(for: session.id, title: tabTitle, body: Self.commandSummary(exitCode: exitCode, duration: duration))
        }
    }

    /// Drops what is kept for a closed tab.
    func forget(_ id: TerminalSession.ID) {
        lastPosted[id] = nil
    }

    /// "Command finished after 2m 5s" or "Command failed with exit code 2 after 12s".
    static func commandSummary(exitCode: Int?, duration: Duration) -> String {
        let time = duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
        switch exitCode {
        case 0?, nil: return "Command finished after \(time)"
        case let code?: return "Command failed with exit code \(code) after \(time)"
        }
    }

    private func post(for id: TerminalSession.ID, title: String, body: String) {
        let now = ContinuousClock.now
        if let last = lastPosted[id], now - last < Self.interval { return }
        lastPosted[id] = now
        let center = UNUserNotificationCenter.current()
        if delegate == nil {
            let delegate = NotificationDelegate { [weak self] id in self?.showTab?(id) }
            center.delegate = delegate
            self.delegate = delegate
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = id.uuidString
        content.userInfo = [NotificationDelegate.sessionKey: id.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }
}

/// Shows banners while AeroOps is active (the tab may still be hidden) and the tab when its
/// notification is clicked.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let sessionKey = "terminalSession"
    private let show: @MainActor @Sendable (TerminalSession.ID) -> Void

    init(show: @escaping @MainActor @Sendable (TerminalSession.ID) -> Void) {
        self.show = show
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo[Self.sessionKey] as? String,
              let id = UUID(uuidString: text) else { return }
        await show(id)
    }
}
