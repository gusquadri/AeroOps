import CoreVideo
import IOSurface
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The window background, all drawn once in a single `Canvas`:
///
/// - By day (Frutiger Aero): the sky gradient with a sun bloom, light rays, rolling green hills,
///   glossy ribbons, soft bokeh, iridescent soap bubbles and lens sparkles.
/// - By night (Nightly Frutiger Aero, dark mode): a midnight-to-violet sky with a moon bloom,
///   faint moonbeams, a field of stars, aurora ribbons, glowing violet cloud banks, moonlit
///   bubbles and four-point star sparkles.
///
/// Nothing animates: the sky is painted again only when its size or the appearance changes, so
/// it costs nothing while the window is idle. Everything is laid out in fractions of the canvas,
/// so it scales with the window. With Increase Contrast the decoration is toned down (no rays
/// or sparkles). Text never sits on the hills or clouds directly, only on glass over them
/// (unit-tested contrast).
/// Fills its container and ignores safe areas; place it behind content with `.background`.
///
/// The window shows a bitmap of the sky rather than the `Canvas` itself: Core Animation redraws
/// a canvas, full-window blurs and all, on every frame of the sidebar or the inspector sliding,
/// even when its size does not change, and a bitmap only has to be composited. While the size
/// is changing (a live window resize), the last bitmap is stretched to fit, and the sky is
/// painted again, off the main thread, once the size holds. Until the first bitmap is ready,
/// and for a moment after the appearance changes, the canvas is drawn directly.
///
/// The bitmap is an `IOSurface`, shown as the contents of a plain layer (``SkySurface``). A
/// full-window bitmap is some 30 MB at 2x. Shown through a SwiftUI `Image`, it cost four times
/// that: the window server got a copy of each image, and SwiftUI's hit-testing kept the image
/// before the last one alive, copy and all. The window server reads an IOSurface where it is,
/// and the layer holds only the current one.
///
/// ```swift
/// RootView().background { SkyBackground() }
/// ```
public struct SkyBackground: View {
    private var accessibility = AeroAccessibility()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    /// The background's size, under the safe areas.
    @State private var size = CGSize.zero
    /// The last bitmap of the sky.
    @State private var painting: SkyPainting?

    /// How long the size has to hold before the sky is painted again.
    static let settleDelay = Duration.milliseconds(150)

    /// Creates the background.
    public init() {}

