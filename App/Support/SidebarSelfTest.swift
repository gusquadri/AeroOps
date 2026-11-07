#if DEBUG
import AeroCore
import AppKit

/// `-AeroSelfTest sidebar`: rearranges hosts, folders and terminal tabs while the sidebar shows
/// them, then checks every row the sidebar draws sits in its place and belongs to it.
///
/// ```sh
/// AeroOps.app/Contents/MacOS/AeroOps -AeroSelfTest sidebar -AeroSelfTestOutput /tmp/aeroops-sidebar.json
/// ```
///
/// Writes a JSON report (`"ok": true` on success) and quits. Its hosts are password hosts on a
/// closed local port, so their terminal tabs open and fail at once.
@MainActor
struct SidebarSelfTest {
    private struct Report: Encodable {
        var ok = true
        var failures: [String] = []
    }

    let model: AppModel

    func runAndQuit() async {
        let report = await run()
        if let url = Phase2SelfTest.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: url, options: .atomic)
        }
        print("[selftest] \(report.ok ? "OK" : "FAILED \(report.failures)")")
        NSApp.terminate(nil)
    }

    private func run() async -> Report {
        let ids = addHosts()
        var failures: [String] = []
        for (name, change) in arrangeSteps(ids) {
            change()
            await settle()
            failures += SidebarRows.problems(after: name)
        }
        for (index, id) in model.hosts.map(\.id).enumerated() {
            model.hostSearch = "host-1"
            await settle()
            model.hostSearch = ""
            await settle()
            model.selection = id
            await settle()
            failures += SidebarRows.problems(after: "search, clear it and select host \(index)")
        }
        return Report(ok: failures.isEmpty, failures: failures)
    }

    private func addHosts() -> [RemoteHost.ID] {
        for index in 0..<10 {
            let host = RemoteHost(
                name: "host-\(index)", address: "127.0.0.1", port: 1, user: "selftest", auth: .password,
                tags: index.isMultiple(of: 3) ? ["TAG"] : [])
            try? model.addHost(host)
        }
        model.selection = nil
        return model.hosts.map(\.id)
    }

    private func arrangeSteps(_ ids: [RemoteHost.ID]) -> [(String, () -> Void)] {
        [
            ("new folder with host-0", { try? model.saveFolder(.new(moving: ids[0]), name: "Test") }),
            ("new empty folder", { try? model.saveFolder(.new(moving: nil), name: "Empty") }),
            ("move host-1 into a folder", { model.moveHost(ids[1], toFolder: model.folders.first?.id) }),
            ("open two terminals on host-0", { model.openSSH(ids[0]); model.openSSH(ids[0]) }),
            ("open a terminal on host-4", { model.openSSH(ids[4]) }),
            ("drop host-6 on host-2", { model.arrange(.host(ids[6]), on: .item(.host(ids[2]))) }),
            ("tag host-2", { retag(ids[2], ["SIMPLIFY"]) }),
            ("untag host-3", { retag(ids[3], []) }),
            ("move host-5 into the empty folder", { model.moveHost(ids[5], toFolder: model.folders.last?.id) }),
            ("move host-5 out", { model.moveHost(ids[5], toFolder: nil) }),
            ("delete host-7", { try? model.deleteHost(id: ids[7]) }),
        ]
    }

    private func retag(_ id: RemoteHost.ID, _ tags: [String]) {
        guard var host = model.host(id: id) else { return }
        host.tags = tags
        try? model.updateHost(host)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(800))
    }
}

@MainActor
private enum SidebarRows {
    static func problems(after step: String) -> [String] {
        guard let outline = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(firstOutline) }).first else {
            return ["\(step): no sidebar"]
        }
        outline.layoutSubtreeIfNeeded()
        let rows = (0..<outline.numberOfRows).compactMap { outline.rowView(atRow: $0, makeIfNecessary: false) }
        let misplaced = rows.indices.filter { rows[$0].frame.integral != outline.rect(ofRow: $0).integral }
        let owned = Set(rows.map(ObjectIdentifier.init))
        let strays = outline.subviews.compactMap { $0 as? NSTableRowView }.filter { row in
            !owned.contains(ObjectIdentifier(row)) && !row.isHidden && row.alphaValue > 0.01 && outline.visibleRect.intersects(row.frame)
        }
        let found = misplaced.map { "row \($0) is drawn away from its place" }
            + strays.map { "a stray row is drawn at y \(Int($0.frame.minY))" }
        print(found.isEmpty ? "[selftest] ✓ \(step)" : "[selftest] ✗ \(step): \(found)")
        return found.map { "\(step): \($0)" }
    }

    private static func firstOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap(firstOutline).first
    }
}
#endif
