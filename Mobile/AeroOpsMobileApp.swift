import AeroTheme
import SwiftUI

/// The iOS app: the server dashboard and the keys AeroOps signs in with, over AeroKit's
/// in-process SSH client (iOS has no `/usr/bin/ssh`). `-AeroOpsDemo` runs on sample hosts.
@main
struct AeroOpsMobileApp: App {
    @State private var model = MobileDebugOptions.isDemo ? MobileModel.preview() : .live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(model)
                .tint(Aero.aqua)
                .task {
                    await model.start()
                    if MobileDebugOptions.isDemo, model.keys.isEmpty {
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
}
