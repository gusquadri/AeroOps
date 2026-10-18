import AeroTheme
import SwiftUI

/// A centred glass card explaining what will appear in an empty screen, with optional actions.
///
/// ```swift
/// AeroEmptyState(systemImage: "terminal", title: "No terminal tabs", message: "…") {
///     Button("Add Host", systemImage: "plus") { … }.buttonStyle(.aqua)
/// }
/// ```
struct AeroEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        // Centred in the available space, but inside a scroll view: wrapped text must never
        // raise the window's minimum height (it once grew the split view past the window).
        GeometryReader { proxy in
            ScrollView {
                card
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var card: some View {
        AeroCard(padding: 28) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(Aero.font(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Aero.aqua)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Aero.font(.title2, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Aero.font(.body))
                    .foregroundStyle(Aero.text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .padding(.top, 6)
            }
            .frame(maxWidth: 400)
        }
    }
}

extension AeroEmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// A "Coming soon" capsule for placeholder screens.
struct ComingSoonBadge: View {
    var text = "Coming soon"

    var body: some View {
        AeroTag(text, systemImage: "sparkles", tint: Aero.sun)
    }
}

#Preview("Empty state") {
    AeroEmptyState(
        systemImage: "square.grid.2x2",
        title: "Your servers will appear here",
        message: "Add a host to see its CPU, memory, disk and uptime at a glance."
    ) {
        Button("Add Host", systemImage: "plus") {}
            .buttonStyle(.aqua)
    }
    .background { SkyBackground() }
    .frame(width: 600, height: 420)
}
