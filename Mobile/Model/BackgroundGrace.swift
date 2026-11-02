import UIKit

/// The extra running time iOS grants an app that just went to the background, so an open shell's
/// output keeps flowing for a while before the app is suspended. Every task begun here ends, when
/// the time runs out or when the app comes back; iOS kills an app that leaves one running.
@MainActor
final class BackgroundGrace {
    private var task: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Open terminals") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
