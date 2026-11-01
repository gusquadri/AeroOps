import AeroTheme
import SwiftUI

/// What stands in front of the app while it is locked. With `isLocked` false it is only the sky,
/// hiding the app from the app switcher while a system prompt or sheet is up.
struct LockScreen: View {
    let isLocked: Bool
    let unlockMethod: String
    let needsPasscode: Bool
    let onUnlock: @MainActor () -> Void
    /// Set when the lock screen offers the sample servers.
    let onTrySamples: (@MainActor () -> Void)?

    var body: some View {
        ZStack {
            SkyBackground()
            if isLocked {
                AeroEmptyState(systemImage: "lock.fill", title: "AeroOps Is Locked", message: message) {
                    Button(unlockTitle, systemImage: "lock.open") { onUnlock() }
                        .buttonStyle(.aqua)
                    if let onTrySamples {
                        Button("Try Sample Servers", systemImage: "sparkles") { onTrySamples() }
                            .buttonStyle(.aquaSecondary)
                    }
                }
            }
        }
        .tint(Aero.aqua)
    }

    private var message: String {
        needsPasscode
            ? "Set a passcode in Settings to use your servers and SSH keys. AeroOps stays locked on a device without one."
            : "Unlock to see your servers and SSH keys."
    }

    private var unlockTitle: String {
        needsPasscode ? "Try Again" : "Unlock with \(unlockMethod)"
    }
}

#Preview("Locked") {
    LockScreen(isLocked: true, unlockMethod: "Face ID", needsPasscode: false, onUnlock: {}, onTrySamples: nil)
}

#Preview("No passcode") {
    LockScreen(isLocked: true, unlockMethod: "Passcode", needsPasscode: true, onUnlock: {}, onTrySamples: {})
}
