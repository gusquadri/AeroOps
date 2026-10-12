import AgentBridge
import AppKit
import os
import UserNotifications

/// Puts waiting approvals in front of the user: the floating panel for every new approval, a
/// notification with Deny / Allow once when AeroOps is not the active app (Dock bounce instead
/// when notifications are not allowed), and the count on the Dock icon.
@MainActor
final class ApprovalPresenter {
    private weak var service: BridgeService?
    private let panel: ApprovalPanelController
    private let notifier: ApprovalNotifier?
    private var shown: Set<UUID> = []

    init(service: BridgeService, notifications: Bool) {
        self.service = service
        panel = ApprovalPanelController(service: service)
        notifier = notifications ? ApprovalNotifier(service: service) : nil
    }

    /// Called with every approval snapshot.
    func update(pending: [PendingApproval]) {
        let ids = Set(pending.map(\.id))
        let new = pending.filter { !shown.contains($0.id) }
        let resolved = shown.subtracting(ids)
        shown = ids
        if !resolved.isEmpty { notifier?.remove(resolved) }
        NSApp.dockTile.badgeLabel = pending.isEmpty ? nil : "\(pending.count)"
        guard !pending.isEmpty else {
            panel.hide()
            return
        }
        guard !new.isEmpty else {
            if !resolved.isEmpty { panel.contentDidChange() }
            return
        }
        panel.show()
        guard !NSApp.isActive else { return }
        guard let notifier else {
            NSApp.requestUserAttention(.criticalRequest)
            return
        }
        for approval in new {
            notifier.post(approval) { posted in
                if !posted { NSApp.requestUserAttention(.criticalRequest) }
            }
        }
    }

    func showPanel() {
        guard let service, !service.pending.isEmpty else { return }
        panel.show()
    }

    func close() {
        panel.close()
        notifier?.remove(shown)
        shown = []
        NSApp.dockTile.badgeLabel = nil
    }
}

/// Approval notifications. Authorization is requested the first time one is needed.
///
/// "Allow once" is only offered when the whole command fits in the notification and has no
/// hidden characters; otherwise the notification offers Deny and opens the panel when clicked.
@MainActor
final class ApprovalNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "app.aeroops.approval"
    nonisolated static let denyOnlyCategory = "app.aeroops.approval.review"
    nonisolated static let denyAction = "deny"
    nonisolated static let allowOnceAction = "allowOnce"
    nonisolated static let approvalKey = "approvalID"
    /// Longest command shown in a notification body.
    static let bodyLimit = 180

    private weak var service: BridgeService?
    private var authorized: Bool?
    private var waiting: [(UNNotificationRequest, (Bool) -> Void)] = []
    private var isRequesting = false

    init(service: BridgeService) {
        self.service = service
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        let allow = UNNotificationAction(identifier: Self.allowOnceAction, title: "Allow once", options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [deny, allow], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.denyOnlyCategory, actions: [deny], intentIdentifiers: []),
        ])
    }

    /// Posts a notification for `approval`; `completion(false)` when notifications are not
    /// allowed or posting failed.
    func post(_ approval: PendingApproval, completion: @escaping (Bool) -> Void) {
        let visible = VisibleText.escape(approval.command)
        let fits = !visible.hadHidden && visible.text.count <= Self.bodyLimit
        let content = UNMutableNotificationContent()
        content.title = "Run a command on \(approval.hostName)?"
        content.subtitle = VisibleText.escape(approval.clientLabel).text
        content.body = fits
            ? visible.text
            : String(visible.text.prefix(Self.bodyLimit)) + "… (full command in AeroOps)"
        content.categoryIdentifier = fits ? Self.category : Self.denyOnlyCategory
        content.userInfo = [Self.approvalKey: approval.id.uuidString]
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: approval.id.uuidString, content: content, trigger: nil)

        switch authorized {
        case true?:
            add(request, completion)
        case false?:
            completion(false)
        case nil:
            waiting.append((request, completion))
            requestAuthorization()
        }
    }

    func remove(_ ids: Set<UUID>) {
        let identifiers = ids.map(\.uuidString)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func requestAuthorization() {
        guard !isRequesting else { return }
        isRequesting = true
        Task { [weak self] in
            let granted: Bool
            do {
                granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.logger.notice("Notifications not authorized: \(error.localizedDescription, privacy: .public)")
                granted = false
            }
            guard let self else { return }
            self.authorized = granted
            self.isRequesting = false
            let waiting = self.waiting
            self.waiting = []
            for (request, completion) in waiting {
                if granted { self.add(request, completion) } else { completion(false) }
            }
        }
    }

    private func add(_ request: UNNotificationRequest, _ completion: @escaping (Bool) -> Void) {
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                completion(true)
            } catch {
                Self.logger.notice("Approval notification failed: \(error.localizedDescription, privacy: .public)")
                completion(false)
            }
        }
    }

    private func handle(action: String, approvalID: UUID?) async {
        guard let service else { return }
        switch action {
        case Self.denyAction:
            if let approvalID { await service.decide(approvalID, .deny) }
        case Self.allowOnceAction:
            if let approvalID { await service.decide(approvalID, .allowOnce) }
        case UNNotificationDefaultActionIdentifier:
            NSApp.activate()
            service.showApprovalPanel()
        default:
            break
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo[Self.approvalKey] as? String).flatMap(UUID.init(uuidString:))
        await handle(action: action, approvalID: id)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated private static let logger = Logger(subsystem: "app.aeroops.AeroOps", category: "approvals")
}
