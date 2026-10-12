import AeroTheme
import AgentBridge
import AppKit
import SwiftUI

/// The floating approval panel's content: the oldest waiting approval ("1 of 3" when more wait).
/// The panel stays above other apps' windows and does not take focus from them.
struct ApprovalPanelView: View {
    let service: BridgeService
    /// Freezes the countdown (snapshots).
    var fixedNow: Date?
    /// Shows this approval instead of the oldest (snapshots).
    var approvalOverride: PendingApproval?

    static let width: CGFloat = 540

    var body: some View {
        let pending = service.pending
        let approval = approvalOverride ?? pending.first
        VStack(alignment: .leading, spacing: 14) {
            if let approval {
                let index = (pending.firstIndex(where: { $0.id == approval.id }) ?? 0) + 1
                ApprovalRequestView(
                    approval: approval,
                    position: (index, max(pending.count, 1)),
                    fixedNow: fixedNow,
                    requiresTouchID: service.requiresTouchID
                ) { decision in
                    await service.decide(approval.id, decision)
                }
                .id(approval.id)
                Text("An agent asked AeroOps to run this over ssh. Closing this panel does not answer; Activity lists every waiting request.")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("No commands are waiting for approval.", systemImage: "checkmark.circle")
                    .font(Aero.font(.callout, weight: .medium))
                    .foregroundStyle(Aero.text.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(width: Self.width, alignment: .topLeading)
        .background { Aero.sky.gradient.ignoresSafeArea() }
    }
}

/// The floating, non-activating panel that shows ``ApprovalPanelView``. Closing it only hides it.
///
/// The panel is sized by hand from the content's fitting size, never through the hosting
/// controller's `preferredContentSize`: a floating panel that is moved while SwiftUI sizes it
/// that way can loop in AppKit's update-constraints pass and crash.
@MainActor
final class ApprovalPanelController {
    private let service: BridgeService
    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?
    private var fitScheduled = false

    init(service: BridgeService) {
        self.service = service
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the panel above other windows, at the top right of the screen with the mouse,
    /// without taking keyboard focus from the frontmost app.
    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            fit(panel, keepingTop: false)
            place(panel)
        }
        panel.orderFrontRegardless()
        scheduleFit()
    }

    /// Re-fits the panel's height to its content (a different approval is now first).
    func contentDidChange() {
        guard isVisible else { return }
        scheduleFit()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        hosting = nil
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: AnyView(ApprovalPanelView(service: service).aeroAppearance()))
        hosting.sizingOptions = []
        self.hosting = hosting
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: ApprovalPanelView.width, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Agent command approval"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting
        return panel
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
    }

    /// Fits on the next turn of the run loop, outside any layout pass.
    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            if let panel = self.panel, panel.isVisible { self.fit(panel, keepingTop: true) }
        }
    }

    /// Sets the panel's height to the content's (at the fixed width), at most the screen's.
    private func fit(_ panel: NSPanel, keepingTop: Bool) {
        guard let hosting else { return }
        let width = ApprovalPanelView.width
        let fitting = hosting.sizeThatFits(in: NSSize(width: width, height: 10_000))
        let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let content = NSSize(width: width, height: min(max(fitting.height.rounded(.up), 160), available - 40))
        var frame = panel.frame
        // The content view fills the frame (full-size content view); add whatever it does not.
        let chrome = frame.height - (panel.contentView?.frame.height ?? frame.height)
        let size = NSSize(width: content.width, height: content.height + max(chrome, 0))
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        if keepingTop { frame.origin.y += frame.height - size.height }
        frame.size = size
        panel.setFrame(frame, display: true)
    }
}
