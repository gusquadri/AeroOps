#if os(macOS)
import AppKit
#else
import UIKit
#endif
import QuartzCore
import SwiftUI

/// The water flowing through a gauge's tube: a wave rolls along the filled arc and two streams
/// of bubbles travel toward its tip.
///
/// The motion runs in Core Animation's render server: each part is a cached ring image that
/// turns clockwise and loops, masked to the tube's arc, at 15 fps. Once set up, a gauge costs
/// the app no CPU per frame. With Reduce Motion, and in `ImageRenderer` (which cannot draw
/// platform views), the same images stand still.
struct GaugeWater: Equatable {
    /// The filled share of the ring, `0...1`: the arc the water fills.
    let fraction: Double
    /// Increase Contrast: bolder lines.
    let strong: Bool
}

/// The water's colours, by day and by night. The water lies over the tube's own colours, so it
/// is drawn in light and dark: a lighter band over the wave, a bright crest line with a dark
/// edge, and bubbles with bright rims and dark edges, which read on leaf, aqua, sun and coral.
enum WaterPalette {
    /// The lighter water between the wave and the tube's outer wall.
    static let foam = Color(day: .white.opacity(0.3), night: .white.opacity(0.2))
    /// The crest line, and the rims and highlights of the bubbles.
    static let crest = Color(day: .white.opacity(0.95), night: Color(hex: 0xE4FBFF, opacity: 0.95))
    /// The dark edge inside the crest and around the bubbles.
    static let shade = Color(day: Color(hex: 0x0A4A7A, opacity: 0.35), night: Color(hex: 0x03041C, opacity: 0.5))
}

/// The tube of a gauge `diameter` points across with a ring `lineWidth` points wide, in points.
struct TubeGeometry: Equatable, Sendable {
    let diameter: CGFloat
    let lineWidth: CGFloat

    /// The tube's centre line.
    var radius: CGFloat { diameter / 2 - lineWidth / 2 }
    /// Crests around the whole ring, about one per 2.4 tube widths; whole, so the wave closes.
    var waves: Int { max(3, Int((2 * .pi * radius / (lineWidth * 2.4)).rounded())) }
    /// How far the wave rolls in and out of its mean line.
    var amplitude: CGFloat { lineWidth * 0.16 }
    /// The wave's mean line, a little outside the centre line.
    var waveRadius: CGFloat { radius + lineWidth * 0.08 }

    /// Seconds for the wave, and for each bubble stream, to go once round the ring.
    static let wavePeriod: TimeInterval = 18
    static let bubblePeriods: [TimeInterval] = [11, 16]
}

/// One bubble in a stream.
struct TubeBubble: Equatable, Sendable {
    /// Angle round the ring in radians, counter-clockwise from the right (y up).
    var angle: CGFloat
    /// Distance from the tube's centre line in points, outward positive.
    var offset: CGFloat
    /// Diameter in points.
    var size: CGFloat
}

/// The bubbles of the two streams. The same geometry, stream and seed give the same bubbles.
enum BubbleSchedule {
    /// Tube widths of ring per bubble, and bubble sizes as a share of the tube's width, for
    /// the fast stream of larger bubbles and the slow one of smaller bubbles.
    static let spacing: [CGFloat] = [3.2, 4.4]
    static let sizes: [ClosedRange<Double>] = [0.34...0.48, 0.24...0.34]

    static func make(_ geometry: TubeGeometry, stream: Int, seed: UInt64 = 1) -> [TubeBubble] {
        var random = SplitMix64(seed: seed &+ UInt64(stream) &* 0x9E37_79B9)
        let width = geometry.lineWidth
        let count = max(2, Int(2 * .pi * geometry.radius / (width * spacing[stream])))
        let slot = 2 * Double.pi / Double(count)
        return (0..<count).map { index in
            let size = width * CGFloat(random.unit(in: sizes[stream]))
            let room = max(0, (width - size) / 2 - width * 0.12)
            return TubeBubble(
                angle: CGFloat(slot * (Double(index) + random.unit(in: 0.15...0.85))),
                offset: CGFloat(random.unit(in: -1...1)) * room,
                size: size
            )
        }
    }
}

