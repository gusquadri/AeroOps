#if DEBUG
import Foundation

@MainActor
struct Phase7SelfTest {
    static var isRequested: Bool { UserDefaults.standard.string(forKey: "AeroSelfTest") == "phase7" }
    let model: AppModel
    func runAndQuit() async {}
}
#endif