    /// The background.
    public var body: some View {
        let painter = SkyPainter(variant: AeroVariant(colorScheme), calm: accessibility.increaseContrast)
        let request = SkyPainting.Request(painter: painter, size: size, scale: displayScale)
        Color.clear
            .overlay {
                if let painting = SkyPainting.recent(request) ?? painting, painting.request.painter == painter {
                    SkySurfaceView(surface: painting.surface)
                } else {
                    Canvas(opaque: true) { context, size in
                        painter.paint(in: &context, size: size)
                    }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .task(id: request) {
                if let recent = SkyPainting.recent(request) {
                    painting = recent
                    return
                }
                guard painting?.request != request, request.size.width > 0, request.size.height > 0 else { return }
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled, let surface = await request.paint(), !Task.isCancelled else { return }
                painting = SkyPainting.remember(SkyPainting(request: request, surface: surface))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A bitmap of the sky.
private struct SkyPainting {
    /// What the bitmap shows.
    struct Request: Equatable {
        let painter: SkyPainter
        /// In points.
        let size: CGSize
        /// Pixels per point.
        let scale: CGFloat

        /// Paints the sky into a bitmap.
        ///
        /// `ImageRenderer` only records the drawing and leaves rasterizing it to whoever first
        /// draws the image, which would be Core Animation, on the main thread. The recording is
        /// drawn into a surface of its own in the background instead.
        @MainActor
        func paint() async -> IOSurface? {
            let painter = painter, size = size
            let renderer = ImageRenderer(
                content: Canvas(opaque: true) { context, _ in
                    painter.paint(in: &context, size: size)
                }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, painter.variant == .night ? .dark : .light)
            )
            renderer.scale = scale
            renderer.isOpaque = true
            guard let recording = renderer.cgImage else { return nil }
            return await Task.detached(priority: .userInitiated) {
                SkySurface.rasterize(recording)
            }.value
        }
    }

    let request: Request
    let surface: IOSurface

    /// The last bitmaps painted, newest first, shared by every background.
    @MainActor private static var cache: [SkyPainting] = []
    private static let cacheLimit = 2

    /// The bitmap of `request`, if one was painted lately.
    @MainActor
    static func recent(_ request: Request) -> SkyPainting? {
        cache.first { $0.request == request }
    }

    /// Keeps `painting` for backgrounds of its size to come, and returns it.
    @MainActor
    static func remember(_ painting: SkyPainting) -> SkyPainting {
        cache.removeAll { $0.request == painting.request }
        cache = Array(([painting] + cache).prefix(cacheLimit))
        return painting
    }
}

/// The sky's bitmap as an `IOSurface`, which a layer can show without the window server copying
/// it.
enum SkySurface {
    /// Draws `image` into a new BGRA surface of its size, tagged with its colour space so Core
    /// Animation matches its colours as it would the image's. The first row is the top, as in
    /// the image.
    nonisolated static func rasterize(_ image: CGImage) -> IOSurface? {
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let surface = IOSurface(properties: [
                  .width: image.width,
                  .height: image.height,
                  .bytesPerElement: 4,
                  .pixelFormat: kCVPixelFormatType_32BGRA,
              ])
        else { return nil }
        guard surface.lock(options: [], seed: nil) == KERN_SUCCESS else { return nil }
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.flush()
        if let colorSpace = space.copyPropertyList() {
            surface.setAttachment(colorSpace, forKey: kIOSurfaceColorSpace as String)
        }
        return surface
    }
}

#if os(macOS)
/// Shows a sky surface, stretched to the view's bounds.
private struct SkySurfaceView: NSViewRepresentable {
    let surface: IOSurface

    func makeNSView(context: Context) -> SkySurfaceLayerView { SkySurfaceLayerView() }

    func updateNSView(_ view: SkySurfaceLayerView, context: Context) {
        view.show(surface)
    }
}

/// A view whose layer shows one surface. AppKit never draws into the layer, so its contents stay
/// the surface it was last given.
final class SkySurfaceLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Shows `surface`, letting go of the one before.
    func show(_ surface: IOSurface) {
        guard layer?.contents as? IOSurface !== surface else { return }
        layer?.contents = surface
    }
}
#else
/// Shows a sky surface, stretched to the view's bounds.
private struct SkySurfaceView: UIViewRepresentable {
    let surface: IOSurface

    func makeUIView(context: Context) -> SkySurfaceLayerView { SkySurfaceLayerView() }

    func updateUIView(_ view: SkySurfaceLayerView, context: Context) {
        view.show(surface)
    }
}

/// A view whose layer shows one surface. UIKit never draws into the layer, so its contents stay
/// the surface it was last given.
final class SkySurfaceLayerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.contentsGravity = .resize
        layer.isOpaque = true
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `surface`, letting go of the one before.
    func show(_ surface: IOSurface) {
        guard layer.contents as? IOSurface !== surface else { return }
        layer.contents = surface
    }
}
#endif

/// Draws the sky. Pure function of the canvas size and variant, so the drawing is deterministic.
struct SkyPainter: Sendable, Equatable {
    /// Day or night sky.
    var variant = AeroVariant.day
    /// Tone the decoration down (Increase Contrast).
    var calm = false

    private var decoration: Double { calm ? 0.45 : 1 }

    func paint(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        switch variant {
        case .day: paintDay(in: &context, size: size)
        case .night: paintNight(in: &context, size: size)
        }
    }

    private static let sunOrMoon = UnitPoint(x: 0.14, y: -0.08)

    private func paintDay(in context: inout GraphicsContext, size: CGSize) {
        let sun = point(Self.sunOrMoon, in: size)
        paintDaySky(in: &context, size: size)
        paintMeadowGlow(in: &context, size: size)
        paintSunBloom(in: &context, size: size)
        if !calm { drawRays(from: sun, light: .white, strength: 1, in: &context, size: size) }
        paintHills(in: &context, size: size)
        paintRibbons(Self.ribbons, edge: .white, blur: 1.2, in: &context, size: size)
        paintBokeh(strength: decoration, tint: { _ in .white }, in: &context, size: size)
        paintBubbles(light: .white, strength: 1, in: &context, size: size)
        if !calm { paintSparkles(Self.sparkles, light: .white, in: &context, size: size) }
    }

    /// Nightly Frutiger Aero: the day's composition after dark.
    /// The sun becomes a moon bloom, the hills violet cloud banks with lit crests, the white
    /// ribbons an aqua and violet aurora, and the sparkles four-point stars over a star field.
    private func paintNight(in context: inout GraphicsContext, size: CGSize) {
        let moon = point(Self.sunOrMoon, in: size)
        paintNightSky(in: &context, size: size)
        paintHorizonGlow(in: &context, size: size)
        paintMoonBloom(in: &context, size: size)
        if !calm { drawRays(from: moon, light: NightSky.moonlight, strength: 0.32, in: &context, size: size) }
        for star in Self.stars {
            drawStar(star, in: &context, size: size)
        }
        paintRibbons(Self.auroras, edge: NightSky.moonlight, blur: 2, in: &context, size: size)
        paintBokeh(
            strength: 0.6 * decoration,
            tint: { $0.isMultiple(of: 2) ? NightSky.moonlight : NightSky.violet },
            in: &context, size: size
        )
        paintCloudBanks(in: &context, size: size)
        paintBubbles(light: NightSky.moonlight, strength: 0.75, in: &context, size: size)
        if !calm { paintSparkles(Self.starSparkles, light: NightSky.starlight, in: &context, size: size) }
    }

    private func point(_ unit: UnitPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: unit.x * size.width, y: unit.y * size.height)
    }

    private func fillCanvas(with shading: GraphicsContext.Shading, in context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: shading)
    }

