import SwiftUI

/// A tinted wash for the header strip of a card, like the lit title bar of an Aero window:
/// `tint` at its strongest along the top edge, fading out towards the bottom of the strip, and
/// clipped to the card's top corners (`radius.card`).
///
/// Draw it behind a header that spans the card's full width, i.e. inside an
/// `AeroCard(padding: 0)`. ``GlassSection`` headers use it with aqua; dashboard cards tint it
/// with the host's status colour. Text on it keeps 4.5:1 for every orb tone and aqua
/// (unit-tested).
///
/// ```swift
/// AeroCard(padding: 0) {
///     header
///         .padding(16)
///         .background { AeroHeaderWash(tint: OrbTone.healthy.color) }
/// }
/// ```
public struct AeroHeaderWash: View {
    private let tint: Color
    private var accessibility = AeroAccessibility()

    /// Opacity of the tint along the top edge (read by the contrast tests).
    nonisolated static let peak = 0.24

    /// A wash of `tint` (an Aero colour token; default aqua).
    public init(tint: Color = Aero.aqua) {
        self.tint = tint
    }

    /// The wash.
    public var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: Aero.radius.card, topTrailingRadius: Aero.radius.card, style: .continuous
        )
        let peak = accessibility.increaseContrast ? Self.peak * 0.6 : Self.peak
        shape
            .fill(LinearGradient(
                stops: [
                    .init(color: tint.opacity(peak), location: 0),
                    .init(color: tint.opacity(peak * 0.45), location: 0.55),
                    .init(color: tint.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview("AeroHeaderWash: every tone") {
    HStack(spacing: 16) {
        ForEach(OrbTone.allCases, id: \.self) { tone in
            AeroCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        StatusOrb(tone: tone, size: 14)
                        Text(tone.rawValue.capitalized).font(Aero.font(.title3, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background { AeroHeaderWash(tint: tone.color) }
                    Text("Body")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                        .padding(16)
                }
            }
            .frame(width: 180)
        }
    }
    .padding(40)
    .background { SkyBackground() }
}
