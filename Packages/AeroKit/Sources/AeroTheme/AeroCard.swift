import SwiftUI

/// A glass card: translucent fill over the system material, a white gloss over the top,
/// a rim highlight and a soft shadow. With Reduce Transparency it uses a solid fill.
///
/// ```swift
/// AeroCard {
///     Text("web-01")
/// }
/// ```
public struct AeroCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Creates a card around `content`, inset by `padding` points (default 16).
    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    /// The card.
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous)
        content
            .padding(padding)
            .background {
                if reduceTransparency {
                    shape.fill(Aero.glass.solidFill)
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Aero.glass.fill)
                        // Gloss over the top 45%.
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Aero.glass.rimTop.opacity(0.6), location: 0),
                                    .init(color: Aero.glass.rimTop.opacity(0), location: 0.45),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
                }
            }
            .overlay { shape.strokeBorder(Aero.glass.rim, lineWidth: 1) }
            .clipShape(shape)
            .aeroShadow()
    }
}
