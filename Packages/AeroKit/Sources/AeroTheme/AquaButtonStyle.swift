import SwiftUI

/// The Aero button: a glossy capsule with a vertical gradient, an inner highlight over the top
/// half and a caustic glow at the bottom; darker while pressed, desaturated when disabled.
///
/// - `.primary` (default, `.buttonStyle(.aqua)`): deep aqua with a white label. A button with
///   `role: .destructive` turns coral.
/// - `.secondary` (`.buttonStyle(.aquaSecondary)`): white glass with a deep aqua label, for
///   the less important action next to a primary one (Logs, Cancel, Copy).
///
/// Honours `controlSize` (`.small`, `.regular`, `.large`), Increase Contrast (stronger rim) and
/// Reduce Motion (no press animation). It is a `ButtonStyle` rather than a custom view, so it
/// works with every `Button` initialiser:
///
/// ```swift
/// Button("Open SSH", systemImage: "terminal") { open() }
///     .buttonStyle(.aqua)
/// Button("Logs") { showLogs() }
///     .buttonStyle(.aquaSecondary)
///     .controlSize(.small)
/// ```
public struct AquaButtonStyle: ButtonStyle {
    /// How much a button stands out.
    public enum Prominence: Sendable, Hashable, CaseIterable {
        /// Filled deep aqua (coral for destructive roles), white label.
        case primary
        /// White glass, deep aqua label.
        case secondary
    }

    /// The button's prominence.
    public let prominence: Prominence

    /// Creates the style. Prefer `.buttonStyle(.aqua)` or `.buttonStyle(.aquaSecondary)`.
    public init(_ prominence: Prominence = .primary) {
        self.prominence = prominence
    }

    /// Builds the styled button.
    public func makeBody(configuration: Configuration) -> some View {
        AquaButtonBody(configuration: configuration, prominence: prominence)
    }
}

extension ButtonStyle where Self == AquaButtonStyle {
    /// The Aero primary button style: `.buttonStyle(.aqua)`.
    public static var aqua: AquaButtonStyle { AquaButtonStyle() }
    /// The Aero secondary button style: `.buttonStyle(.aquaSecondary)`.
    public static var aquaSecondary: AquaButtonStyle { AquaButtonStyle(.secondary) }
}

// MARK: - Palette

/// Colours of one filled button variant. Internal; the contrast tests read them.
struct AquaFill: Sendable {
    /// Top of the base gradient, under the gloss.
    let top: Color
    /// The band behind the label (40%–80% of the height). White text on it reaches 4.5:1.
    let band: Color
    /// Bottom of the base gradient (lighter: the caustic).
    let bottom: Color
    /// Caustic glow colour at the bottom centre.
    let glow: Color
    /// Outer rim.
    let rim: Color

    static let primary = AquaFill(
        top: Color(hex: 0x3AAEEE),
        band: Aero.aquaDeep,
        bottom: Color(hex: 0x1C8FD8),
        glow: Aero.aquaLight,
        rim: Color(hex: 0x06508A)
    )

    static let destructive = AquaFill(
        top: Color(hex: 0xF07A70),
        band: Aero.coralDeep,
        bottom: Color(hex: 0xDE4E47),
        glow: Color(hex: 0xFF9F92),
        rim: Color(hex: 0x8A1F1C)
    )

