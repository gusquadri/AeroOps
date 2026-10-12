import Foundation
import Observation

/// Whether the first-run onboarding sheet is up, and whether it ever shows again.
///
/// Onboarding appears on a launch where the app has no hosts and no keys (both loaded without
/// error), until the user finishes or skips it once. A launch that finds hosts or keys marks it
/// done as well, so an existing user who later deletes everything isn't greeted again. The flag
/// is one non-secret `UserDefaults` boolean, ``completedDefaultsKey``.
@MainActor
@Observable
final class OnboardingState {
    /// `true` once onboarding was finished, skipped or found unnecessary.
    static let completedDefaultsKey = "OnboardingCompleted"

    /// Whether the onboarding sheet is showing.
    var isPresented = false

    /// Never presents on its own (DEBUG self-tests and snapshot runs). ``present()`` still works.
    @ObservationIgnored var suppressesAutomaticPresentation = false

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var completedInMemory = false

    /// - Parameter defaults: Where the flag is stored; `nil` keeps it in memory (previews, DEBUG
    ///   data-directory runs).
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    /// Onboarding was finished, skipped or found unnecessary.
    var isCompleted: Bool {
        defaults?.bool(forKey: Self.completedDefaultsKey) ?? completedInMemory
    }

    /// Presents onboarding on a first run. Call once hosts and keys have loaded.
    ///
    /// - Parameter inventoryLoaded: `false` when hosts or keys failed to load, so an empty list
    ///   may not mean a first run: then nothing happens.
    func presentIfNeeded(hasHosts: Bool, hasKeys: Bool, inventoryLoaded: Bool) {
        guard !isCompleted, !suppressesAutomaticPresentation, inventoryLoaded else { return }
        if hasHosts || hasKeys {
            markCompleted()
        } else {
            isPresented = true
        }
    }

    /// Presents onboarding regardless of the flag (DEBUG `-AeroOpsOnboarding YES`).
    func present() {
        isPresented = true
    }

    /// Finished or skipped: dismisses the sheet and never presents it automatically again.
    func complete() {
        markCompleted()
        isPresented = false
    }

    private func markCompleted() {
        completedInMemory = true
        defaults?.set(true, forKey: Self.completedDefaultsKey)
    }
}

extension AppModel {
    /// Presents onboarding if this is a first run. Called after ``startServices()``, which loads
    /// the keys.
    func presentOnboardingIfNeeded() {
        onboarding.presentIfNeeded(
            hasHosts: !hosts.isEmpty,
            hasKeys: !ssh.keys.isEmpty,
            inventoryLoaded: hostStore.loadError == nil && ssh.keyStoreError == nil
        )
    }
}
