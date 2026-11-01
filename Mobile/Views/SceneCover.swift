import AeroTheme
import SwiftUI
import UIKit

/// Shows the lock screen in a window of its own above the scene's, because sheets, alerts and
/// system pickers are presented above any SwiftUI overlay. The app below stays mounted, so a
/// re-lock keeps navigation and form drafts.
struct SceneCover: UIViewRepresentable {
    /// Whether the cover stays up while the scene is active: while locked, and until the app below exists.
    let isCovering: Bool
    let screen: LockScreen

    func makeUIView(context: Context) -> SceneCoverAnchor {
        SceneCoverAnchor(screen: screen)
    }

    func updateUIView(_ anchor: SceneCoverAnchor, context: Context) {
        anchor.update(isCovering: isCovering, screen: screen)
    }
}

/// Finds the scene, owns its cover window, and follows that scene's activation. The scene's own
/// notifications matter here: they arrive before the snapshot, and SwiftUI's `scenePhase` gives no
/// such promise. With several iPad windows, each window has its own cover.
final class SceneCoverAnchor: UIView {
    private let host: UIHostingController<LockScreen>
    private var cover: UIWindow?
    private var isCovering = true

    init(screen: LockScreen) {
        host = UIHostingController(rootView: screen)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(isCovering: Bool, screen: LockScreen) {
        self.isCovering = isCovering
        host.rootView = screen
        cover?.isHidden = !isCovering && window?.windowScene?.activationState == .foregroundActive
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard cover == nil, let scene = window?.windowScene else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.backgroundColor = UIColor(Aero.sky.bottom)
        cover.rootViewController = host
        cover.accessibilityViewIsModal = true
        cover.isHidden = false
        self.cover = cover
        follow(scene)
    }

    private func follow(_ scene: UIWindowScene) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(showCover), name: UIScene.willDeactivateNotification, object: scene)
        center.addObserver(self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: scene)
        center.addObserver(self, selector: #selector(sceneDidEnterBackground), name: UIScene.didEnterBackgroundNotification, object: scene)
    }

    @objc private func showCover() {
        cover?.isHidden = false
    }

    @objc private func sceneDidActivate() {
        cover?.isHidden = !isCovering
    }

    /// Drops the keyboard too, so it cannot come back typing into a form behind the lock.
    @objc private func sceneDidEnterBackground() {
        showCover()
        window?.endEditing(true)
    }
}