    private func fillGlow(
        _ gradient: Gradient, at center: UnitPoint, reach: CGFloat, in context: inout GraphicsContext, size: CGSize
    ) {
        let radius = max(size.width, size.height) * reach
        fillCanvas(
            with: .radialGradient(gradient, center: point(center, in: size), startRadius: 0, endRadius: radius),
            in: &context, size: size
        )
    }

    private func paintDaySky(in context: inout GraphicsContext, size: CGSize) {
        let gradient = Gradient(stops: [
            .init(color: Aero.sky.top, location: 0),
            .init(color: Aero.sky.top.mix(with: Aero.sky.bottom, by: 0.5), location: 0.48),
            .init(color: Aero.sky.bottom, location: 0.9),
        ])
        let shading = GraphicsContext.Shading.linearGradient(
            gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
        )
        fillCanvas(with: shading, in: &context, size: size)
    }

    private func paintMeadowGlow(in context: inout GraphicsContext, size: CGSize) {
        fillGlow(
            Gradient(colors: [Aero.leaf.opacity(0.30 * decoration), Aero.leaf.opacity(0)]),
            at: UnitPoint(x: 0.02, y: 1.08), reach: 0.5, in: &context, size: size
        )
        fillGlow(
            Gradient(colors: [Aero.aqua.opacity(0.16 * decoration), Aero.aqua.opacity(0)]),
            at: UnitPoint(x: 1.0, y: 1.05), reach: 0.42, in: &context, size: size
        )
    }

    private func paintSunBloom(in context: inout GraphicsContext, size: CGSize) {
        let gradient = Gradient(stops: [
            .init(color: .white.opacity(0.9), location: 0),
            .init(color: .white.opacity(0.35), location: 0.28),
            .init(color: .white.opacity(0), location: 1),
        ])
        fillGlow(gradient, at: Self.sunOrMoon, reach: 0.62, in: &context, size: size)
    }

