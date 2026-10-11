import SwiftUI

/// The Aero primary button: an aqua capsule with a vertical gradient and an inner highlight,
/// darker while pressed, dimmed when disabled.
///
/// This is a `ButtonStyle` rather than a custom view, so it works with every `Button`
/// initialiser (title, `Label`, SF Symbol via `systemImage:`, roles, keyboard shortcuts):
///
/// ```swift
/// Button("Open SSH", systemImage: "terminal") { open() }
///     .buttonStyle(.aqua)
/// ```
public struct AquaButtonStyle: ButtonStyle {
    /// Creates the style. Prefer `.buttonStyle(.aqua)`.
    public init() {}

    /// Builds the styled button.
    public func makeBody(configuration: Configuration) -> some View {
        AquaButtonBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == AquaButtonStyle {
    /// The Aero primary button style: `.buttonStyle(.aqua)`.
    public static var aqua: AquaButtonStyle { AquaButtonStyle() }
}

private struct AquaButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Aero.font(.body, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    Capsule().fill(
                        LinearGradient(
                            colors: [Aero.aqua.mix(with: .white, by: 0.35), Aero.aqua],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    // Inner highlight over the top half.
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Aero.glass.rimTop, Aero.glass.rimTop.opacity(0)],
                            startPoint: .top, endPoint: .center
                        ))
                        .padding(2)
                        .opacity(0.6)
                }
            }
            .overlay { Capsule().strokeBorder(Aero.glass.rim, lineWidth: 1) }
            .brightness(pressed ? -0.12 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
    }
}
