import KeyAgent
import LocalAuthentication
import Observation

/// Runs the prompts `AppLock` asks for. The unlocked state lives here, in memory, and nowhere else.
@MainActor @Observable
final class AppLockController {
    private(set) var state = AppLock()
    @ObservationIgnored private var evaluation: Task<Void, Never>?

    func sceneChanged(to phase: AppLock.ScenePhase) {
        if phase == .background {
            evaluation?.cancel()
        }
        run(state.sceneChanged(to: phase))
    }

    func unlock() {
        run(state.requestUnlock())
    }

    /// Names only what the next prompt will offer: `.deviceOwnerAuthentication` asks for the
    /// passcode when biometry is missing or locked out. Read fresh each time, because
    /// `canEvaluatePolicy`'s answer must not be stored.
    var unlockMethod: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return "Passcode"
        }
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    private func run(_ attempt: AppLock.Attempt?) {
        guard let attempt else { return }
        evaluation = Task {
            let outcome = await LocalAuthenticationVerifier().authenticate(reason: "Unlock your servers and SSH keys")
            state.finish(attempt, with: outcome)
        }
    }
}
