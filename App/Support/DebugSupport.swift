#if DEBUG
import AeroCore
import AppKit
import ImageIO
import KeyAgent
@preconcurrency import ScreenCaptureKit
import SSHKit
import SwiftUI
import UniformTypeIdentifiers

/// Developer-only launch arguments, read from the `UserDefaults` argument domain. Compiled out
/// of Release builds.
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps \
///   -AeroOpsDataDirectory /tmp/aeroops-demo \   # hosts.json, keys.json and the ~/.aeroops files
///                                                # (in <dir>/dot) live here; keys stay in memory
///   -AeroOpsDemoHosts YES \                      # an empty data directory gets the six sample hosts
///   -AeroOpsDemoStatuses YES \                   # give hosts every HostStatus so all orb tones show
///   -AeroOpsDemoKeys YES \                       # sample keys, and a changed host key on the third host
///   -AeroOpsSnapshotDirectory build/snapshots \  # write PNGs of every tab, the editor and Settings, then quit
///   -AeroOpsSnapshotPrefix many                  # file name prefix for the PNGs (default "main")
///
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest phase2 -AeroSelfTestOutput /tmp/st.json \
///   -AeroSelfTestAuthorizeScript dev/add-key.sh  # see Phase2SelfTest
/// ```
enum DebugLaunchOptions {
    private static var defaults: UserDefaults { .standard }

    static var dataDirectory: URL? {
        defaults.string(forKey: "AeroOpsDataDirectory").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static var demoStatuses: Bool { defaults.bool(forKey: "AeroOpsDemoStatuses") }

    static var demoKeys: Bool { defaults.bool(forKey: "AeroOpsDemoKeys") }

    static var demoHosts: Bool { defaults.bool(forKey: "AeroOpsDemoHosts") }

    static var snapshotDirectory: URL? {
        defaults.string(forKey: "AeroOpsSnapshotDirectory").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static var snapshotPrefix: String { defaults.string(forKey: "AeroOpsSnapshotPrefix") ?? "main" }

    /// A model for a debug launch, or `nil` for the real one.
    ///
    /// - `-AeroSelfTest`: a fresh temporary root (see ``Phase2SelfTest``).
    /// - `-AeroOpsDataDirectory`: everything under that directory, keys in memory, so demo and
    ///   snapshot runs never touch `~/.aeroops`, the real hosts or the Keychain.
    @MainActor
    static func makeModel() -> AppModel? {
        if Phase2SelfTest.isRequested || Phase5SelfTest.isRequested {
            return Phase2SelfTest.makeModel()
        }
        guard let dataDirectory else { return nil }
        let paths = AeroPaths(
            dotDirectory: dataDirectory.appending(path: "dot", directoryHint: .isDirectory),
            applicationSupport: dataDirectory
        )
        let ssh = SSHServices(paths: paths, secretStore: InMemorySecretStore(), defaults: nil)
        return AppModel(hostStore: HostStore(directory: dataDirectory), ssh: ssh)
    }

    @MainActor
    static func apply(to model: AppModel) {
        if demoHosts, dataDirectory != nil, model.hosts.isEmpty {
            for host in SampleData.hosts {
                try? model.addHost(host)
            }
            model.selection = nil
        }
        if demoStatuses {
            model.applySampleStatuses()
        }
    }

    /// Runs after ``AppModel/startServices()``: demo keys and the self-test.
    @MainActor
    static func servicesDidStart(_ model: AppModel) async {
        if demoKeys, dataDirectory != nil {
            await model.ssh.loadSampleData(blocking: model.hosts.dropFirst(2).first)
            // Give hosts without a key one of the sample keys, so the editor and Keys pane show usage.
            let keys = model.ssh.keys
            for (index, host) in model.hosts.enumerated() where host.keyId == nil && !keys.isEmpty {
                var host = host
                host.keyId = keys[index % keys.count].id.uuidString
                try? model.updateHost(host)
            }
        }
        if Phase2SelfTest.isRequested {
            await Phase2SelfTest(model: model).runAndQuit()
        } else if Phase5SelfTest.isRequested {
            await Phase5SelfTest(model: model).runAndQuit()
        }
    }
}

extension View {
    /// With `-AeroOpsSnapshotDirectory`, captures every main-window tab, the host editor sheet
    /// and every Settings pane to PNGs, then quits. Otherwise does nothing.
    func debugSnapshotHarness() -> some View {
        modifier(DebugSnapshotHarness())
    }
}

private struct DebugSnapshotHarness: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            guard let directory = DebugLaunchOptions.snapshotDirectory else { return }
            await DebugSnapshotter(model: model, directory: directory, prefix: DebugLaunchOptions.snapshotPrefix)
                .run(openSettings: { openSettings() })
        }
    }
}

