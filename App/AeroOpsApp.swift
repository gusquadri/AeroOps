import AeroCore
import AeroTheme
import KeyAgent
import SwiftUI

/// App entry point. Owns the ``AppModel`` and injects it into the main window and Settings.
///
/// The main window is a single `Window` (not a `WindowGroup`): tab and host selection live in
/// the shared ``AppModel``, so a second window would mirror the first.
@main
struct AeroOpsApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    /// Sparkle; does nothing in builds without an update feed (every development build).
    @State private var updates: UpdateService

    init() {
        let updates = UpdateService()
        updates.start()
        _updates = State(initialValue: updates)
        #if DEBUG
        let model = DebugLaunchOptions.makeModel() ?? Self.makeModel()
        DebugLaunchOptions.apply(to: model)
        #else
        let model = Self.makeModel()
        #endif
        _model = State(initialValue: model)
        AppDelegate.launchHandler = {
            await model.startServices()
            model.presentOnboardingIfNeeded()
            #if DEBUG
            await DebugLaunchOptions.servicesDidStart(model)
            #endif
        }
        AppDelegate.shutdownHandler = { model.beginShutdown() }
    }

    /// The real app: hosts in `~/Library/Application Support/AeroOps/hosts.json`, keys in the
    /// login Keychain, runtime files in `~/.aeroops/`.
    @MainActor
    static func makeModel() -> AppModel {
        let paths = AeroPaths.standard
        let ssh = SSHServices(
            paths: paths, secretStore: KeychainSecretStore(), passwordStore: HostPasswordVault.keychainStore(), defaults: .standard
        )
        let model = AppModel(hostStore: HostStore(directory: paths.applicationSupport), ssh: ssh)
        model.onboarding = OnboardingState(defaults: .standard)
        return model
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
        .commands {
            AppCommands(model: model)
            UpdateCommands(updates: updates)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.updateService, updates)
                .aeroAppearance()
        }
    }
}

extension View {
    /// App-wide look: SF Pro Rounded and aqua accents. The colour scheme follows macOS:
    /// Frutiger Aero in light mode, Nightly Frutiger Aero in dark mode.
    func aeroAppearance() -> some View {
        self
            .fontDesign(.rounded)
            .tint(Aero.aqua)
    }
}
