import AeroTheme
import SwiftUI

struct NoMatchingHostsView: View {
    let search: String

    var body: some View {
        AeroCard(padding: 24) {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(Aero.font(size: 32, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Aero.aqua)
                    .accessibilityHidden(true)
                Text("No matches")
                    .font(Aero.font(.headline))
                    .foregroundStyle(Aero.text.primary)
                Text("No name or address contains “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NoMatchingHostsView(search: "10.0.3")
        .padding()
        .background { SkyBackground() }
}
