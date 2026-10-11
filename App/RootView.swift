import AeroCore
import AeroTheme
import SwiftUI

/// Placeholder root view. Replaced by the app shell (sidebar, tabs, Settings) in Phase 1.
struct RootView: View {
    @Environment(HostStore.self) private var hostStore

    var body: some View {
        AeroCard {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    StatusOrb(tone: hostStore.loadError == nil ? .healthy : .warning)
                    Text("AeroOps")
                        .font(Aero.font(.largeTitle, weight: .bold))
                }
                Text("\(hostStore.hosts.count) hosts")
                    .font(Aero.font(.headline))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RootView()
        .environment(HostStore(directory: URL.temporaryDirectory.appending(path: "AeroOpsPreview")))
        .background { SkyBackground() }
}