    private func paintHills(in context: inout GraphicsContext, size: CGSize) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.2))
            for hill in Self.hills {
                drawHill(hill, in: &layer, size: size)
            }
        }
    }

    private func paintRibbons(
        _ ribbons: [Ribbon], edge: Color, blur: CGFloat, in context: inout GraphicsContext, size: CGSize
    ) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: blur))
            for ribbon in ribbons {
                drawRibbon(ribbon, edge: edge, in: &layer, size: size)
            }
        }
    }

    private func paintBokeh(
        strength: Double, tint: (Int) -> Color, in context: inout GraphicsContext, size: CGSize
    ) {
        let side = min(size.width, size.height)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: side * 0.018))
            for (index, disc) in Self.bokeh.enumerated() {
                drawBokehDisc(disc, tint: tint(index), strength: strength, in: &layer, size: size)
            }
        }
    }

    private func drawBokehDisc(
        _ disc: Bubble, tint: Color, strength: Double, in context: inout GraphicsContext, size: CGSize
    ) {
        let r = disc.diameter * min(size.width, size.height) / 2
        let center = CGPoint(x: disc.x * size.width, y: disc.y * size.height)
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let k = disc.opacity * strength
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(stops: [
                .init(color: tint.opacity(k * 0.4), location: 0),
                .init(color: tint.opacity(k), location: 0.92),
                .init(color: tint.opacity(0), location: 1),
            ]),
            center: center, startRadius: 0, endRadius: r
        ))
    }

    private func paintBubbles(light: Color, strength: Double, in context: inout GraphicsContext, size: CGSize) {
        for bubble in Self.bubbles {
            drawBubble(bubble, light: light, strength: strength, in: &context, size: size)
        }
    }

    private func paintCloudBanks(in context: inout GraphicsContext, size: CGSize) {
        for bank in Self.clouds {
            drawClouds(bank, in: &context, size: size)
        }
    }

    private func paintSparkles(_ sparkles: [Bubble], light: Color, in context: inout GraphicsContext, size: CGSize) {
        for sparkle in sparkles {
            drawSparkle(sparkle, light: light, in: &context, size: size)
        }
    }

    private func paintNightSky(in context: inout GraphicsContext, size: CGSize) {
        let gradient = Gradient(stops: [
            .init(color: Aero.sky.top, location: 0),
            .init(color: Aero.sky.top.mix(with: Aero.sky.bottom, by: 0.45), location: 0.5),
            .init(color: Aero.sky.bottom, location: 0.95),
        ])
        let shading = GraphicsContext.Shading.linearGradient(
            gradient,
            startPoint: point(UnitPoint(x: 0.1, y: 0), in: size),
            endPoint: point(UnitPoint(x: 0.4, y: 1), in: size)
        )
        fillCanvas(with: shading, in: &context, size: size)
    }

    private func paintHorizonGlow(in context: inout GraphicsContext, size: CGSize) {
        fillGlow(
            Gradient(colors: [NightSky.violet.opacity(0.42 * decoration), NightSky.violet.opacity(0)]),
            at: UnitPoint(x: 0.92, y: 1.02), reach: 0.6, in: &context, size: size
        )
        fillGlow(
            Gradient(colors: [Aero.aqua.opacity(0.14 * decoration), Aero.aqua.opacity(0)]),
            at: UnitPoint(x: 0.02, y: 1.06), reach: 0.45, in: &context, size: size
        )
    }

    private func paintMoonBloom(in context: inout GraphicsContext, size: CGSize) {
        let gradient = Gradient(stops: [
            .init(color: NightSky.moonlight.opacity(NightSky.moonPeak), location: 0),
            .init(color: NightSky.moonlight.opacity(0.12), location: 0.3),
            .init(color: NightSky.moonlight.opacity(0), location: 1),
        ])
        fillGlow(gradient, at: Self.sunOrMoon, reach: 0.55, in: &context, size: size)
    }

    private func drawStar(_ star: Star, in context: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: star.x * size.width, y: star.y * size.height)
        let k = star.opacity * (calm ? 0.7 : 1)
        if star.radius > 1.2 {
            let halo = star.radius * 4
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - halo, y: c.y - halo, width: halo * 2, height: halo * 2)),
                with: .radialGradient(
                    Gradient(colors: [NightSky.starlight.opacity(0.35 * k), NightSky.starlight.opacity(0)]),
                    center: c, startRadius: 0, endRadius: halo
                )
            )
        }
        let r = star.radius
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
            with: .color(NightSky.starlight.opacity(k))
        )
    }

    /// Wedges of `light` fanning out from `origin` (the sun, or the moon at `strength` < 1).
    private func drawRays(
        from origin: CGPoint, light: Color, strength: Double, in context: inout GraphicsContext, size: CGSize
    ) {
        let w = size.width, h = size.height
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: min(w, h) * 0.014))
            let length = hypot(w, h) * 1.2
            for ray in Self.rays {
                let a0 = Angle.degrees(ray.angle - ray.spread / 2).radians
                let a1 = Angle.degrees(ray.angle + ray.spread / 2).radians
                var wedge = Path()
                wedge.move(to: origin)
                wedge.addLine(to: CGPoint(x: origin.x + cos(a0) * length, y: origin.y + sin(a0) * length))
                wedge.addLine(to: CGPoint(x: origin.x + cos(a1) * length, y: origin.y + sin(a1) * length))
                wedge.closeSubpath()
                layer.fill(wedge, with: .radialGradient(
                    Gradient(colors: [light.opacity(ray.opacity * strength), light.opacity(0)]),
                    center: origin, startRadius: 0, endRadius: length * 0.8
                ))
            }
        }
    }

    /// A cloud bank is a row of overlapping puffs over a floor, swelling towards its peak. It
    /// glows into the sky around it, has a lit crest (brightest on the moon's side) and a body
    /// shaded from its top down, with a soft sheen just under the crest.
    private func drawClouds(_ bank: CloudBank, in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let unit = min(w, h)
        let pattern: [CGFloat] = [1.0, 1.35, 0.9, 1.2, 1.5, 0.95, 1.25, 0.85]
        var puffs = Path()
        var floor = Path()
        var x = -bank.radius * unit
        var index = bank.phase
        var highest = h
        floor.move(to: CGPoint(x: x, y: h + 1))
        while x < w + bank.radius * unit * 2 {
            let r = bank.radius * unit * pattern[index % pattern.count]
            let t = x / w
            let swell = bank.swell * exp(-pow((t - bank.peak) / bank.spread, 2))
            let center = CGPoint(x: x, y: (bank.floor - swell) * h + r * 0.3)
            puffs.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            floor.addLine(to: center)
            highest = min(highest, center.y - r)
            x += r * 1.15
            index += 1
        }
        floor.addLine(to: CGPoint(x: x, y: h + 1))
        floor.closeSubpath()
        let shape = floor.union(puffs)
        let alpha = bank.opacity * (calm ? 0.8 : 1)
        let rim = max(2, unit * 0.006)

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: unit * 0.03))
            layer.fill(shape, with: .color(NightSky.violet.opacity(0.35 * alpha * decoration)))
        }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 1))
            layer.clip(to: shape)
            layer.fill(shape, with: .linearGradient(
                Gradient(colors: [bank.crest.opacity(alpha), bank.crest.mix(with: bank.top, by: 0.55).opacity(alpha)]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: 0)
            ))
            let body = shape.offsetBy(dx: 0, dy: rim)
            let top = CGPoint(x: 0, y: highest), bottom = CGPoint(x: 0, y: h)
            layer.fill(body, with: .linearGradient(
                Gradient(colors: [bank.top.opacity(alpha), bank.bottom.opacity(alpha)]),
                startPoint: top, endPoint: bottom
            ))
            layer.fill(body, with: .linearGradient(
                Gradient(stops: [
                    .init(color: NightSky.moonlight.opacity(0.22 * alpha), location: 0),
                    .init(color: NightSky.moonlight.opacity(0), location: 0.3),
                ]),
                startPoint: top, endPoint: bottom
            ))
        }
    }

    /// A hill is the area under a curve across the canvas, shaded from its crest down, with a
    /// sunlit sheen on the upper slope and a glossy white rim along the crest.
    private func drawHill(_ hill: Hill, in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
        var crest = Path()
        crest.move(to: p(-0.05, hill.crest[0]))
        crest.addCurve(to: p(1.05, hill.crest[3]), control1: p(0.32, hill.crest[1]), control2: p(0.66, hill.crest[2]))
        var body = crest
        body.addLine(to: p(1.05, 1.05))
        body.addLine(to: p(-0.05, 1.05))
        body.closeSubpath()

        let alpha = hill.opacity * decoration
        let top = CGPoint(x: 0, y: hill.crest.min()! * h)
        let bottom = CGPoint(x: 0, y: h)
        context.fill(body, with: .linearGradient(
            Gradient(colors: [hill.top.opacity(alpha), hill.bottom.opacity(alpha * 0.85)]),
            startPoint: top, endPoint: bottom
        ))
        context.fill(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.5 * alpha), location: 0),
                .init(color: .white.opacity(0), location: 0.4),
            ]),
            startPoint: top, endPoint: bottom
        ))
        context.stroke(crest, with: .linearGradient(
            Gradient(colors: [.white.opacity(min(1, alpha * 1.8)), .white.opacity(alpha * 0.5)]),
            startPoint: .zero, endPoint: CGPoint(x: w, y: 0)
        ), lineWidth: 2)
    }

    /// A ribbon is a stack of curves from its top edge to its bottom edge, brightest at the
    /// leading (top) edge and fading towards the trailing one, and faded out at both ends.
    private func drawRibbon(_ ribbon: Ribbon, edge: Color, in context: inout GraphicsContext, size: CGSize) {
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
        context.stroke(curve(at: 0), with: shading(edge, min(1, alpha * 2.6)), lineWidth: 1.5)
    }

    /// A soap bubble lit by `light` (the sun by day, the moon by night), at `strength`.
    private func drawBubble(
        _ bubble: Bubble, light: Color, strength: Double = 1, in context: inout GraphicsContext, size: CGSize
    ) {
        let s = min(size.width, size.height)
        let r = bubble.diameter * s / 2
        let c = CGPoint(x: bubble.x * size.width, y: bubble.y * size.height)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let circle = Path(ellipseIn: rect)
        let k = bubble.opacity * decoration * strength

        context.fill(circle, with: .radialGradient(
            Gradient(stops: [
                .init(color: light.opacity(0), location: 0),
                .init(color: light.opacity(0.06 * k), location: 0.6),
                .init(color: light.opacity(0.28 * k), location: 0.88),
                .init(color: light.opacity(0.6 * k), location: 1),
            ]),
            center: c, startRadius: 0, endRadius: r
        ))
        context.fill(circle, with: .linearGradient(
            Gradient(colors: [Aero.aqua.opacity(0), Aero.aqua.opacity(0.14 * k)]),
            startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)
        ))
        let film = Gradient(colors: [Aero.aquaLight, Aero.leaf, Aero.sun, Aero.coral.mix(with: .white, by: 0.35), Aero.aqua, Aero.aquaLight]
            .map { $0.opacity(0.3 * k) })
        context.stroke(
            Path(ellipseIn: rect.insetBy(dx: r * 0.07, dy: r * 0.07)),
            with: .conicGradient(film, center: c, angle: .degrees(-40)),
            lineWidth: max(1, r * 0.1)
        )
        context.stroke(circle, with: .color(light.opacity(0.55 * k)), lineWidth: max(0.75, r * 0.035))

        let spec = CGRect(x: -r * 0.32, y: -r * 0.17, width: r * 0.64, height: r * 0.34)
        let specPath = Path(ellipseIn: spec).applying(
            CGAffineTransform(rotationAngle: -.pi / 5)
                .concatenating(CGAffineTransform(translationX: c.x - r * 0.4, y: c.y - r * 0.46))
        )
        context.fill(specPath, with: .linearGradient(
            Gradient(colors: [light.opacity(0.95 * k), light.opacity(0.15 * k)]),
            startPoint: CGPoint(x: c.x - r * 0.7, y: c.y - r * 0.8),
            endPoint: CGPoint(x: c.x - r * 0.1, y: c.y - r * 0.2)
        ))

        var crescent = Path()
        crescent.addArc(center: c, radius: r * 0.8, startAngle: .degrees(10), endAngle: .degrees(75), clockwise: false)
        context.stroke(crescent, with: .color(light.opacity(0.5 * k)),
                       style: StrokeStyle(lineWidth: max(1, r * 0.07), lineCap: .round))
    }

    /// A soft glow under a long four-point star of `light`, with a smaller star turned 45° over it.
    private func drawSparkle(_ sparkle: Bubble, light: Color, in context: inout GraphicsContext, size: CGSize) {
        let r = sparkle.diameter * min(size.width, size.height) / 2
        let c = CGPoint(x: sparkle.x * size.width, y: sparkle.y * size.height)
        let k = sparkle.opacity * decoration
        let glow = CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.9, height: r * 0.9)
        context.fill(Path(ellipseIn: glow), with: .radialGradient(
            Gradient(colors: [light.opacity(0.85 * k), light.opacity(0)]),
            center: c, startRadius: 0, endRadius: r * 0.45
        ))
        for (scale, turn, alpha) in [(1.0, 0.0, 1.0), (0.5, Double.pi / 4, 0.6)] {
            let reach = r * scale, waist = reach * 0.11
            var star = Path()
            star.move(to: CGPoint(x: 0, y: -reach))
            star.addLine(to: CGPoint(x: waist, y: -waist))
            star.addLine(to: CGPoint(x: reach, y: 0))
            star.addLine(to: CGPoint(x: waist, y: waist))
            star.addLine(to: CGPoint(x: 0, y: reach))
            star.addLine(to: CGPoint(x: -waist, y: waist))
            star.addLine(to: CGPoint(x: -reach, y: 0))
            star.addLine(to: CGPoint(x: -waist, y: -waist))
            star.closeSubpath()
            let placed = star.applying(
                CGAffineTransform(rotationAngle: turn).concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            )
            context.fill(placed, with: .radialGradient(
                Gradient(colors: [light.opacity(k * alpha), light.opacity(0)]),
                center: c, startRadius: 0, endRadius: reach
            ))
        }
    }

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

    private struct Star: Sendable {
        /// Position in fractions of the canvas, radius in points (stars stay crisp at any size).
        let x: CGFloat, y: CGFloat, radius: CGFloat, opacity: Double
    }

    private struct CloudBank: Sendable {
        /// Y of the bank's floor, in fractions of the height.
        let floor: CGFloat
        /// Typical puff radius, in fractions of the canvas's shorter side.
        let radius: CGFloat
        /// Where the bank rises highest (fraction of the width), how far (fraction of the
        /// height) and over how wide a stretch.
        let peak: CGFloat, swell: CGFloat, spread: CGFloat
        /// Offset into the puff size pattern, so banks do not repeat each other.
        let phase: Int
        /// Crest, top-of-body and bottom colours.
        let crest: Color, top: Color, bottom: Color
        let opacity: Double
    }

    private struct Hill: Sendable {
        /// Y of the crest at x = -0.05, the two control points and x = 1.05.
        let crest: [CGFloat]
        /// Colour at the crest and at the bottom edge.
        let top: Color, bottom: Color
        let opacity: Double
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

    private static let hills: [Hill] = [
        Hill(crest: [0.86, 0.74, 0.90, 0.80], top: Aero.leaf.mix(with: Aero.aqua, by: 0.45),
             bottom: Aero.aquaLight, opacity: 0.30),
        Hill(crest: [0.93, 0.83, 0.86, 0.97], top: Aero.leaf.mix(with: .white, by: 0.15),
             bottom: Aero.leaf, opacity: 0.46),
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

    /// Night: aurora ribbons, aqua above violet, on the day ribbons' sweep.
    private static let auroras: [Ribbon] = [
        Ribbon(top: [0.60, 0.40, 0.84, 0.46], bottom: [0.70, 0.55, 0.95, 0.57], tint: Aero.aqua, opacity: 0.20),
        Ribbon(top: [0.70, 0.52, 0.92, 0.58], bottom: [0.76, 0.60, 0.98, 0.66], tint: NightSky.violet, opacity: 0.34),
        Ribbon(top: [0.78, 0.64, 0.98, 0.70], bottom: [0.84, 0.72, 1.04, 0.76], tint: Aero.aquaLight, opacity: 0.16),
    ]

    /// Night: a dim far bank swelling on the right (as on the icon) and a lit near bank on the left.
    private static let clouds: [CloudBank] = [
        CloudBank(floor: 0.90, radius: 0.075, peak: 0.80, swell: 0.12, spread: 0.32, phase: 3,
                  crest: NightSky.cloudCrest.mix(with: NightSky.cloudTop, by: 0.4),
                  top: NightSky.cloudTop.mix(with: Aero.sky.bottom, by: 0.35), bottom: Aero.sky.bottom,
                  opacity: 0.8),
        CloudBank(floor: 0.97, radius: 0.07, peak: 0.12, swell: 0.12, spread: 0.30, phase: 0,
                  crest: NightSky.cloudCrest, top: NightSky.cloudTop, bottom: NightSky.cloudBottom,
                  opacity: 1),
    ]

    /// Night: a deterministic star field, thinning towards the horizon.
    private static let stars: [Star] = {
        var state: UInt64 = 0x5EED_AE20_0F_C0DE
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        return (0..<110).map { _ in
            Star(
                x: next(),
                y: pow(next(), 1.5) * 0.85,
                radius: 0.5 + pow(next(), 4) * 1.3,
                opacity: 0.35 + next() * 0.6
            )
        }
    }()

    /// Night: four-point stars, the large ones spread like the icon's.
    private static let starSparkles: [Bubble] = [
        Bubble(x: 0.07, y: 0.14, diameter: 0.045, opacity: 0.8),
        Bubble(x: 0.33, y: 0.24, diameter: 0.03, opacity: 0.7),
        Bubble(x: 0.86, y: 0.17, diameter: 0.04, opacity: 0.85),
        Bubble(x: 0.69, y: 0.37, diameter: 0.028, opacity: 0.7),
        Bubble(x: 0.95, y: 0.47, diameter: 0.03, opacity: 0.75),
        Bubble(x: 0.22, y: 0.58, diameter: 0.025, opacity: 0.6),
    ]

    /// Sparkles reuse ``Bubble``: `diameter` is the star's span.
    private static let sparkles: [Bubble] = [
        Bubble(x: 0.27, y: 0.07, diameter: 0.07, opacity: 0.9),
        Bubble(x: 0.47, y: 0.21, diameter: 0.04, opacity: 0.7),
        Bubble(x: 0.085, y: 0.775, diameter: 0.045, opacity: 0.85),
        Bubble(x: 0.71, y: 0.855, diameter: 0.04, opacity: 0.75),
    ]
}

/// Colours of the night sky that are not tokens: the light sources and the clouds.
enum NightSky {
    /// The moon's bloom, beams, ribbon edges and bubble rims: a pale lavender white.
    static let moonlight = Color(hex: 0xE4E0FF)
    /// Stars.
    static let starlight = Color(hex: 0xF6F4FF)
    /// Horizon glow, aurora and the haze around the clouds.
    static let violet = Color(hex: 0x8A5CF0)
    /// Cloud crests (the brightest large surface of the night sky; text only sits on glass over it).
    static let cloudCrest = Color(hex: 0xA295F2)
    /// Top and bottom of the near cloud bank's body.
    static let cloudTop = Color(hex: 0x6C5DD3)
    static let cloudBottom = Color(hex: 0x3A2A86)
    /// Opacity of the moon bloom at its centre, above the top-left corner.
    static let moonPeak = 0.42
}

#Preview("SkyBackground") {
    SkyBackground()
        .frame(width: 900, height: 600)
}

#Preview("SkyBackground: night") {
    SkyBackground()
        .frame(width: 900, height: 600)
        .environment(\.colorScheme, .dark)
}

#Preview("SkyBackground: Increase Contrast") {
    SkyBackground()
        .frame(width: 900, height: 600)
        .environment(\.aeroAccessibilityOverride, .all)
}
