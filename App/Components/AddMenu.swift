import AeroTheme
import SwiftUI

/// The sidebar's "Add" button. It opens a glass popover with three large rows, each with its own
/// aqua gel icon: a new host, a new folder, or hosts imported from another app.
struct AddMenu: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingChoices = false
    @State private var isImporting = false

    var body: some View {
        Button("Add", systemImage: "plus") { isShowingChoices.toggle() }
            .buttonStyle(.aqua)
            .fixedSize()
            .help("Add a server to monitor (⌘N), a folder (⇧⌘N), or import hosts")
            .popover(isPresented: $isShowingChoices, arrowEdge: .bottom) {
                VStack(spacing: 4) {
                    AddChoiceRow(title: "New Host", systemImage: "server.rack", shortcut: "⌘N") {
                        choose { model.requestNewHost() }
                    }
                    AddChoiceRow(title: "New Folder", systemImage: "folder.fill", shortcut: "⇧⌘N") {
                        choose { model.requestNewFolder() }
                    }
                    AddChoiceRow(title: "Import Hosts", systemImage: "square.and.arrow.down.fill", shortcut: nil) {
                        choose { isImporting = true }
                    }
                }
                .padding(8)
                .frame(width: 280)
            }
            .sheet(isPresented: $isImporting) {
                ImportSheet { ids in
                    if let first = ids.first { model.selection = first }
                }
            }
    }

    /// Closes the popover, then acts, so a sheet the choice opens is not refused by the popover.
    private func choose(_ action: @escaping () -> Void) {
        isShowingChoices = false
        Task { @MainActor in action() }
    }
}

/// One row of the Add popover: a gel icon, a large title and its keyboard shortcut, lit in aqua
/// under the pointer.
private struct AddChoiceRow: View {
    let title: String
    let systemImage: String
    let shortcut: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SymbolGel(systemImage: systemImage, size: 34)
                Text(title)
                    .font(Aero.font(.title3, weight: .medium))
                    .foregroundStyle(Aero.text.primary)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
                    .fill(Aero.aqua.opacity(isHovered ? 0.18 : 0))
            }
            .contentShape(.rect(cornerRadius: Aero.radius.inner))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.12), value: isHovered)
    }
}
