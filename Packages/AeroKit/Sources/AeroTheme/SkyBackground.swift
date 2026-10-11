import SwiftUI

/// The window background: the sky gradient with a sun bloom, light rays, glossy ribbons, a
/// leaf-green glow and soft bubbles, all drawn once in a single `Canvas`.
///
/// Nothing animates: the canvas redraws only when its size changes, so it costs nothing while
/// the window is idle. Everything is laid out in fractions of the canvas, so it scales with
/// the window. With Increase Contrast the decoration is toned down.
/// Fills its container and ignores safe areas; place it behind content with `.background`.
///
/// ```swift
/// RootView().background { SkyBackground() }
/// ```
public struct SkyBackground: View {
    private var accessibility = AeroAccessibility()

    /// Creates the background.
    public init() {}

    /// The background.
    public var body: some View {
        let painter = SkyPainter(calm: accessibility.increaseContrast)
        Canvas(opaque: true) { context, size in
            painter.paint(in: &context, size: size)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Draws the sky. Pure function of the canvas size, so the drawing is deterministic.
struct SkyPainter: Sendable {
    /// Tone the decoration down (Increase Contrast).
    var calm = false

    private var decoration: Double { calm ? 0.45 : 1 }

    func paint(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let w = size.width, h = size.height
        let bounds = Path(CGRect(origin: .zero, size: size))
        let sun = CGPoint(x: w * 0.14, y: -h * 0.08)

        // 1. Sky gradient, top to bottom.
        context.fill(bounds, with: .linearGradient(
            Gradient(stops: [
                .init(color: Aero.sky.top, location: 0),
                .init(color: Aero.sky.top.mix(with: Aero.sky.bottom, by: 0.5), location: 0.48),
                .init(color: Aero.sky.bottom, location: 0.9),
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
        ))

        // 2. Ground glow: a hint of leaf green bottom left, aqua bottom right.
        context.fill(bounds, with: .radialGradient(
            Gradient(colors: [Aero.leaf.opacity(0.30 * decoration), Aero.leaf.opacity(0)]),
            center: CGPoint(x: w * 0.02, y: h * 1.08), startRadius: 0, endRadius: max(w, h) * 0.5
        ))
        context.fill(bounds, with: .radialGradient(
            Gradient(colors: [Aero.aqua.opacity(0.16 * decoration), Aero.aqua.opacity(0)]),
            center: CGPoint(x: w * 1.0, y: h * 1.05), startRadius: 0, endRadius: max(w, h) * 0.42
        ))

        // 3. Sun bloom.
        context.fill(bounds, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.9), location: 0),
                .init(color: .white.opacity(0.35), location: 0.28),
                .init(color: .white.opacity(0), location: 1),
            ]),
            center: sun, startRadius: 0, endRadius: max(w, h) * 0.62
        ))

        // 4. Light rays fanning out from the sun.
        if !calm {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: min(w, h) * 0.014))
                let length = hypot(w, h) * 1.2
                for ray in Self.rays {
                    let a0 = Angle.degrees(ray.angle - ray.spread / 2).radians
                    let a1 = Angle.degrees(ray.angle + ray.spread / 2).radians
                    var wedge = Path()
                    wedge.move(to: sun)
                    wedge.addLine(to: CGPoint(x: sun.x + cos(a0) * length, y: sun.y + sin(a0) * length))
                    wedge.addLine(to: CGPoint(x: sun.x + cos(a1) * length, y: sun.y + sin(a1) * length))
                    wedge.closeSubpath()
                    layer.fill(wedge, with: .radialGradient(
                        Gradient(colors: [.white.opacity(ray.opacity), .white.opacity(0)]),
                        center: sun, startRadius: 0, endRadius: length * 0.8
                    ))
                }
            }
        }

        // 5. Glossy ribbons sweeping across the lower half.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.2))
            for ribbon in Self.ribbons {
                drawRibbon(ribbon, in: &layer, size: size)
            }
        }

        // 6. Out-of-focus bokeh discs.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: min(w, h) * 0.018))
            for disc in Self.bokeh {
                let r = disc.diameter * min(w, h) / 2
                let center = CGPoint(x: disc.x * w, y: disc.y * h)
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                layer.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(disc.opacity * 0.4 * decoration), location: 0),
                        .init(color: .white.opacity(disc.opacity * decoration), location: 0.92),
                        .init(color: .white.opacity(0), location: 1),
                    ]),
                    center: center, startRadius: 0, endRadius: r
                ))
            }
        }

        // 7. Crisp soap bubbles.
        for bubble in Self.bubbles {
            drawBubble(bubble, in: &context, size: size)
        }
    }

    // MARK: Ribbons

    /// A ribbon is a stack of curves from its top edge to its bottom edge, brightest at the
    /// leading (top) edge and fading towards the trailing one, and faded out at both ends.
    private func drawRibbon(_ ribbon: Ribbon, in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
        func curve(at t: CGFloat) -> Path {
            let y = (0..<4).map { ribbon.top[$0] + (ribbon.bottom[$0] - ribbon.top[$0]) * t }
            var path = Path()
            path.move(to: p(-0.05, y[0]))
            path.addCurve(to: p(1.05, y[3]), control1: p(0.32, y[1]), control2: p(0.66, y[2]))
            return path
        }
        func shading(_ color: Color, _ alpha: Double) -> GraphicsContext.Shading {
            .linearGradient(
                Gradient(stops: [
                    .init(color: color.opacity(0), location: 0.0),
                    .init(color: color.opacity(alpha), location: 0.32),
                    .init(color: color.opacity(alpha * 0.7), location: 0.68),
                    .init(color: color.opacity(0), location: 1.0),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: 0)
            )
        }

        let alpha = ribbon.opacity * decoration
        let thickness = (0..<4).map { abs(ribbon.bottom[$0] - ribbon.top[$0]) }.max()! * h
        let steps = 14
        for step in 0..<steps {
            let t = CGFloat(step) / CGFloat(steps)
            let falloff = pow(1 - Double(t), 1.6)
            context.stroke(
                curve(at: t),
                with: shading(ribbon.tint, alpha * falloff),
                lineWidth: thickness / CGFloat(steps) * 1.6
            )
        }
        // Bright leading edge.
        context.stroke(curve(at: 0), with: shading(.white, min(1, alpha * 2.6)), lineWidth: 1.5)
    }

    // MARK: Bubbles

    private func drawBubble(_ bubble: Bubble, in context: inout GraphicsContext, size: CGSize) {
        let s = min(size.width, size.height)
        let r = bubble.diameter * s / 2
        let c = CGPoint(x: bubble.x * size.width, y: bubble.y * size.height)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let circle = Path(ellipseIn: rect)
        let k = bubble.opacity * decoration

        // Thin-film body: clear centre, brighter towards the rim.
        context.fill(circle, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0.06 * k), location: 0.6),
                .init(color: .white.opacity(0.28 * k), location: 0.88),
                .init(color: .white.opacity(0.6 * k), location: 1),
            ]),
            center: c, startRadius: 0, endRadius: r
        ))
        // A touch of aqua in the lower half.
        context.fill(circle, with: .linearGradient(
            Gradient(colors: [Aero.aqua.opacity(0), Aero.aqua.opacity(0.14 * k)]),
            startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)
        ))
        context.stroke(circle, with: .color(.white.opacity(0.55 * k)), lineWidth: max(0.75, r * 0.035))

        // Specular highlight, tilted, upper left.
        let spec = CGRect(x: -r * 0.32, y: -r * 0.17, width: r * 0.64, height: r * 0.34)
        let specPath = Path(ellipseIn: spec).applying(
            CGAffineTransform(rotationAngle: -.pi / 5)
                .concatenating(CGAffineTransform(translationX: c.x - r * 0.4, y: c.y - r * 0.46))
        )
        context.fill(specPath, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.95 * k), .white.opacity(0.15 * k)]),
            startPoint: CGPoint(x: c.x - r * 0.7, y: c.y - r * 0.8),
            endPoint: CGPoint(x: c.x - r * 0.1, y: c.y - r * 0.2)
        ))

        // Crescent reflection, lower right.
        var crescent = Path()
        crescent.addArc(center: c, radius: r * 0.8, startAngle: .degrees(10), endAngle: .degrees(75), clockwise: false)
        context.stroke(crescent, with: .color(.white.opacity(0.5 * k)),
                       style: StrokeStyle(lineWidth: max(1, r * 0.07), lineCap: .round))
    }

    // MARK: Layout (fractions of the canvas)

    private struct Ray: Sendable {
        let angle: Double, spread: Double, opacity: Double
    }

    private struct Ribbon: Sendable {
        /// Y of the top edge at x = -0.05, the two control points and x = 1.05.
        let top: [CGFloat]
        /// Y of the bottom edge, same x positions.
        let bottom: [CGFloat]
        let tint: Color
        let opacity: Double
    }

    private struct Bubble: Sendable {
        let x: CGFloat, y: CGFloat, diameter: CGFloat, opacity: Double
    }

    /// Angles in degrees, 0 = right, 90 = down (the sun is above the top-left corner).
    private static let rays: [Ray] = [
        Ray(angle: 16, spread: 4, opacity: 0.26),
        Ray(angle: 26, spread: 7, opacity: 0.20),
        Ray(angle: 37, spread: 3, opacity: 0.30),
        Ray(angle: 46, spread: 8, opacity: 0.16),
        Ray(angle: 57, spread: 4, opacity: 0.24),
        Ray(angle: 68, spread: 6, opacity: 0.16),
        Ray(angle: 79, spread: 3, opacity: 0.20),
    ]

    private static let ribbons: [Ribbon] = [
        Ribbon(top: [0.66, 0.46, 0.90, 0.52], bottom: [0.75, 0.60, 1.00, 0.62], tint: .white, opacity: 0.30),
        Ribbon(top: [0.80, 0.60, 0.98, 0.68], bottom: [0.84, 0.67, 1.03, 0.73], tint: .white, opacity: 0.50),
        Ribbon(top: [0.88, 0.72, 1.04, 0.78], bottom: [0.98, 0.88, 1.14, 0.92], tint: Aero.leaf, opacity: 0.34),
    ]

    private static let bokeh: [Bubble] = [
        Bubble(x: 0.88, y: 0.16, diameter: 0.30, opacity: 0.20),
        Bubble(x: 0.70, y: 0.06, diameter: 0.14, opacity: 0.22),
        Bubble(x: 0.08, y: 0.62, diameter: 0.22, opacity: 0.16),
        Bubble(x: 0.55, y: 0.88, diameter: 0.18, opacity: 0.18),
        Bubble(x: 0.97, y: 0.70, diameter: 0.16, opacity: 0.18),
    ]

    private static let bubbles: [Bubble] = [
        Bubble(x: 0.80, y: 0.26, diameter: 0.13, opacity: 1),
        Bubble(x: 0.90, y: 0.42, diameter: 0.06, opacity: 0.9),
        Bubble(x: 0.73, y: 0.40, diameter: 0.035, opacity: 0.85),
        Bubble(x: 0.10, y: 0.80, diameter: 0.09, opacity: 0.95),
        Bubble(x: 0.19, y: 0.90, diameter: 0.04, opacity: 0.85),
        Bubble(x: 0.40, y: 0.12, diameter: 0.045, opacity: 0.75),
        Bubble(x: 0.62, y: 0.80, diameter: 0.07, opacity: 0.85),
        Bubble(x: 0.95, y: 0.88, diameter: 0.05, opacity: 0.85),
    ]
}

// MARK: - Previews

#Preview("SkyBackground") {
    SkyBackground()
        .frame(width: 900, height: 600)
}

#Preview("SkyBackground: Increase Contrast") {
    SkyBackground()
        .frame(width: 900, height: 600)
        .environment(\.aeroAccessibilityOverride, .all)
}
