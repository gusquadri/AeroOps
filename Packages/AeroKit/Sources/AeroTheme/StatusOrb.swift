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
}

/// A small glossy sphere in the colour of an ``OrbTone``.
///
/// ```swift
/// StatusOrb(tone: .healthy)
/// ```
public struct StatusOrb: View {
    /// The status to show.
    public let tone: OrbTone
    /// Diameter in points.
    public let size: CGFloat

    /// Creates an orb of `size` points (default 12).
    public init(tone: OrbTone, size: CGFloat = 12) {
        self.tone = tone
        self.size = size
    }

    /// The orb.
    public var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [tone.color.mix(with: .white, by: 0.45), tone.color],
                center: UnitPoint(x: 0.35, y: 0.3),
                startRadius: 0, endRadius: size * 0.7
            ))
            .overlay(alignment: .top) {
                // Specular highlight.
                Ellipse()
                    .fill(Aero.glass.rimTop)
                    .frame(width: size * 0.55, height: size * 0.3)
                    .padding(.top, size * 0.08)
                    .opacity(0.8)
            }
            .overlay { Circle().strokeBorder(tone.color.mix(with: .black, by: 0.2), lineWidth: 0.5) }
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(tone.rawValue.capitalized)
    }
}