/// Captures the app's own windows with ScreenCaptureKit's current-process content, which needs
/// no Screen Recording permission.
@MainActor
private struct DebugSnapshotter {
    let model: AppModel
    let directory: URL
    let prefix: String

    func run(openSettings: () -> Void) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await pause(1.5)
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !$0.isSheet }) else {
            log("no main window")
            return NSApp.terminate(nil)
        }
        if model.selection == nil, model.hosts.count > 1 {
            model.selection = model.hosts[min(2, model.hosts.count - 1)].id
        }
        NSApp.activate()
        main.makeKeyAndOrderFront(nil)
        for tab in AppTab.allCases {
            model.selectedTab = tab
            await pause(0.8)
            await capture(main, name: "\(prefix)-\(tab.rawValue)")
        }
        model.selectedTab = .dashboard
        await pause(0.8)
        await capture(main, name: "\(prefix)-dashboard-again")

        model.editorRequest = model.hosts.dropFirst(2).first.map { .edit($0.id) } ?? .new
        await pause(1.2)
        if let sheet = main.attachedSheet {
            await capture(sheet, name: "\(prefix)-editor-sheet")
        }
        model.editorRequest = nil
        await pause(0.8)

        await captureTrustSheet()

        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        openSettings()
        await pause(1.2)
        let settings = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
        if let settings {
            for pane in SettingsPane.allCases {
                model.settingsPane = pane
                await pause(0.8)
                await capture(settings, name: "\(prefix)-settings-\(pane.rawValue)")
            }
        } else {
            log("no settings window")
        }
        NSApp.terminate(nil)
    }

    /// The first-contact sheet, hosted in a temporary window (it normally appears over the host
    /// editor after a Test connection, which a snapshot run can't trigger).
    private func captureTrustSheet() async {
        guard let host = model.hosts.first else { return }
        let sheet = HostKeyTrustSheet(
            host: host,
            offered: [SampleHostKeys.ed25519(seed: 4), SampleHostKeys.ecdsa(seed: 5)],
            onTrust: {},
            onCancel: {}
        )
        await captureStandalone(sheet, title: "Trust host key", name: "\(prefix)-trust-sheet")
        // The editor of a blocked host, full size (sheets capture small and dimmed).
        if let blocked = model.hosts.first(where: { model.hostKeyBlock(for: $0.id) != nil }) {
            await captureStandalone(HostEditorSheet(request: .edit(blocked.id)), title: "Edit \(blocked.name)", name: "\(prefix)-editor-blocked")
        }
        // Settings › Keys tall enough to show the agent section without scrolling.
        await captureStandalone(KeysSettingsPane().frame(width: 780, height: 940), title: "Keys", name: "\(prefix)-keys-full")
    }

    /// Shows `view` in a temporary window, captures it and closes the window.
    private func captureStandalone(_ view: some View, title: String, name: String) async {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.aeroAppearance().environment(model)))
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        await pause(1.0)
        await capture(window, name: name)
        window.close()
        await pause(0.4)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Describes the sidebar and flags a split view taller than the window. (Wrapped text in a
    /// non-scrolling detail once raised the minimum height and pushed the sidebar out of view.)
    private func describeSplit(in window: NSWindow) -> String? {
        func find(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let root = window.contentView?.superview ?? window.contentView, let split = find(root),
              let sidebar = split.arrangedSubviews.first else { return nil }
        let overflow = split.frame.height > root.frame.height + 1 ? " OVERFLOW" : ""
        return "sidebar collapsed=\(split.isSubviewCollapsed(sidebar)) width=\(Int(sidebar.frame.width)) "
            + "split height=\(Int(split.frame.height)) window height=\(Int(root.frame.height))\(overflow)"
    }

    private func capture(_ window: NSWindow, name: String) async {
        if let layout = describeSplit(in: window) { log("\(name): \(layout)") }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                return log("window \(window.windowNumber) not shareable for \(name)")
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            write(image, name: name)
        } catch {
            // Sheets can't always be captured as independent windows; draw the view tree instead
            // (no glass or materials, but controls and layout are faithful).
            log("capture \(name) failed (\(error.localizedDescription)); drawing the view instead")
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let image = rep.cgImage {
                write(image, name: name)
            }
        }
    }

    private func write(_ image: CGImage, name: String) {
        let url = directory.appending(path: "\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return log("cannot create \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            log("wrote \(url.path)")
        }
    }

    private func log(_ message: String) {
        print("[snapshot] \(message)")
    }
}
#endif