    /// Base gradient: light top, the deep label band, a lighter bottom.
    var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: top, location: 0),
                .init(color: band, location: 0.40),
                .init(color: band, location: 0.80),
                .init(color: bottom, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// Secondary (white glass) button colours.
enum AquaGlassFill {
    /// Fill at the top and bottom of the capsule; the label sits on roughly white 90%.
    static let top = Color.white.opacity(0.96)
    static let bottom = Color.white.opacity(0.84)
    /// Label colour.
    static let label = Aero.aquaDeep
}

// MARK: - Body

private struct AquaButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominence: AquaButtonStyle.Prominence

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    private var accessibility = AeroAccessibility()

    init(configuration: ButtonStyleConfiguration, prominence: AquaButtonStyle.Prominence) {
        self.configuration = configuration
        self.prominence = prominence
    }

    var body: some View {
        let pressed = configuration.isPressed
        let metrics = Metrics(controlSize)
        configuration.label
            .font(metrics.font)
            .lineLimit(1)
            .foregroundStyle(prominence == .primary ? Aero.text.onAccent : AquaGlassFill.label)
            // Primary: a soft dark edge under the white label lifts it off the gloss.
            .shadow(
                color: prominence == .primary ? Aero.ink.opacity(0.5) : .clear,
                radius: 0.5, x: 0, y: 0.5
            )
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .frame(minHeight: metrics.minHeight)
            .background { surface(pressed: pressed) }
            .overlay { rim }
            .compositingGroup()
            .aeroShadow(pressed ? AeroShadow(color: .clear, blur: 0, x: 0, y: 0) : Aero.shadow.control)
            .saturation(isEnabled ? 1 : 0.1)
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(pressed && !accessibility.reduceMotion ? 0.97 : 1)
            .animation(accessibility.animation(.easeOut(duration: 0.12)), value: pressed)
            .contentShape(Capsule())
    }

    private var fill: AquaFill {
        configuration.role == .destructive ? .destructive : .primary
    }

    @ViewBuilder
    private func surface(pressed: Bool) -> some View {
        switch prominence {
        case .primary:
            ZStack {
                Capsule().fill(fill.gradient)
                // Caustic: light pooling at the bottom centre.
                if !accessibility.increaseContrast {
                    Capsule().fill(EllipticalGradient(
                        colors: [fill.glow.opacity(0.8), fill.glow.opacity(0)],
                        center: UnitPoint(x: 0.5, y: 1.1),
                        startRadiusFraction: 0, endRadiusFraction: 0.5
                    ))
                }
                GlossHighlight(opacity: pressed ? 0.45 : 0.9)
            }
            .brightness(pressed ? -0.1 : 0)
        case .secondary:
            ZStack {
                if accessibility.reduceTransparency {
                    Capsule().fill(Aero.glass.solidFill)
                } else {
                    Capsule().fill(LinearGradient(
                        colors: [AquaGlassFill.top, AquaGlassFill.bottom],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
                if pressed {
                    Capsule().fill(Aero.aqua.opacity(0.18))
                }
                GlossHighlight(opacity: 0.8)
            }
        }
    }

    @ViewBuilder
    private var rim: some View {
        let strong = accessibility.increaseContrast
        switch prominence {
        case .primary:
            ZStack {
                Capsule().strokeBorder(fill.rim.opacity(strong ? 1 : 0.75), lineWidth: strong ? 1.5 : 1)
                // Inner light edge, brightest at the top.
                Capsule()
                    .inset(by: 1)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.25)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
        case .secondary:
            Capsule().strokeBorder(
                strong
                    ? AnyShapeStyle(Aero.glass.rimStrong)
                    : AnyShapeStyle(LinearGradient(
                        colors: [Aero.aqua.opacity(0.35), Aero.aquaDeep.opacity(0.55)],
                        startPoint: .top, endPoint: .bottom
                    )),
                lineWidth: strong ? 1.5 : 1
            )
        }
    }

    /// Size-dependent font and padding.
    private struct Metrics {
        let font: Font
        let horizontal: CGFloat
        let vertical: CGFloat
        let minHeight: CGFloat

        init(_ size: ControlSize) {
            switch size {
            case .mini, .small:
                font = Aero.font(.callout, weight: .semibold)
                horizontal = 11; vertical = 3; minHeight = 22
            case .large, .extraLarge:
                font = Aero.font(.title3, weight: .semibold)
                horizontal = 22; vertical = 9; minHeight = 38
            default:
                font = Aero.font(.body, weight: .semibold)
                horizontal = 16; vertical = 6; minHeight = 28
            }
        }
    }
}

/// The inner gloss of Aqua controls: a white capsule over the top half, inset from the edges,
/// fading downwards.
struct GlossHighlight: View {
    var opacity: Double = 0.9

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            Capsule()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.85), .white.opacity(0.12)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(height: h * 0.48)
                .padding(.horizontal, h * 0.22)
                .padding(.top, 1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - Previews

#Preview("AquaButton: primary, secondary, destructive, disabled") {
    VStack(spacing: 16) {
        HStack(spacing: 12) {
            Button("Open SSH", systemImage: "terminal") {}.buttonStyle(.aqua)
            Button("Logs") {}.buttonStyle(.aquaSecondary)
            Button("Deny", role: .destructive) {}.buttonStyle(.aqua)
        }
        HStack(spacing: 12) {
            Button("Disabled") {}.buttonStyle(.aqua).disabled(true)
            Button("Disabled") {}.buttonStyle(.aquaSecondary).disabled(true)
        }
        HStack(spacing: 12) {
            Button("Small") {}.buttonStyle(.aqua).controlSize(.small)
            Button("Small") {}.buttonStyle(.aquaSecondary).controlSize(.small)
            Button("Large") {}.buttonStyle(.aqua).controlSize(.large)
        }
    }
    .padding(40)
    .background { SkyBackground() }
}

#Preview("AquaButton: Increase Contrast + Reduce Transparency") {
    HStack(spacing: 12) {
        Button("Open SSH", systemImage: "terminal") {}.buttonStyle(.aqua)
        Button("Logs") {}.buttonStyle(.aquaSecondary)
    }
    .padding(40)
    .background { SkyBackground() }
    .environment(\.aeroAccessibilityOverride, .all)
}
