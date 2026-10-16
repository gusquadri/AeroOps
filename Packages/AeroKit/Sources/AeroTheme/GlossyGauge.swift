import SwiftUI

/// A glossy ring gauge, used for CPU, memory and disk.
///
/// `value` is a fraction in `0...1` (clamped); `nil` or NaN shows a dash, e.g. CPU on the
/// first poll. The ring is a glass tube in a recessed groove: leaf-to-aqua normally, leaf-to-sun
/// from `warningThreshold` (default 80%) and sun-to-coral from `criticalThreshold` (default 95%).
/// A glass bubble in the centre shows the value as a whole percentage; `label` sits underneath.
///
/// ```swift
/// GlossyGauge(value: snapshot.memUsedFraction, label: "Memory")
/// GlossyGauge(value: disk, label: "Disk", warningThreshold: 0.85, criticalThreshold: 0.97)
/// ```
public struct GlossyGauge: View {
    /// Fraction `0...1`, or `nil` for "no data".
    public let value: Double?
    /// Caption under the ring, e.g. "CPU".
    public let label: String
    /// Fraction from which the ring turns sun (warning). Default 0.8.
    public let warningThreshold: Double
    /// Fraction from which the ring turns coral (critical). Default 0.95.
    public let criticalThreshold: Double
    /// Ring diameter in points. Default 64.
    public let diameter: CGFloat

    private var accessibility = AeroAccessibility()

    /// Creates a gauge. `value` is a fraction `0...1`; `nil` shows a dash.
    public init(
        value: Double?,
        label: String,
        warningThreshold: Double = 0.8,
        criticalThreshold: Double = 0.95,
        diameter: CGFloat = 64
    ) {
        self.value = value
        self.label = label
        self.warningThreshold = warningThreshold
        self.criticalThreshold = criticalThreshold
        self.diameter = diameter
    }

