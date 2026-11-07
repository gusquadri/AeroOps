import AppKit
import SwiftUI
import Testing
@testable import AeroTheme

@Suite("Gauge water")
@MainActor
struct GaugeWaterTests {
    @Test("the tube's centre line, wave and crests", arguments: [24.0, 40.08, 64, 97.5])
    func geometry(diameter: CGFloat) {
        let lineWidth = max(6, diameter * 0.14)
        let geometry = TubeGeometry(diameter: diameter, lineWidth: lineWidth)
        #expect(geometry.radius == diameter / 2 - lineWidth / 2)
        #expect(geometry.waves >= 3)
        let spacing = 2 * .pi * geometry.radius / CGFloat(geometry.waves) / lineWidth
        #expect(geometry.waves == 3 || (1.8...3.2).contains(spacing))
        let half = lineWidth / 2
        #expect(geometry.waveRadius + geometry.amplitude < geometry.radius + half)
        #expect(geometry.waveRadius - geometry.amplitude > geometry.radius - half)
    }

    @Test("bubbles: the same seed gives the same bubbles, spread round the tube and inside it", arguments: [0, 1])
    func bubbles(stream: Int) {
        let geometry = TubeGeometry(diameter: 64, lineWidth: 8.96)
        let a = BubbleSchedule.make(geometry, stream: stream, seed: 7)
        #expect(a == BubbleSchedule.make(geometry, stream: stream, seed: 7))
        #expect(a != BubbleSchedule.make(geometry, stream: stream, seed: 8))
        #expect(a != BubbleSchedule.make(geometry, stream: 1 - stream, seed: 7))
        #expect(a.count >= 2)
        let width = geometry.lineWidth
        let sizes = BubbleSchedule.sizes[stream]
        for bubble in a {
            #expect((0..<(2 * .pi)).contains(bubble.angle))
            #expect(sizes.contains(Double(bubble.size / width)))
            #expect(abs(bubble.offset) + bubble.size / 2 <= width / 2 - width * 0.12 + 0.0001)
        }
        #expect(a.map(\.angle) == a.map(\.angle).sorted())
        let angles = a.map(\.angle) + [a[0].angle + 2 * .pi]
        for (index, gap) in zip(angles, angles.dropFirst()).map({ $1 - $0 }).enumerated() {
            let neighbours = a[index].size / 2 + a[(index + 1) % a.count].size / 2
            #expect(gap * geometry.radius > neighbours, "bubbles \(index) and \(index + 1)")
        }
    }

    @Test("art is drawn once per look and shared", arguments: AeroVariant.allCases)
    func artCache(variant: AeroVariant) throws {
        let art = try #require(WaterArt.art(variant: variant, strong: false, diameter: 64, lineWidth: 9, scale: 2))
        #expect(WaterArt.art(variant: variant, strong: false, diameter: 64, lineWidth: 9, scale: 2) === art)
        #expect(WaterArt.art(variant: variant, strong: true, diameter: 64, lineWidth: 9, scale: 2) !== art)
        #expect(WaterArt.art(variant: variant, strong: false, diameter: 64, lineWidth: 9, scale: 1) !== art)
        #expect(WaterArt.art(variant: variant, strong: false, diameter: 40, lineWidth: 6, scale: 2) !== art)
        #expect(art.streams.count == TubeGeometry.bubblePeriods.count)
        for image in [art.wave] + art.streams {
            #expect(image.width == 128 && image.height == 128)
        }
        #expect(WaterArt.art(variant: variant, strong: false, diameter: 0, lineWidth: 9, scale: 2) == nil)
        #expect(WaterArt.art(variant: variant, strong: false, diameter: 64, lineWidth: 0, scale: 2) == nil)
    }

