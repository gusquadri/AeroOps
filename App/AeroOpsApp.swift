import AeroCore
import AeroTheme
import SwiftUI

/// App entry point. Owns the long-lived stores and injects them into the environment.
@main
struct AeroOpsApp: App {
    /// Host inventory persisted in ~/Library/Application Support/AeroOps/hosts.json.
    @State private var hostStore = HostStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hostStore)
                .fontDesign(.rounded)
                .background { SkyBackground() }
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
