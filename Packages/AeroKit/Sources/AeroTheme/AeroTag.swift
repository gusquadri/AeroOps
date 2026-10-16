import SwiftUI

/// A small glossy capsule for host tags and status chips.
///
/// - `AeroTag("prod")`: a tag tinted with `tint` (default aqua), optionally with an SF Symbol.
/// - `AeroTag("CrashLoopBackOff", tone: .error)`: a status chip led by a ``StatusOrb``.
///
/// The text is always `Aero.text.primary` on the glass base (light by day, deep indigo by night),
/// so it keeps 4.5:1 whatever the tint.
///
/// ```swift
/// ForEach(host.tags, id: \.self) { AeroTag($0) }
/// AeroTag("Running", tone: .healthy)
/// ```
public struct AeroTag: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color
    private let tone: OrbTone?

    private var accessibility = AeroAccessibility()

    /// A tag tinted with `tint` (an Aero colour token), with an optional SF Symbol.
    public init(_ text: String, systemImage: String? = nil, tint: Color = Aero.aqua) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.tone = nil
    }

    /// A status chip: a ``StatusOrb`` of `tone` and the text, tinted with the tone's colour.
    public init(_ text: String, tone: OrbTone) {
        self.text = text
        self.systemImage = nil
        self.tint = tone.color
        self.tone = tone
    }

    /// The tag.
    public var body: some View {
        let strong = accessibility.increaseContrast
        HStack(spacing: 4) {
            if let tone {
                StatusOrb(tone: tone, size: 8)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(Aero.font(.caption, weight: .semibold))
        .foregroundStyle(Aero.text.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background {
            ZStack {
                Capsule().fill(accessibility.reduceTransparency ? Aero.glass.solidFill : AeroTagFill.base)
                Capsule().fill(tint.opacity(AeroTagFill.tintOpacity))
                Capsule().fill(Aero.glass.gloss)
            }
        }
        .overlay {
            Capsule().strokeBorder(
                strong ? AnyShapeStyle(Aero.glass.rimStrong) : AnyShapeStyle(tint.opacity(0.6)),
                lineWidth: strong ? 1 : 0.75
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Tag fill values, shared with the contrast tests.
enum AeroTagFill {
    /// The base under the tint: white by day, deep indigo by night.
    static let base = Aero.base.opacity(0.8)
    /// Opacity of the tint wash over the base.
    static let tintOpacity = 0.22
}

// MARK: - Previews

#Preview("AeroTag") {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            AeroTag("prod")
            AeroTag("eu-west", systemImage: "globe.europe.africa")
            AeroTag("k3s", tint: Aero.leaf)
            AeroTag("legacy", tint: Aero.neutral)
        }
        HStack {
            ForEach(OrbTone.allCases, id: \.self) { tone in
                AeroTag(tone.rawValue.capitalized, tone: tone)
            }
        }
    }
    .padding(40)
    .background { SkyBackground() }
}

#Preview("AeroTag: Increase Contrast + Reduce Transparency") {
    HStack {
        AeroTag("prod")
        AeroTag("Running", tone: .healthy)
        AeroTag("CrashLoopBackOff", tone: .error)
    }
    .padding(40)
    .background { SkyBackground() }
    .environment(\.aeroAccessibilityOverride, .all)
}
