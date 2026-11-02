import AeroCore
import AeroTheme
import SwiftUI

/// A server in the lists of the Terminals, Files and Containers tabs.
struct HostRow: View {
    let host: RemoteHost
    let status: HostStatus
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(tone: status.orbTone, size: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                    .font(Aero.font(.headline))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                Text(host.connectionSummary)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// What a tab that starts from a server shows when there are none.
struct NoServersView: View {
    var body: some View {
        AeroEmptyState(
            systemImage: "server.rack",
            title: "No servers yet",
            message: "Add a server in the Servers tab."
        )
    }
}
