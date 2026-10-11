import AeroCore
import AeroTheme
import SwiftUI

/// App entry point. Owns the ``AppModel`` and injects it into the main window and Settings.
///
/// The main window is a single `Window` (not a `WindowGroup`): tab and host selection live in
/// the shared ``AppModel``, so a second window would mirror the first.
@main
struct AeroOpsApp: App {
    static let mainWindowID = "main"

    @State private var model: AppModel

    init() {
        #if DEBUG
        let directory = DebugLaunchOptions.dataDirectory ?? AeroPaths.standard.applicationSupport
        #else
        let directory = AeroPaths.standard.applicationSupport
        #endif
        // Host inventory persisted in ~/Library/Application Support/AeroOps/hosts.json.
        let model = AppModel(hostStore: HostStore(directory: directory))
        #if DEBUG
        DebugLaunchOptions.apply(to: model)
        #endif
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("AeroOps", id: Self.mainWindowID) {
            RootView()
                .aeroAppearance()
                .frame(minWidth: 900, minHeight: 600)
            #if DEBUG
                .debugSnapshotHarness()
            #endif
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .aeroAppearance()
        }
    }
}

extension View {
    /// App-wide look: SF Pro Rounded, aqua accents, and the light scheme the Aero palette is
    /// designed for (the dark "Aero Night" variant comes later).
    func aeroAppearance() -> some View {
        self
            .fontDesign(.rounded)
            .tint(Aero.aqua)
            .preferredColorScheme(.light)
    }
}
