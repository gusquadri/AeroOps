import SwiftUI

/// A ring gauge with a leaf-to-aqua gradient, used for CPU, memory and disk.
///
/// `value` is a fraction in `0...1` (clamped); `nil` or NaN shows a dash, e.g. CPU on the
/// first poll. The centre shows the value as a whole percentage; `label` sits underneath.
///
/// ```swift
/// GlossyGauge(value: snapshot.memUsedFraction, label: "Memory")
/// ```
public struct GlossyGauge: View {
    /// Fraction `0...1`, or `nil` for "no data".
    public let value: Double?
    /// Caption under the ring, e.g. "CPU".
    public let label: String

    /// Creates a gauge. `value` is a fraction `0...1`; `nil` shows a dash.
    public init(value: Double?, label: String) {
        self.value = value
        self.label = label
    }

    /// The gauge.
    public var body: some View {
        let fraction = Self.clamped(value)
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Aero.glass.fill, lineWidth: 8)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            AngularGradient(colors: [Aero.leaf, Aero.aqua], center: .center),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Text(Self.formatted(value))
                    .font(Aero.font(size: 15, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 64, height: 64)
            Text(label)
                .font(Aero.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Self.formatted(value))
    }

    /// The dash shown when there is no value.
    nonisolated static let placeholder = "—"

    /// `value` clamped to `0...1`, or `nil` for `nil`/NaN.
    nonisolated static func clamped(_ value: Double?) -> Double? {
        guard let value, !value.isNaN else { return nil }
        return min(max(value, 0), 1)
    }

    /// Centre text: "42%" or the dash.
    nonisolated static func formatted(_ value: Double?) -> String {
        guard let fraction = clamped(value) else { return placeholder }
        return "\(Int((fraction * 100).rounded()))%"
    }
}
