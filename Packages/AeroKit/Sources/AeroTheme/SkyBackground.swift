import SwiftUI

/// The window background: the sky gradient with soft blurred bubbles, drawn once in a `Canvas`.
/// Fills its container and ignores safe areas; place it behind content with `.background`.
///
/// ```swift
/// RootView().background { SkyBackground() }
/// ```
public struct SkyBackground: View {
    /// Creates the background.
    public init() {}

    /// The background.
    public var body: some View {
        Aero.sky.gradient
            .overlay {
                Canvas { context, size in
                    context.addFilter(.blur(radius: 12))
                    for bubble in Self.bubbles {
                        let d = bubble.diameter * min(size.width, size.height)
                        let rect = CGRect(
                            x: bubble.x * size.width - d / 2,
                            y: bubble.y * size.height - d / 2,
                            width: d, height: d
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(Aero.glass.fill.opacity(bubble.opacity)))
                    }
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    /// Bubble layout as fractions of the canvas, so it scales with the window.
    private static let bubbles: [(x: CGFloat, y: CGFloat, diameter: CGFloat, opacity: Double)] = [
        (0.12, 0.18, 0.22, 0.35),
        (0.82, 0.12, 0.30, 0.25),
        (0.68, 0.72, 0.18, 0.30),
        (0.25, 0.85, 0.12, 0.40),
        (0.92, 0.55, 0.10, 0.35),
    ]
}