    @Test("the art lies only in the tube, and the wave goes all the way round", arguments: AeroVariant.allCases)
    func artInTube(variant: AeroVariant) throws {
        let art = try #require(WaterArt.art(variant: variant, strong: false, diameter: 64, lineWidth: 9, scale: 2))
        let geometry = art.geometry
        let (inner, outer) = ((geometry.radius - geometry.lineWidth / 2) * 2, (geometry.radius + geometry.lineWidth / 2) * 2)
        for image in [art.wave] + art.streams {
            let pixels = try #require(Pixels(image))
            var inked = 0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let distance = hypot(CGFloat(x) + 0.5 - 64, CGFloat(y) + 0.5 - 64)
                    let alpha = pixels[x, y][3]
                    if distance < inner - 1.5 || distance > outer + 1.5 {
                        #expect(alpha == 0, "\(x),\(y) outside the tube")
                    } else if alpha > 0 {
                        inked += 1
                    }
                }
            }
            #expect(inked > 100)
        }
        let pixels = try #require(Pixels(art.wave))
        for step in 0..<36 {
            let theta = CGFloat(step) * .pi / 18
            let r = outer - 2
            #expect(pixels[Int(64 + r * cos(theta)), Int(64 + r * sin(theta))][3] > 20, "at \(step * 10)°")
        }
    }

    @Test("the live view masks the water to the tube's arc and moves only on screen")
    func liveView() throws {
        let view = WaterView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        view.show(GaugeWater(fraction: 0.4, strong: false), lineWidth: 9, variant: .night, animated: false)
        #expect(view.content.mask === view.tube)
        #expect(view.tube.strokeEnd == 0.4)
        #expect(view.tube.lineWidth == 9)
        #expect(view.tube.lineCap == .round)
        #expect(view.tube.fillColor == nil)
        let end = try #require(view.tube.path?.currentPoint)
        #expect(abs(end.x - 32) < 0.001 && abs(end.y - (64 - 4.5)) < 0.001)
        #expect(view.waveLayer.contents != nil)
        #expect(view.streamLayers.count == TubeGeometry.bubblePeriods.count)
        #expect(view.streamLayers.allSatisfy { $0.contents != nil && $0.position == CGPoint(x: 32, y: 32) })
        #expect(!view.isMoving)
        #expect(view.waveLayer.animationKeys() == nil)

        view.setMoving(true)
        #expect(view.isMoving)
        let rings = [view.waveLayer] + view.streamLayers
        let periods = [TubeGeometry.wavePeriod] + TubeGeometry.bubblePeriods
        for (ring, period) in zip(rings, periods) {
            let flow = try #require(ring.animation(forKey: "flow") as? CABasicAnimation)
            #expect(flow.keyPath == "transform.rotation.z")
            #expect((flow.toValue as? CGFloat) == -2 * .pi)
            #expect(flow.duration == period)
            #expect(flow.repeatCount == .infinity)
            #expect(flow.preferredFrameRateRange == WaterView.frameRate)
        }
        #expect(WaterView.frameRate.maximum <= 15)

        view.setMoving(false)
        #expect(rings.allSatisfy { $0.animationKeys() == nil })

        view.show(GaugeWater(fraction: 0.9, strong: false), lineWidth: 9, variant: .night, animated: true)
        #expect(view.tube.strokeEnd == 0.9)
        #expect(view.tube.animation(forKey: "glide") == nil)
        let art = view.art
        view.show(GaugeWater(fraction: 0.9, strong: true), lineWidth: 9, variant: .night, animated: false)
        #expect(view.art !== art)
        #expect(view.hitTest(CGPoint(x: 32, y: 32)) == nil)
    }

    @Test("the gauge builds with its water")
    func gauge() {
        _ = GlossyGauge(value: 0.42, label: "CPU").body
        _ = GaugeBubble(inset: 4).body
        _ = GaugeWaterView(water: GaugeWater(fraction: 1, strong: true), lineWidth: 9, diameter: 64).body
    }

    @Test("still water renders in ImageRenderer, only along the arc", arguments: AeroVariant.allCases)
    func stillWater(variant: AeroVariant) throws {
        let view = GaugeWaterView(water: GaugeWater(fraction: 0.5, strong: false), lineWidth: 9, diameter: 64)
            .environment(\.aeroAnimatedWater, false)
            .environment(\.colorScheme, variant == .night ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 128)
        let pixels = try #require(Pixels(image))
        #expect(pixels[126, 64][3] > 20, "the tube at 3 o'clock")
        #expect(pixels[1, 64][3] == 0, "the tube at 9 o'clock, past the tip")
        #expect(pixels[64, 64][3] == 0, "the bubble")
        #expect(pixels[2, 2][3] == 0, "outside the ring")
    }
}

/// RGBA bytes of an image, row 0 at the top.
private struct Pixels {
    let width: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }

    subscript(x: Int, y: Int) -> [UInt8] {
        let start = (y * width + x) * 4
        return Array(bytes[start..<start + 4])
    }
}
