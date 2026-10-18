import Foundation

/// Developer-only launch arguments, read from the `UserDefaults` argument domain. Release
/// builds ignore them.
///
/// ```sh
/// xcrun simctl launch booted app.aeroops.AeroOpsMobile \
///   -AeroOpsDemo \               # the six sample hosts and a sample key, all in memory
///   -AeroOpsScreen host          # open on: host (the first host), terminal or files (its terminal,
///                                # its files), add, edit, keys, newKey or key
/// ```
enum MobileDebugOptions {
    enum Screen: String {
        case host, terminal, files, add, edit, keys, newKey, key
    }

    static var isDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-AeroOpsDemo")
    }

    static var screen: Screen? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "AeroOpsScreen").flatMap(Screen.init(rawValue:))
        #else
        nil
        #endif
    }
}
