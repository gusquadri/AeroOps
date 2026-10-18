import SwiftUI

/// Servers and Keys tabs.
struct MobileRootView: View {
    enum Section: Hashable {
        case servers, keys
    }

    @State private var section: Section = Self.initialSection

    private static var initialSection: Section {
        switch MobileDebugOptions.screen {
        case .keys, .newKey, .key: .keys
        default: .servers
        }
    }

    var body: some View {
        TabView(selection: $section) {
            Tab("Servers", systemImage: "server.rack", value: .servers) {
                DashboardScreen()
            }
            Tab("Keys", systemImage: "key.horizontal", value: .keys) {
                KeysScreen()
            }
        }
    }
}

#Preview {
    MobileRootView()
        .environment(MobileModel.preview())
}
