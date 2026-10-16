import Foundation
import Observation
import os
import Sparkle
import SwiftUI

/// Sparkle 2 software updates. Owned by
/// ``AeroOpsApp``; the app menu's Check for Updates…, the sidebar's update button and
/// Settings › Updates read it.
///
/// The updater starts only when the bundle's Info.plist has both `SUFeedURL` and
/// `SUPublicEDKey`. They come from the `AEROOPS_FEED_URL` and `AEROOPS_SPARKLE_PUBLIC_KEY` build
/// settings, which are empty unless `Scripts/release.sh` sets them, so development builds never
/// contact a feed: no updater object exists, the menu item is hidden and the pane says so.
///
/// Automatic checks start on, every hour (`SUEnableAutomaticChecks` and `SUScheduledCheckInterval`
/// in App/Info.plist; setting the key also skips Sparkle's own permission prompt). Sparkle shows its
/// update window when a release appears; installing still takes a click. The user can turn checks
/// off under Settings › Updates, and Sparkle keeps that choice in the app's user defaults.
@MainActor
@Observable
final class UpdateService {
    /// The feed and key a release build was configured with.
    struct Configuration: Equatable, Sendable {
        let feedURL: String
        let publicEDKey: String

        /// `nil` when either value is missing, empty or an unexpanded `$(…)` build setting.
        init?(infoDictionary: [String: Any]) {
            func value(_ key: String) -> String? {
                let text = (infoDictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty || text.contains("$(") ? nil : text
            }
            guard let feedURL = value("SUFeedURL"), let publicEDKey = value("SUPublicEDKey") else { return nil }
            self.feedURL = feedURL
            self.publicEDKey = publicEDKey
        }
    }

    enum Status: Equatable {
        /// This build has no feed URL or no public key, so the updater never starts.
        case notConfigured
        /// Configured, but ``start()`` has not run yet.
        case idle
        /// Sparkle refused to start (a misconfigured release build); the message says why.
        case failed(String)
        /// The updater runs: manual checks work, automatic ones unless the user turned them off.
        case running
    }

    let configuration: Configuration?
    private(set) var status: Status
    /// `SPUUpdater.canCheckForUpdates`: `false` before the start and while a check is shown.
    private(set) var canCheckForUpdates = false
    /// `SPUUpdater.automaticallyChecksForUpdates` (on unless the user turned it off).
    private(set) var automaticallyChecks = false
    /// `SPUUpdater.automaticallyDownloadsUpdates`.
    private(set) var automaticallyDownloads = false
    /// `SPUUpdater.allowsAutomaticUpdates`: whether automatic downloads may be turned on at all.
    private(set) var allowsAutomaticDownloads = false
    /// `SPUUpdater.lastUpdateCheckDate`.
    private(set) var lastCheckDate: Date?
    /// The version a check found, until the user skips it or a later check finds nothing newer.
    /// The sidebar's update button shows a dot for it.
    private(set) var availableVersion: String?
    /// A check started with ``checkForUpdates()`` is running. Background checks do not set it.
    private(set) var isChecking = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// Sparkle holds its delegate weakly.
    @ObservationIgnored private var delegate: UpdaterDelegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let logger = Logger(subsystem: "app.aeroops", category: "updates")

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        configuration = Configuration(infoDictionary: infoDictionary)
        status = configuration == nil ? .notConfigured : .idle
    }

    /// Whether the app menu offers Check for Updates….
    var isAvailable: Bool { status == .running }

    /// Starts Sparkle when this build is configured; otherwise does nothing.
    func start() {
        guard status == .idle, let configuration else { return }
        let delegate = UpdaterDelegate(service: self)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            status = .failed(error.localizedDescription)
            logger.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.controller = controller
        self.delegate = delegate
        status = .running
        logger.info("Sparkle started with feed \(configuration.feedURL, privacy: .public)")
        observe(controller.updater)
    }

    /// Check for Updates…: Sparkle's own window shows progress and the result. During a session
    /// (an update already on screen) it only brings Sparkle's window forward.
    func checkForUpdates() {
        guard let controller, canCheckForUpdates else { return }
        if !controller.updater.sessionInProgress {
            isChecking = true
        }
        controller.updater.checkForUpdates()
    }

    func setAutomaticallyChecks(_ isOn: Bool) {
        controller?.updater.automaticallyChecksForUpdates = isOn
        refresh()
    }

    func setAutomaticallyDownloads(_ isOn: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = isOn
        refresh()
    }

    /// Mirrors the updater's KVO-compliant properties, so SwiftUI sees their changes.
    private func observe(_ updater: SPUUpdater) {
        let onChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        observations = [
            updater.observe(\.canCheckForUpdates) { _, _ in onChange() },
            updater.observe(\.automaticallyChecksForUpdates) { _, _ in onChange() },
            updater.observe(\.automaticallyDownloadsUpdates) { _, _ in onChange() },
            updater.observe(\.allowsAutomaticUpdates) { _, _ in onChange() },
            updater.observe(\.lastUpdateCheckDate) { _, _ in onChange() },
        ]
        refresh()
    }

    fileprivate func didFindUpdate(version: String?) {
        availableVersion = version
        isChecking = false
    }

    fileprivate func didSkipUpdate() {
        availableVersion = nil
    }

    fileprivate func didFinishUpdateCycle() {
        isChecking = false
    }

    private func refresh() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        allowsAutomaticDownloads = updater.allowsAutomaticUpdates
        lastCheckDate = updater.lastUpdateCheckDate
    }
}

/// Tells ``UpdateService`` what Sparkle's checks found.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var service: UpdateService?

    init(service: UpdateService) {
        self.service = service
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        service?.didFindUpdate(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        service?.didFindUpdate(version: nil)
    }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if choice == .skip {
            service?.didSkipUpdate()
        }
    }

    /// Also ends checks that failed, which report neither of the above.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        service?.didFinishUpdateCycle()
    }
}

extension EnvironmentValues {
    /// The app's updater; `nil` in previews and standalone windows, which then show the
    /// not-configured state.
    @Entry var updateService: UpdateService? = nil
}

/// App menu › Check for Updates…, after About. Only release builds with an update feed have it.
struct UpdateCommands: Commands {
    let updates: UpdateService

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updates.isAvailable {
                CheckForUpdatesButton(updates: updates)
            }
        }
    }
}

/// A view, not inline in the command group, so the menu item tracks ``UpdateService`` changes.
private struct CheckForUpdatesButton: View {
    let updates: UpdateService

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}
