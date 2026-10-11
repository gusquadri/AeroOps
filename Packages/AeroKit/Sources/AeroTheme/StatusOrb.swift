import SwiftUI

/// The meaning of a ``StatusOrb``. AeroTheme does not know about hosts or pods; the app maps
/// its own states (e.g. `HostStatus`, pod phase) onto these tones.
public enum OrbTone: String, Sendable, Hashable, CaseIterable {
    /// Leaf green: online, running and ready.
    case healthy
    /// Sun yellow: stale, pending, container creating.
    case warning
    /// Coral red: offline, crash-looping, error.
    case error
    /// Grey: loading, unsupported, succeeded.
    case neutral

    /// The token colour for this tone.
    public var color: Color {
        switch self {
        case .healthy: Aero.leaf
        case .warning: Aero.sun
        case .error: Aero.coral
        case .neutral: Aero.neutral
        }
    }

    /// A darker shade of ``color`` for rims and the orb's lower edge.
    var deepColor: Color {
        switch self {
        case .healthy: Aero.leafDeep
        case .warning: Aero.sunDeep
        case .error: Aero.coralDeep
        case .neutral: Aero.neutralDeep
        }
    }
}

/// A small glossy sphere in the colour of an ``OrbTone``: lit from within at the bottom,
/// with a white specular cap on top and a darker rim.
///
/// ```swift
/// StatusOrb(tone: .healthy)
/// ```
public struct StatusOrb: View {
    /// The status to show.
    public let tone: OrbTone
    /// Diameter in points.
    public let size: CGFloat

    private var accessibility = AeroAccessibility()

    /// Creates an orb of `size` points (default 12).
    public init(tone: OrbTone, size: CGFloat = 12) {
        self.tone = tone
        self.size = size
    }

    /// The orb.
    public var body: some View {
        let strong = accessibility.increaseContrast
        ZStack {
            // Body: light pools at the bottom, the edge darkens.
            Circle().fill(RadialGradient(
                stops: [
                    .init(color: tone.color.mix(with: .white, by: 0.45), location: 0),
                    .init(color: tone.color, location: 0.55),
                    .init(color: tone.deepColor, location: 1),
                ],
                center: UnitPoint(x: 0.5, y: 0.92),
                startRadius: 0, endRadius: size * 0.95
            ))
            // Specular cap.
            Ellipse()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.95), .white.opacity(0.1)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: size * 0.68, height: size * 0.46)
                .offset(y: -size * 0.2)
            Circle().strokeBorder(
                tone.deepColor.opacity(strong ? 1 : 0.7),
                lineWidth: strong ? max(1, size * 0.08) : max(0.5, size * 0.05)
            )
        }
        .frame(width: size, height: size)
        .shadow(color: tone.deepColor.opacity(0.35), radius: size * 0.12, x: 0, y: size * 0.06)
        .accessibilityElement()
        .accessibilityLabel(tone.rawValue.capitalized)
    }
}

// MARK: - Previews

#Preview("StatusOrb: every tone and size") {
    VStack(spacing: 18) {
        ForEach([12.0, 20, 36], id: \.self) { size in
            HStack(spacing: 18) {
                ForEach(OrbTone.allCases, id: \.self) { tone in
                    StatusOrb(tone: tone, size: size)
                }
            }
        }
    }
    .padding(40)
    .background { SkyBackground() }
}

#Preview("StatusOrb: Increase Contrast") {
    HStack(spacing: 18) {
        ForEach(OrbTone.allCases, id: \.self) { tone in
            StatusOrb(tone: tone, size: 20)
        }
    }
    .padding(40)
    .background { SkyBackground() }
    .environment(\.aeroAccessibilityOverride, .all)
}