    /// The gauge.
    public var body: some View {
        let fraction = Self.clamped(value)
        let level = Self.level(for: value, warning: warningThreshold, critical: criticalThreshold)
        let strong = accessibility.increaseContrast
        VStack(spacing: 6) {
            ZStack {
                GaugeSpecular(lineWidth: lineWidth)
                GaugeBubble(inset: lineWidth + 3)
                Text(Self.formatted(value))
                    .font(Aero.font(size: diameter * 0.24, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(fraction == nil ? Aero.text.secondary : Aero.text.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, lineWidth + 4)
            }
            .frame(width: diameter, height: diameter)
            // The groove and the tube sit in a background: drawn first, as before, but outside
            // the layout, so the animating tube does not re-measure the stacks and grid around
            // the gauge on every frame.
            .background {
                ZStack {
                    GaugeGroove(lineWidth: lineWidth, strong: strong)
                    if let fraction, fraction > 0 {
                        GaugeTube(fraction: fraction, colors: level.colors, lineWidth: lineWidth)
                    }
                }
            }
            // Keyed on the shown percentage: a sub-percent move (under 2 pt of ring) lands in
            // one frame instead of running the 0.6 s spring at the display rate.
            .animation(accessibility.animation(Self.animation), value: Self.percent(value))
            Text(label)
                .font(Aero.font(.caption, weight: .semibold))
                .foregroundStyle(strong ? Aero.text.primary : Aero.text.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Self.formatted(value))
    }

    private var lineWidth: CGFloat { max(6, diameter * 0.14) }

    /// The ring's move to a new value: `.smooth(duration: 0.6)`'s curve, ended once it is
    /// within 0.1% of the change (under 0.2 pt of ring even for a 0-to-100% swing). Evaluating
    /// it costs a fraction of SwiftUI's own spring, which was a tenth of each animation frame
    /// with twenty hosts on the Dashboard.
    nonisolated static let animation = Animation(SettlingSpring(duration: 0.6, remaining: 0.001))

    // MARK: Logic (unit-tested)

    /// The dash shown when there is no value.
    nonisolated static let placeholder = "—"

    /// `value` clamped to `0...1`, or `nil` for `nil`/NaN.
    nonisolated static func clamped(_ value: Double?) -> Double? {
        guard let value, !value.isNaN else { return nil }
        return min(max(value, 0), 1)
    }

    /// The value as a whole percentage `0...100`, or `nil` for `nil`/NaN.
    nonisolated static func percent(_ value: Double?) -> Int? {
        clamped(value).map { Int(($0 * 100).rounded()) }
    }

    /// Centre text: "42%" or the dash.
    nonisolated static func formatted(_ value: Double?) -> String {
        guard let percent = percent(value) else { return placeholder }
        return "\(percent)%"
    }

    /// The colour band for `value`.
    nonisolated static func level(for value: Double?, warning: Double, critical: Double) -> Level {
        guard let fraction = clamped(value) else { return .none }
        if fraction >= critical { return .critical }
        if fraction >= warning { return .warning }
        return .normal
    }

    /// Colour band of the ring.
    enum Level: Sendable, Equatable {
        /// No value: groove only.
        case none
        /// Leaf to aqua.
        case normal
        /// Leaf to sun.
        case warning
        /// Sun to coral.
        case critical

        var colors: [Color] {
            switch self {
            case .none, .normal: [Aero.leaf, Aero.aqua]
            case .warning: [Aero.leaf, Aero.sun]
            case .critical: [Aero.sun, Aero.coral]
            }
        }
    }
}

// MARK: - Animation

/// A critically damped spring (`Spring(duration:bounce: 0)`, the curve of
/// `.smooth(duration:)`) that ends once less than `remaining` of the change is left.
///
/// A change that lands mid-animation is added on top of the running one rather than merged
/// into it; both follow the same curve, so the ring still glides to the newest value.
struct SettlingSpring: CustomAnimation {
    let spring: Spring
    /// Time after which less than `remaining` of the change is left; the animation ends there.
    let cutoff: TimeInterval

    init(duration: TimeInterval, remaining: Double) {
        spring = Spring(duration: duration, bounce: 0)
        cutoff = spring.settlingDuration(target: 1.0, epsilon: remaining)
    }

    func animate<V: VectorArithmetic>(
        value: V, time: TimeInterval, context: inout AnimationContext<V>
    ) -> V? {
        guard time < cutoff else { return nil }
        return spring.value(target: value, time: time)
    }

    func velocity<V: VectorArithmetic>(
        value: V, time: TimeInterval, context: AnimationContext<V>
    ) -> V? {
        spring.velocity(target: value, time: time)
    }
}

// MARK: - Parts

/// The recessed track: darker at the top, lit at the bottom, so it reads as a groove.
private struct GaugeGroove: View {
    let lineWidth: CGFloat
    let strong: Bool

    var body: some View {
        let ring = Circle().inset(by: lineWidth / 2)
        ZStack {
            ring.stroke(Aero.glass.fill, lineWidth: lineWidth)
            ring.stroke(
                LinearGradient(
                    colors: [Aero.ink.opacity(strong ? 0.35 : 0.22), Aero.ink.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: lineWidth
            )
            // Outer and inner lips of the groove.
            Circle().strokeBorder(Aero.ink.opacity(strong ? 0.4 : 0.12), lineWidth: 0.75)
            Circle()
                .inset(by: lineWidth)
                .stroke(
                    LinearGradient(
                        colors: [Aero.sheen.opacity(0.2), Aero.sheen.opacity(0.9)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }
}

/// The value arc: a gradient tube with a highlight running along it and a soft glow.
private struct GaugeTube: View {
    let fraction: Double
    let colors: [Color]
    let lineWidth: CGFloat

    var body: some View {
        // The gradient spans only the arc, so a short arc still shows both colours.
        let gradient = AngularGradient(
            colors: colors, center: .center,
            startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.02))
        )
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: (colors.last ?? Aero.aqua).opacity(0.45), radius: 3)
            // Highlight along the outer half of the tube.
            Circle()
                .inset(by: lineWidth * 0.3)
                .trim(from: 0, to: fraction)
                .stroke(
                    .white.opacity(0.55),
                    style: StrokeStyle(lineWidth: lineWidth * 0.22, lineCap: .round)
                )
                .blur(radius: 0.4)
            // Shade along the inner edge gives the tube its roundness.
            Circle()
                .inset(by: lineWidth * 0.86)
                .trim(from: 0, to: fraction)
                .stroke(
                    Aero.ink.opacity(0.18),
                    style: StrokeStyle(lineWidth: lineWidth * 0.2, lineCap: .round)
                )
                .blur(radius: 0.6)
        }
        .rotationEffect(.degrees(-90))
    }
}

/// A fixed specular reflection on the ring's upper left, as if lit from above.
private struct GaugeSpecular: View {
    let lineWidth: CGFloat

    var body: some View {
        Circle()
            .inset(by: lineWidth * 0.32)
            .trim(from: 0.56, to: 0.70)
            .stroke(
                Aero.sheen.opacity(0.9),
                style: StrokeStyle(lineWidth: lineWidth * 0.26, lineCap: .round)
            )
            .blur(radius: 0.5)
            .allowsHitTesting(false)
    }
}

/// The glass bubble in the centre of the ring that carries the value text: white by day, deep
/// indigo by night.
struct GaugeBubble: View {
    let inset: CGFloat

    /// Opacity of the base at the bubble's rim, its most transparent (read by the contrast tests).
    static let edgeOpacity = 0.62

    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(RadialGradient(
                    colors: [Aero.base.opacity(0.95), Aero.base.opacity(GaugeBubble.edgeOpacity)],
                    center: UnitPoint(x: 0.5, y: 0.7), startRadius: 0, endRadius: d * 0.6
                ))
                // Top gloss.
                Ellipse()
                    .fill(LinearGradient(
                        colors: [Aero.sheen.opacity(0.95), Aero.sheen.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: d * 0.72, height: d * 0.42)
                    .offset(y: -d * 0.24)
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [Aero.ink.opacity(0.10), Aero.sheen.opacity(0.9)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .frame(width: d, height: d)
        }
        .padding(inset)
        .allowsHitTesting(false)
    }
}

// MARK: - Previews

#Preview("GlossyGauge: nil, low, mid, warning, critical") {
    HStack(spacing: 20) {
        GlossyGauge(value: nil, label: "CPU")
        GlossyGauge(value: 0.12, label: "CPU")
        GlossyGauge(value: 0.48, label: "Memory")
        GlossyGauge(value: 0.86, label: "Disk")
        GlossyGauge(value: 0.97, label: "Disk")
    }
    .padding(24)
    .background { AeroCard { Color.clear } }
    .padding(40)
    .background { SkyBackground() }
}

#Preview("GlossyGauge: custom thresholds and size") {
    HStack(spacing: 20) {
        GlossyGauge(value: 0.7, label: "Warn at 60%", warningThreshold: 0.6, criticalThreshold: 0.9, diameter: 96)
        GlossyGauge(value: 0.92, label: "Crit at 90%", warningThreshold: 0.6, criticalThreshold: 0.9, diameter: 96)
    }
    .padding(40)
    .background { SkyBackground() }
}

#Preview("GlossyGauge: Increase Contrast") {
    HStack(spacing: 20) {
        GlossyGauge(value: nil, label: "CPU")
        GlossyGauge(value: 0.42, label: "Memory")
        GlossyGauge(value: 0.99, label: "Disk")
    }
    .padding(40)
    .background { SkyBackground() }
    .environment(\.aeroAccessibilityOverride, .all)
}
