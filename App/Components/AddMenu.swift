import AeroTheme
import SwiftUI

/// The sidebar's "Add" menu: a new host, or hosts imported from another app.
struct AddMenu: View {
    @Environment(AppModel.self) private var model
    @State private var isImporting = false

    var body: some View {
        Menu {
            Button("Add Host…", systemImage: "server.rack") { model.requestNewHost() }
            Button("Import…", systemImage: "square.and.arrow.down") { isImporting = true }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.aqua)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a server to monitor (⌘N) or import hosts")
        .sheet(isPresented: $isImporting) {
            ImportSheet { ids in
                if let first = ids.first { model.selection = first }
            }
        }
    }
}
