import SwiftUI

/// A recessed, tinted panel inside a card, for a status line or a notice: an opaque light base
/// (so it reads the same over glass, forms and the sky), a wash of `tint`, a soft inner shade
/// along the top edge as if the well were pressed into the glass, and a `tint` hairline, at
/// `radius.inner`. Text on it keeps 4.5:1 for every orb tone and aqua (unit-tested).
///
/// ```swift
/// AeroWell(tint: Aero.coral) {
///     Label("Host key changed", systemImage: "exclamationmark.octagon.fill")
///         .padding(10)
/// }
/// ```
public struct AeroWell<Content: View>: View {
    private let tint: Color
    private let content: Content
    private var accessibility = AeroAccessibility()

    /// A well tinted with `tint` (an Aero colour token; default aqua) around `content`.
    public init(tint: Color = Aero.aqua, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    /// The well.
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
        content
            .background {
                shape.fill(Aero.glass.solidFill)
                shape.fill(tint.opacity(AeroWellFill.tintOpacity))
                shape.fill(LinearGradient(
                    colors: [Aero.ink.opacity(AeroWellFill.shadeOpacity), Aero.ink.opacity(0)],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)
                ))
            }
            .overlay {
                shape.strokeBorder(tint.opacity(accessibility.increaseContrast ? 1 : 0.8), lineWidth: 1)
            }
    }
}

/// ``AeroWell`` fill strengths (shared with the contrast tests).
enum AeroWellFill {
    /// Opacity of the tint wash over the solid base.
    static let tintOpacity = 0.14
    /// Opacity of the inner shade along the top edge.
    static let shadeOpacity = 0.08
}

// MARK: - Previews

#Preview("AeroWell: every tone") {
    AeroCard {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(OrbTone.allCases, id: \.self) { tone in
                AeroWell(tint: tone.color) {
                    HStack(spacing: 8) {
                        StatusOrb(tone: tone)
                        Text("Status line for \(tone.rawValue)")
                            .font(Aero.font(.caption, weight: .medium))
                            .foregroundStyle(Aero.text.secondary)
                        Spacer()
                    }
                    .padding(10)
                }
            }
        }
    }
    .frame(width: 320)
    .padding(40)
    .background { SkyBackground() }
}