/// SplitMix64: small, fast and the same on every run for a seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in `range`.
    mutating func unit(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}

/// The cached images of the water for one look: the wave ring and the two bubble streams, each
/// a full ring the size of the gauge. Every gauge with the same look, size and scale shares
/// them, so Core Animation keeps one copy of each.
@MainActor
final class WaterArt {
    struct Key: Hashable {
        let variant: AeroVariant
        let strong: Bool
        /// The gauge's diameter and the ring's width, in pixels.
        let pixels: Int
        let line: Int
        let scale: CGFloat
    }

    let geometry: TubeGeometry
    let scale: CGFloat
    let wave: CGImage
    let streams: [CGImage]

    private static var cache: [Key: WaterArt] = [:]

    static func key(variant: AeroVariant, strong: Bool, diameter: CGFloat, lineWidth: CGFloat, scale: CGFloat) -> Key {
        Key(
            variant: variant, strong: strong, pixels: Int((diameter * scale).rounded()),
            line: Int((lineWidth * scale).rounded()), scale: scale
        )
    }

    /// The art for a look, drawn on first use.
    static func art(variant: AeroVariant, strong: Bool, diameter: CGFloat, lineWidth: CGFloat, scale: CGFloat) -> WaterArt? {
        let key = key(variant: variant, strong: strong, diameter: diameter, lineWidth: lineWidth, scale: scale)
        if let art = cache[key] { return art }
        guard let art = WaterArt(key: key) else { return nil }
        cache[key] = art
        return art
    }

    private init?(key: Key) {
        guard key.scale > 0, key.line > 0, key.pixels > key.line * 2 else { return nil }
        var environment = EnvironmentValues()
        environment.colorScheme = key.variant == .night ? .dark : .light
        func cg(_ color: Color) -> CGColor { color.resolve(in: environment).cgColor }

        let geometry = TubeGeometry(diameter: CGFloat(key.pixels) / key.scale, lineWidth: CGFloat(key.line) / key.scale)
        let line = max(1, geometry.lineWidth * 0.11) * (key.strong ? 1.5 : 1)
        let (foam, crest, shade) = (cg(WaterPalette.foam), cg(WaterPalette.crest), cg(WaterPalette.shade))
        guard let wave = Self.wave(geometry, scale: key.scale, foam: foam, crest: crest, shade: shade, line: line)
        else { return nil }
        let streams = (0..<TubeGeometry.bubblePeriods.count).compactMap { stream in
            Self.stream(
                geometry, bubbles: BubbleSchedule.make(geometry, stream: stream), scale: key.scale,
                crest: crest, shade: shade, strong: key.strong
            )
        }
        guard streams.count == TubeGeometry.bubblePeriods.count else { return nil }
        self.geometry = geometry
        self.scale = key.scale
        self.wave = wave
        self.streams = streams
    }

