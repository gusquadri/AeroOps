import AeroTheme
import KeyAgent
import SwiftUI

/// The iOS app: the server dashboard and the keys AeroOps signs in with, over AeroKit's
/// in-process SSH client (iOS has no `/usr/bin/ssh`). It opens locked: nothing reads the Keychain,
/// polls or connects until the device owner authenticates. "Try Sample Servers" on the empty
/// dashboard, or on the lock screen of a device with no passcode (and `-AeroOpsDemo`), runs on
/// sample hosts instead, so the app can be tried without a server.
@main
struct AeroOpsMobileApp: App {
    /// The user's servers and keys. The first unlock builds it, so before that it holds nothing.
    @State private var live: MobileModel?
    /// The sample servers, while they are shown in place of the user's.
    @State private var sample: MobileModel? = MobileDebugOptions.isDemo ? .preview() : nil
    @State private var lock = AppLockController()
    @State private var grace = BackgroundGrace()
    @Environment(\.scenePhase) private var scenePhase

    private var model: MobileModel? { sample ?? live }

    var body: some Scene {
        WindowGroup {
            ZStack {
                cover
                if let model {
                    root(for: model)
                }
            }
            .onChange(of: lock.state.isUnlocked) {
                if scenePhase == .active { resume() }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            sceneChanged(to: phase)
        }
    }

    private var cover: some View {
        let isLocked = lock.state.covers(showingSamples: sample != nil)
        return SceneCover(
            isCovering: isLocked || model == nil,
            screen: LockScreen(
                isLocked: isLocked,
                unlockMethod: lock.unlockMethod,
                needsPasscode: lock.state.needsPasscode,
                onUnlock: { lock.unlock() },
                onTrySamples: trySamplesOnLockScreen
            )
        )
    }

    private var trySamplesOnLockScreen: (@MainActor () -> Void)? {
        guard lock.state.offersSampleServers else { return nil }
        return { showSampleServers(true) }
    }

    /// The app for this model. `-AeroOpsDemo` is for screenshots: no way out, and nothing marks it
    /// as samples. Navigation and sheets start over in the other model.
    private func root(for model: MobileModel) -> some View {
        MobileRootView()
            .environment(model)
            .environment(\.showSampleServers, MobileDebugOptions.isDemo ? nil : showSampleServers)
            .id(ObjectIdentifier(model))
            .tint(Aero.aqua)
            .task(id: ObjectIdentifier(model)) {
                await model.start()
                if model.isPreview, model.keys.isEmpty {
                    try? await model.generateKey(.ed25519, name: "AeroOps iPhone", policy: .oncePerSession)
                }
            }
    }

    /// `inactive` changes nothing but the cover: prompts, sheets and Control Center must not lock
    /// the app or close its sessions. In the background the open shells keep running for the
    /// grace period iOS grants; the lock covers them meanwhile.
    private func sceneChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            grace.end()
            resume()
        case .inactive:
            lock.sceneChanged(to: .inactive)
        case .background:
            grace.begin()
            lock.sceneChanged(to: .background)
            model?.setActive(false)
        @unknown default:
            break
        }
    }

    /// Runs whatever the lock allows while the scene is active. The samples need no unlock; the
    /// user's model is only built or woken after one, and waits for the scene to come back from
    /// the prompt so its own Face ID prompts never race it.
    private func resume() {
        if let sample {
            sample.setActive(true)
            return
        }
        lock.sceneChanged(to: .active)
        guard lock.state.isUnlocked else { return }
        let live = live ?? MobileModel.live()
        self.live = live
        live.setActive(true)
    }

    /// Swaps in fresh sample servers, or goes back to the user's, through the lock when it is
    /// locked. The user's model stays paused (no polling, only its sessions' connections) while the
    /// samples are shown.
    private func showSampleServers(_ show: Bool) {
        if show {
            live?.setActive(false)
            sample = .preview()
        } else {
            sample = nil
            if scenePhase == .active { resume() }
        }
    }
}

extension EnvironmentValues {
    /// Shows the sample servers (`true`) or the user's (`false`); nil where there is nothing to
    /// switch to (previews, `-AeroOpsDemo`).
    @Entry var showSampleServers: (@MainActor (Bool) -> Void)? = nil
}
