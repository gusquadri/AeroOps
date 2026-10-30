import AeroTheme
import SwiftUI

/// The iOS app: the server dashboard and the keys AeroOps signs in with, over AeroKit's
/// in-process SSH client (iOS has no `/usr/bin/ssh`). "Try Sample Servers" on the empty dashboard
/// (and `-AeroOpsDemo`) runs on sample hosts instead, so the app can be tried without a server.
@main
struct AeroOpsMobileApp: App {
    /// The user's servers and keys.
    @State private var live = MobileModel.live()
    /// The sample servers, while they are shown in place of the user's.
    @State private var sample: MobileModel? = MobileDebugOptions.isDemo ? .preview() : nil
    @Environment(\.scenePhase) private var scenePhase

    private var model: MobileModel { sample ?? live }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(model)
                // `-AeroOpsDemo` is for screenshots: no way out, and nothing marks it as samples.
                .environment(\.showSampleServers, MobileDebugOptions.isDemo ? nil : showSampleServers)
                // Navigation and sheets start over in the other model.
                .id(ObjectIdentifier(model))
                .tint(Aero.aqua)
                .task(id: ObjectIdentifier(model)) {
                    await model.start()
                    if model.isPreview, model.keys.isEmpty {
                        try? await model.generateKey(.ed25519, name: "AeroOps iPhone", policy: .oncePerSession)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.setActive(true)
            case .background: model.setActive(false)
            case .inactive: break
            @unknown default: break
            }
        }
    }

    /// Swaps in fresh sample servers, or goes back to the user's. The user's model stays paused
    /// (no polling, no connections) while the samples are shown.
    private func showSampleServers(_ show: Bool) {
        if show {
            live.setActive(false)
            sample = .preview()
        } else {
            sample = nil
            live.setActive(scenePhase == .active)
        }
    }
}

extension EnvironmentValues {
    /// Shows the sample servers (`true`) or the user's (`false`); nil where there is nothing to
    /// switch to (previews, `-AeroOpsDemo`).
    @Entry var showSampleServers: (@MainActor (Bool) -> Void)? = nil
}
