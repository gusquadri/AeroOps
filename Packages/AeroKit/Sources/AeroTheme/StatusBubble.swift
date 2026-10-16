import SwiftUI

/// A large glossy status orb with a system logo inside: a round gel in the colour of an
/// ``OrbTone`` (light top, deep band, lighter bottom with a caustic glow, as on primary Aqua
/// buttons), the white ``SystemLogo`` under a specular cap, and a dark rim. Without a logo it
/// shows a generic server glyph.
///
/// The host card uses it in place of a small ``StatusOrb``, so one bubble says both how the host
/// is and what it runs.
///
/// ```swift
/// StatusBubble(tone: .healthy, logo: .ubuntu)
/// StatusBubble(tone: .warning, logo: SystemLogo.match(id: "alpine"), size: 32)
/// ```
public struct StatusBubble: View {
    /// The status, as the bubble's colour.
    public let tone: OrbTone
    /// The system inside, or `nil` for the generic server glyph.
    public let logo: SystemLogo?
    /// Diameter in points.
    public let size: CGFloat

    private var accessibility = AeroAccessibility()

    /// Creates a bubble of `size` points (default 40).
    public init(tone: OrbTone, logo: SystemLogo?, size: CGFloat = 40) {
        self.tone = tone
        self.logo = logo
        self.size = size
    }

    /// The bubble.
    public var body: some View {
        let fill = AquaFill.bubble(tone)
        let strong = accessibility.increaseContrast
        ZStack {
            Circle().fill(LinearGradient(
                stops: [
                    .init(color: fill.top, location: 0),
                    .init(color: fill.band, location: 0.32),
                    .init(color: fill.band, location: 0.72),
                    .init(color: fill.bottom, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            // Caustic: light pooling at the bottom.
            if !strong {
                Circle().fill(EllipticalGradient(
                    colors: [fill.glow.opacity(0.85), fill.glow.opacity(0)],
                    center: UnitPoint(x: 0.5, y: 1.05),
                    startRadiusFraction: 0, endRadiusFraction: 0.5
                ))
            }
            glyph
                .frame(width: size * Self.glyphFraction, height: size * Self.glyphFraction)
                .offset(y: size * 0.02)
            // Specular cap over the top of the logo, as if it sat under the glass.
            Ellipse()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.85), .white.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: size * 0.72, height: size * 0.42)
                .offset(y: -size * 0.25)
                .opacity(strong ? 0.5 : 1)
            Circle().strokeBorder(fill.rim.opacity(strong ? 1 : 0.75), lineWidth: strong ? 1.5 : 1)
            Circle()
                .inset(by: 1)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.3)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: fill.rim.opacity(0.35), radius: size * 0.08, x: 0, y: size * 0.05)
        .accessibilityElement()
        .accessibilityLabel(tone.rawValue.capitalized)
        .accessibilityValue(logo?.title ?? "")
    }

    /// The logo's share of the diameter: inside the circle with room for the rim.
    static let glyphFraction: CGFloat = 0.54

    @ViewBuilder
    private var glyph: some View {
        if let logo, logo.designPath != nil {
            SystemLogoShape(logo: logo)
                .fill(LinearGradient(
                    colors: [Aero.text.onAccent, Aero.text.onAccent.opacity(0.9)],
                    startPoint: .top, endPoint: .bottom
                ))
                // A soft dark edge under the white logo lifts it off the gel, like a button label.
                .shadow(color: Aero.ink.opacity(0.55), radius: 0.5, x: 0, y: 0.6)
        } else {
            Image(systemName: "server.rack")
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(Aero.text.onAccent)
                .shadow(color: Aero.ink.opacity(0.55), radius: 0.5, x: 0, y: 0.6)
                .padding(size * 0.03)
        }
    }
}

extension AquaFill {
    /// The gel of a ``StatusBubble`` in `tone`. White logos on the band reach 3:1 (WCAG non-text
    /// contrast); the contrast tests check it.
    static func bubble(_ tone: OrbTone) -> AquaFill {
        switch tone {
        case .healthy:
            AquaFill(top: Aero.leaf, band: Aero.leafDeep, bottom: Color(hex: 0x55B03C),
                     glow: Color(hex: 0xA6EB8A), rim: Color(hex: 0x24601A))
        case .warning:
            // Deeper than `sunDeep`: white on sun yellow would not reach 3:1.
            AquaFill(top: Aero.sun, band: Color(hex: 0xB87A00), bottom: Color(hex: 0xE0A21C),
                     glow: Color(hex: 0xFFE38F), rim: Color(hex: 0x7A5100))
        case .error:
            .destructive
        case .neutral:
            AquaFill(top: Color(hex: 0xB3C0CB), band: Aero.neutralDeep, bottom: Color(hex: 0x8091A2),
                     glow: Color(hex: 0xD5DEE6), rim: Color(hex: 0x45525F))
        }
    }
}

// MARK: - Previews

#Preview("StatusBubble: every tone, logos and the fallback") {
    VStack(spacing: 18) {
        ForEach(OrbTone.allCases, id: \.self) { tone in
            HStack(spacing: 14) {
                ForEach([SystemLogo.ubuntu, .debian, .alpine, .redHat, .freeBSD, .apple, .linux], id: \.self) { logo in
                    StatusBubble(tone: tone, logo: logo)
                }
                StatusBubble(tone: tone, logo: nil)
            }
        }
    }
    .padding(40)
    .background { SkyBackground() }
}

#Preview("StatusBubble: every logo") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 8), spacing: 12) {
        ForEach(SystemLogo.allCases, id: \.self) { logo in
            StatusBubble(tone: .healthy, logo: logo)
                .help(logo.title)
        }
    }
    .padding(40)
    .background { SkyBackground() }
}

#Preview("StatusBubble: Increase Contrast") {
    HStack(spacing: 14) {
        ForEach(OrbTone.allCases, id: \.self) { tone in
            StatusBubble(tone: tone, logo: .ubuntu)
        }
    }
    .padding(40)
    .background { SkyBackground() }
    .environment(\.aeroAccessibilityOverride, .all)
}