    /// The wave: a crest line rolling in and out round the tube, lighter water outside it and a
    /// dark edge inside it.
    private static func wave(
        _ geometry: TubeGeometry, scale: CGFloat, foam: CGColor, crest: CGColor, shade: CGColor, line: CGFloat
    ) -> CGImage? {
        draw(geometry, scale: scale) { context, center in
            func ring(_ inset: CGFloat) -> CGPath {
                let path = CGMutablePath()
                let steps = geometry.waves * 32
                for step in 0...steps {
                    let theta = 2 * CGFloat.pi * CGFloat(step) / CGFloat(steps)
                    let r = geometry.waveRadius - inset + geometry.amplitude * sin(CGFloat(geometry.waves) * theta)
                    let point = CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                return path
            }
            let crestLine = ring(0)
            let outer = geometry.diameter / 2 + 1
            context.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            context.addPath(crestLine)
            context.setFillColor(foam)
            context.fillPath(using: .evenOdd)

            context.setLineWidth(line)
            context.addPath(ring(line * 0.9))
            context.setStrokeColor(shade)
            context.strokePath()
            context.addPath(crestLine)
            context.setStrokeColor(crest)
            context.strokePath()
        }
    }

    /// A stream of bubbles: a faint fill, a bright rim with a dark edge, and a highlight toward
    /// the tube's outer wall, where its glass highlight runs.
    private static func stream(
        _ geometry: TubeGeometry, bubbles: [TubeBubble], scale: CGFloat, crest: CGColor, shade: CGColor, strong: Bool
    ) -> CGImage? {
        draw(geometry, scale: scale) { context, center in
            for bubble in bubbles {
                let r = geometry.radius + bubble.offset
                let (dx, dy) = (cos(bubble.angle), sin(bubble.angle))
                let middle = CGPoint(x: center.x + r * dx, y: center.y + r * dy)
                let rim = max(0.8, bubble.size * 0.15) * (strong ? 1.3 : 1)
                let circle = CGRect(
                    x: middle.x - bubble.size / 2, y: middle.y - bubble.size / 2, width: bubble.size, height: bubble.size
                ).insetBy(dx: rim / 2, dy: rim / 2)
                context.setLineWidth(rim)
                context.setStrokeColor(shade)
                context.strokeEllipse(in: circle.insetBy(dx: -rim, dy: -rim))
                context.setFillColor(crest.copy(alpha: crest.alpha * 0.28) ?? crest)
                context.fillEllipse(in: circle)
                context.setStrokeColor(crest)
                context.strokeEllipse(in: circle)
                let shine = bubble.size * 0.26
                let glint = CGPoint(x: middle.x + dx * bubble.size * 0.2, y: middle.y + dy * bubble.size * 0.2)
                context.setFillColor(crest)
                context.fillEllipse(in: CGRect(x: glint.x - shine / 2, y: glint.y - shine / 2, width: shine, height: shine))
            }
        }
    }

    /// A gauge-sized image clipped to the tube's ring.
    private static func draw(
        _ geometry: TubeGeometry, scale: CGFloat, _ body: (CGContext, CGPoint) -> Void
    ) -> CGImage? {
        let side = Int((geometry.diameter * scale).rounded(.up))
        guard side > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        let center = CGPoint(x: geometry.diameter / 2, y: geometry.diameter / 2)
        let (outer, inner) = (geometry.radius + geometry.lineWidth / 2, geometry.radius - geometry.lineWidth / 2)
        context.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        context.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        context.clip(using: .evenOdd)
        body(context, center)
        return context.makeImage()
    }
}

/// The water for a gauge's tube: live, or still with Reduce Motion and in render tests. Its
/// frame is the gauge's ring, `diameter` points across.
struct GaugeWaterView: View {
    let water: GaugeWater
    let lineWidth: CGFloat
    let diameter: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.aeroAnimatedWater) private var animated
    private var accessibility = AeroAccessibility()

    init(water: GaugeWater, lineWidth: CGFloat, diameter: CGFloat) {
        self.water = water
        self.lineWidth = lineWidth
        self.diameter = diameter
    }

