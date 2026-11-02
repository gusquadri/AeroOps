import AeroTheme
import SwiftUI

/// A row's Stop, Restart and Delete menu, or a spinner while one of them runs.
struct WorkloadActionsMenu<Items: View>: View {
    let busy: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        if busy {
            ProgressView()
                .controlSize(.small)
                .help("Working…")
        } else {
            Menu {
                items()
            } label: {
                Label("Stop, Restart or Delete", systemImage: "power")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .foregroundStyle(Aero.aquaDeep)
            .fixedSize()
            .help("Stop, restart or delete")
        }
    }
}
