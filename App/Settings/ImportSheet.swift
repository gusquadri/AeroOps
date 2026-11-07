import AeroCore
import AeroTheme
import SwiftUI

/// Lists the apps AeroOps can import hosts from, then shows the chosen one's import.
struct ImportSheet: View {
    enum Source { case sshConfig, termius }

    @Environment(\.dismiss) private var dismiss
    @State private var source: Source?
    let onImport: @MainActor ([RemoteHost.ID]) -> Void

    var body: some View {
        switch source {
        case .sshConfig: SSHConfigImportSheet(onImport: onImport)
        case .termius: TermiusImportSheet(onImport: onImport)
        case nil: chooser
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Hosts")
                    .font(Aero.font(.title2, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                Text("Choose where to import hosts from.")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
            }
            ImportSourceRow(
                title: "SSH Config",
                detail: "Hosts in ~/.ssh/config. AeroOps only reads the file and never opens key files.",
                systemImage: "square.and.arrow.down"
            ) { source = .sshConfig }
            ImportSourceRow(
                title: "Termius",
                detail: "Hosts saved in the Termius app on this Mac, with their keys and passwords.",
                systemImage: "arrow.down.app"
            ) { source = .termius }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.aquaSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background { Aero.sky.gradient.ignoresSafeArea() }
    }
}

private struct ImportSourceRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AeroCard(padding: 12) {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(Aero.font(.title2))
                        .foregroundStyle(Aero.aquaDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(Aero.font(.headline))
                            .foregroundStyle(Aero.text.primary)
                        Text(detail)
                            .font(Aero.font(.callout))
                            .foregroundStyle(Aero.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Aero.text.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview("Import") {
    ImportSheet { _ in }
        .environment(AppModel.preview())
}