    var body: some View {
        let variant = AeroVariant(colorScheme)
        Group {
            if animated && !accessibility.reduceMotion {
                LiveWater(water: water, lineWidth: lineWidth, variant: variant)
            } else {
                StillWater(water: water, variant: variant, lineWidth: lineWidth, diameter: diameter, scale: displayScale)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Still water: the live water's rings, posed, masked to the tube's arc. The mask is the
/// tube's own shape, so it follows the tube when the value animates.
private struct StillWater: View {
    let water: GaugeWater
    let variant: AeroVariant
    let lineWidth: CGFloat
    let diameter: CGFloat
    let scale: CGFloat

    var body: some View {
        if let art = WaterArt.art(
            variant: variant, strong: water.strong, diameter: diameter, lineWidth: lineWidth, scale: scale
        ) {
            ZStack {
                Image(decorative: art.wave, scale: art.scale)
                    .rotationEffect(.degrees(25))
                ForEach(Array(art.streams.enumerated()), id: \.offset) { index, stream in
                    Image(decorative: stream, scale: art.scale)
                        .rotationEffect(.degrees(70 + 140 * Double(index)))
                }
            }
            .frame(width: diameter, height: diameter)
            .mask {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: water.fraction)
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

/// Live water: a Core Animation layer tree driven by the render server.
private struct LiveWater {
    let water: GaugeWater
    let lineWidth: CGFloat
    let variant: AeroVariant

    func update(_ view: WaterView, _ transaction: Transaction) {
        view.show(
            water, lineWidth: lineWidth, variant: variant,
            animated: transaction.animation != nil && !transaction.disablesAnimations
        )
    }
}

#if os(macOS)
typealias WaterHostView = NSView

extension LiveWater: NSViewRepresentable {
    func makeNSView(context: Context) -> WaterView { WaterView() }
    func updateNSView(_ view: WaterView, context: Context) { update(view, context.transaction) }
}
#else
typealias WaterHostView = UIView

extension LiveWater: UIViewRepresentable {
    func makeUIView(context: Context) -> WaterView { WaterView() }
    func updateUIView(_ view: WaterView, context: Context) { update(view, context.transaction) }
}
#endif

/// The live water's layers:
///
/// ```
/// root (the gauge's ring)
///   content (masked by the tube: an arc from the top, clockwise, to the value)
///     wave, bubble streams (gauge-sized rings turning clockwise)
/// ```
///
/// The rings turn only while the view is on screen and Low Power Mode is off.
final class WaterView: WaterHostView {
    private(set) var water: GaugeWater?
    private(set) var variant: AeroVariant = .day
    private(set) var lineWidth: CGFloat = 0
    private(set) var art: WaterArt?
    /// Whether the rings are turning.
    private(set) var isMoving = false

    let content = CALayer()
    let tube = CAShapeLayer()
    let waveLayer = CALayer()
    let streamLayers = TubeGeometry.bubblePeriods.map { _ in CALayer() }

    /// The rings' turning. The window server composites the window once per frame however many
    /// gauges move, so the frame rate sets the cost; slow water still reads smooth at 15 fps.
    static let frameRate = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
    /// The arc's glide to a new value: the ring's spring.
    static let glide: TimeInterval = 0.6

    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        tube.fillColor = nil
        tube.strokeColor = CGColor(gray: 0, alpha: 1)
        tube.lineCap = .round
        tube.strokeEnd = 0
        content.mask = tube
        for ring in [waveLayer] + streamLayers {
            content.addSublayer(ring)
        }
        hostContent()
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `water` in a ring `lineWidth` wide. `animated` glides the arc to a new value.
    func show(_ water: GaugeWater, lineWidth: CGFloat, variant: AeroVariant, animated: Bool) {
        guard water != self.water || variant != self.variant || lineWidth != self.lineWidth else { return }
        let previous = self.water
        self.water = water
        self.variant = variant
        self.lineWidth = lineWidth
        apply(glide: animated && previous != nil && previous?.fraction != water.fraction)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Follows what starts and stops the rings in the current window, then lays out for it.
    private func windowChanged() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMotion() }
        }
        observers = motionSignals.map { signal in
            NotificationCenter.default.addObserver(forName: signal.name, object: signal.object, queue: .main, using: refresh)
        }
        apply(glide: false)
    }

    /// Whether the water should move: on screen, Low Power Mode off.
    private var shouldMove: Bool {
        isOnScreen && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Lays out the layers for the current water, size and scale; draws new art if needed.
    private func apply(glide: Bool) {
        guard let water else { return }
        let diameter = min(bounds.width, bounds.height)
        guard let art = WaterArt.art(
            variant: variant, strong: water.strong, diameter: diameter, lineWidth: lineWidth, scale: displayScale
        ) else { return }
        self.art = art

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layOut(art, diameter: diameter)
        fill(to: CGFloat(min(max(water.fraction, 0), 1)), glide: glide)
        CATransaction.commit()

        setMoving(shouldMove)
    }

    /// The mask is the tube's exact shape; the art is drawn on whole pixels.
    private func layOut(_ art: WaterArt, diameter: CGFloat) {
        let geometry = TubeGeometry(diameter: diameter, lineWidth: lineWidth)
        let square = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let center = CGPoint(x: square.midX, y: square.midY)
        content.frame = square.offsetBy(dx: (bounds.width - diameter) / 2, dy: (bounds.height - diameter) / 2)
        tube.frame = square
        tube.lineWidth = lineWidth
        let top = -Self.clockwise * .pi / 2
        let path = CGMutablePath()
        path.addArc(
            center: center, radius: geometry.radius, startAngle: top, endAngle: top + Self.clockwise * 2 * .pi,
            clockwise: Self.clockwise < 0
        )
        tube.path = path
        let side = art.geometry.diameter
        for (ring, image) in zip([waveLayer] + streamLayers, [art.wave] + art.streams) {
            ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            ring.position = center
            ring.contents = image
            ring.contentsScale = displayScale
        }
    }

    /// Moves the arc's tip to `target`.
    private func fill(to target: CGFloat, glide: Bool) {
        let from = tube.presentation()?.strokeEnd ?? tube.strokeEnd
        tube.strokeEnd = target
        guard glide, abs(from - target) > 0.0001, shouldMove else {
            tube.removeAnimation(forKey: "glide")
            return
        }
        let animation = CASpringAnimation(perceptualDuration: Self.glide, bounce: 0)
        animation.keyPath = "strokeEnd"
        animation.fromValue = from
        animation.toValue = target
        animation.duration = animation.settlingDuration
        tube.add(animation, forKey: "glide")
    }

    private func refreshMotion() { setMoving(shouldMove) }

    /// Starts or stops the rings. Each gauge starts them at its own random point, so gauges
    /// side by side do not move in step.
    func setMoving(_ moving: Bool) {
        guard moving != isMoving, art != nil else { return }
        isMoving = moving
        let rings = [(waveLayer, TubeGeometry.wavePeriod)] + Array(zip(streamLayers, TubeGeometry.bubblePeriods))
        for (ring, _) in rings { ring.removeAnimation(forKey: "flow") }
        guard moving else { return }
        var random = SplitMix64(seed: UInt64.random(in: .min ... .max))
        for (ring, period) in rings {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = Self.clockwise * 2 * CGFloat.pi
            animation.duration = period
            animation.repeatCount = .infinity
            animation.timeOffset = random.unit(in: 0...period)
            animation.preferredFrameRateRange = Self.frameRate
            ring.add(animation, forKey: "flow")
        }
    }

    #if os(macOS)
    /// The sign of a clockwise angle: layers on the Mac have y up.
    private static let clockwise: CGFloat = -1

    private var displayScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private var isOnScreen: Bool { window?.occlusionState.contains(.visible) ?? false }

    private var motionSignals: [(name: Notification.Name, object: AnyObject?)] {
        guard let window else { return [] }
        return [(NSWindow.didChangeOcclusionStateNotification, window), (.NSProcessInfoPowerStateDidChange, nil)]
    }

    private func hostContent() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(content)
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        apply(glide: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply(glide: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged()
    }
    #else
    /// The sign of a clockwise angle: layers on iOS have y down.
    private static let clockwise: CGFloat = 1

    private var displayScale: CGFloat { traitCollection.displayScale }

    /// iOS drops layer animations in the background, so the rings stop there and start again
    /// when the scene comes back.
    private var isOnScreen: Bool {
        guard let state = window?.windowScene?.activationState else { return false }
        return state == .foregroundActive || state == .foregroundInactive
    }

    private var motionSignals: [(name: Notification.Name, object: AnyObject?)] {
        guard let scene = window?.windowScene else { return [] }
        return [
            (UIScene.didActivateNotification, scene),
            (UIScene.didEnterBackgroundNotification, scene),
            (.NSProcessInfoPowerStateDidChange, nil),
        ]
    }

    private func hostContent() {
        isUserInteractionEnabled = false
        layer.addSublayer(content)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard content.bounds.size != bounds.size else { return }
        apply(glide: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        windowChanged()
    }
    #endif
}
