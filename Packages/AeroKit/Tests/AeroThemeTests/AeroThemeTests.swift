import IOSurface
import SwiftUI
import Testing
@testable import AeroTheme

@Suite("AeroTheme")
@MainActor
struct AeroThemeTests {
    @Test("tokens match the plan's starting values by day")
    func tokens() {
        #expect(Aero.radius.card == 18)
        #expect(Aero.shadow.card.y == 6)
        #expect(Aero.shadow.card.blur == 18)
        let day = EnvironmentValues.aero(.day)
        func same(_ token: Color, _ expected: Color) -> Bool {
            let (a, b) = (token.resolve(in: day), expected.resolve(in: day))
            return [a.red - b.red, a.green - b.green, a.blue - b.blue, a.opacity - b.opacity]
                .allSatisfy { abs($0) < 0.001 }
        }
        #expect(same(Aero.aqua, Color(hex: 0x1BA6E8)))
        #expect(same(Aero.leaf, Color(hex: 0x6CCB4F)))
        #expect(same(Aero.sun, Color(hex: 0xFFC83D)))
        #expect(same(Aero.coral, Color(hex: 0xF2605A)))
        #expect(same(Aero.sky.top, Color(hex: 0x5BC8F5)))
        #expect(same(Aero.sky.bottom, Color(hex: 0xE9F8FF)))
        #expect(same(Aero.glass.fill, .white.opacity(0.55)))
        #expect(same(Aero.glass.rimTop, .white.opacity(0.8)))
        #expect(same(Aero.glass.rimBottom, .white.opacity(0.2)))
        #expect(same(Aero.shadow.card.color, Color(hex: 0x0A4A7A).opacity(0.18)))
    }

    @Test("every colour token changes by night, except the white label colour")
    func nightTokens() {
        let day = EnvironmentValues.aero(.day), night = EnvironmentValues.aero(.night)
        let tokens: [(String, Color)] = [
            ("sky.top", Aero.sky.top), ("sky.bottom", Aero.sky.bottom), ("aqua", Aero.aqua),
            ("aquaDeep", Aero.aquaDeep), ("leaf", Aero.leaf), ("sun", Aero.sun), ("coral", Aero.coral),
            ("neutral", Aero.neutral), ("text.primary", Aero.text.primary),
            ("text.secondary", Aero.text.secondary), ("glass.fill", Aero.glass.fill),
            ("glass.rimTop", Aero.glass.rimTop), ("glass.rimBottom", Aero.glass.rimBottom),
            ("glass.solidFill", Aero.glass.solidFill), ("glass.rimStrong", Aero.glass.rimStrong),
            ("shadow.card", Aero.shadow.card.color), ("shadow.control", Aero.shadow.control.color),
        ]
        for (name, token) in tokens {
            #expect(token.resolve(in: day) != token.resolve(in: night), "\(name) is the same by night")
        }
        #expect(Aero.text.onAccent.resolve(in: day) == Aero.text.onAccent.resolve(in: night))
        #expect(Aero.text.onBright.resolve(in: day) == Aero.text.onBright.resolve(in: night))
        #expect(RGB(Aero.text.primary, .night).luminance > RGB(Aero.sky.top, .night).luminance)
        #expect(RGB(Aero.sky.top, .night).luminance < 0.02)
    }

    @Test("variants follow the colour scheme and the AppKit appearance")
    func variants() throws {
        #expect(AeroVariant(ColorScheme.light) == .day)
        #expect(AeroVariant(ColorScheme.dark) == .night)
        #expect(AeroVariant(try #require(NSAppearance(named: .aqua))) == .day)
        #expect(AeroVariant(try #require(NSAppearance(named: .darkAqua))) == .night)
        #expect(AeroVariant(try #require(NSAppearance(named: .vibrantDark))) == .night)
        #expect(AeroVariant(try #require(NSAppearance(named: .accessibilityHighContrastDarkAqua))) == .night)
        #expect(AeroVariant(try #require(NSAppearance(named: .accessibilityHighContrastAqua))) == .day)
        #expect(AeroVariant.night.title == "Nightly Frutiger Aero")
        #expect(AeroVariant.day.title == "Frutiger Aero")
    }

    @Test("AppKit resolves the tokens against the view's appearance")
    func appKitResolution() throws {
        let color = NSColor(Aero.text.primary)
        func srgb(_ name: NSAppearance.Name) throws -> NSColor {
            var resolved: NSColor?
            try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            return try #require(resolved)
        }
        #expect(try srgb(.aqua).redComponent < 0.1)
        #expect(try srgb(.darkAqua).redComponent > 0.9)
    }

    @Test("fonts: rounded for text, SF Mono at the same text style sizes for code-like text")
    func fonts() {
        #expect(Aero.font(.callout) == .system(.callout, design: .rounded, weight: .regular))
        #expect(Aero.monospacedFont(.callout) != Aero.font(.callout))
        for style in Font.TextStyle.allCases {
            let mono = Aero.monospacedNSFont(style.appKit)
            #expect(mono.isFixedPitch)
            #expect(mono.pointSize == NSFont.preferredFont(forTextStyle: style.appKit).pointSize)
        }
        #expect(Font.TextStyle.caption.appKit == .caption1)
        #expect(Font.TextStyle.title.appKit == .title1)
        #expect(Font.TextStyle.callout.appKit == .callout)
        #expect(Font.Weight.regular.appKit == .regular)
        #expect(Font.Weight.semibold.appKit == .semibold)
    }

    @Test("every orb tone has a distinct colour")
    func orbTones() {
        let colors = OrbTone.allCases.map(\.color)
        #expect(Set(colors.map(\.description)).count == OrbTone.allCases.count)
        #expect(OrbTone.healthy.color == Aero.leaf)
        #expect(OrbTone.warning.color == Aero.sun)
        #expect(OrbTone.error.color == Aero.coral)
        #expect(OrbTone.neutral.color == Aero.neutral)
    }

    @Test("gauge text: percent, clamped, or a dash for no data")
    func gaugeFormatting() {
        #expect(GlossyGauge.formatted(nil) == GlossyGauge.placeholder)
        #expect(GlossyGauge.formatted(.nan) == GlossyGauge.placeholder)
        #expect(GlossyGauge.formatted(0) == "0%")
        #expect(GlossyGauge.formatted(0.423) == "42%")
        #expect(GlossyGauge.formatted(1.7) == "100%")
        #expect(GlossyGauge.formatted(-0.2) == "0%")
    }

    @Test("gauge animation key: the shown whole percentage")
    func gaugePercent() {
        #expect(GlossyGauge.percent(nil) == nil)
        #expect(GlossyGauge.percent(.nan) == nil)
        #expect(GlossyGauge.percent(0.423) == 42)
        #expect(GlossyGauge.percent(0.4249) == GlossyGauge.percent(0.4151))
        #expect(GlossyGauge.percent(0.425) == 43)
        #expect(GlossyGauge.percent(1.7) == 100)
        #expect(GlossyGauge.percent(-0.2) == 0)
    }

    @Test("gauge spring ends once less than 0.1% of the change is left")
    func gaugeSpringCutoff() {
        let settling = SettlingSpring(duration: 0.6, remaining: 0.001)
        let left = { (time: Double) in 1 - settling.spring.value(target: 1.0, time: time) }
        #expect(settling.spring == Spring(duration: 0.6, bounce: 0))
        #expect(left(settling.cutoff) < 0.001)
        #expect(left(settling.cutoff - 0.05) > 0.001)
        #expect((0.8...1.0).contains(settling.cutoff))
    }

    @Test("gauge colour band follows the thresholds", arguments: [
        (nil, GlossyGauge.Level.none),
        (Double.nan, .none),
        (0, .normal),
        (0.5, .normal),
        (0.799, .normal),
        (0.8, .warning),
        (0.949, .warning),
        (0.95, .critical),
        (1.4, .critical),
    ] as [(Double?, GlossyGauge.Level)])
    func gaugeLevels(value: Double?, expected: GlossyGauge.Level) {
        #expect(GlossyGauge.level(for: value, warning: 0.8, critical: 0.95) == expected)
    }

    @Test("gauge thresholds are configurable")
    func gaugeCustomThresholds() {
        #expect(GlossyGauge.level(for: 0.65, warning: 0.6, critical: 0.9) == .warning)
        #expect(GlossyGauge.level(for: 0.9, warning: 0.6, critical: 0.9) == .critical)
        #expect(GlossyGauge.level(for: 0.59, warning: 0.6, critical: 0.9) == .normal)
        let gauge = GlossyGauge(value: 0.5, label: "Disk", warningThreshold: 0.6, criticalThreshold: 0.9)
        #expect(gauge.warningThreshold == 0.6)
        #expect(gauge.criticalThreshold == 0.9)
        let defaults = GlossyGauge(value: 0.5, label: "CPU")
        #expect(defaults.warningThreshold == 0.8)
        #expect(defaults.criticalThreshold == 0.95)
    }

    @Test("gauge level colours: leaf to aqua, leaf to sun, sun to coral")
    func gaugeLevelColours() {
        #expect(GlossyGauge.Level.normal.colors == [Aero.leaf, Aero.aqua])
        #expect(GlossyGauge.Level.warning.colors == [Aero.leaf, Aero.sun])
        #expect(GlossyGauge.Level.critical.colors == [Aero.sun, Aero.coral])
    }

    @Test("button styles: .aqua is primary, .aquaSecondary is secondary")
    func buttonStyles() {
        #expect(AquaButtonStyle.aqua.prominence == .primary)
        #expect(AquaButtonStyle.aquaSecondary.prominence == .secondary)
        #expect(AquaButtonStyle().prominence == .primary)
    }

    @Test("components build their bodies")
    func componentsInstantiate() {
        _ = AeroCard { Text("x") }.body
        _ = GlossyGauge(value: nil, label: "CPU").body
        _ = GlossyGauge(value: 0.97, label: "CPU", diameter: 80).body
        _ = StatusOrb(tone: .warning).body
        _ = SkyBackground().body
        _ = AeroThemeShowcase(variant: .night).body
        _ = Button("Go") {}.buttonStyle(.aqua)
        _ = Button("Go") {}.buttonStyle(.aquaSecondary)
        _ = AeroTag("prod").body
        _ = AeroTag("Running", tone: .healthy).body
        _ = GlassSection("Hosts") { Text("x") }.body
        _ = GlassSection("Hosts", systemImage: "server.rack") { Text("x") } accessory: { AeroTag("3") }.body
        _ = Text("x").aeroGlass(in: Capsule())
        _ = AquaGel().body
        _ = AeroHeaderWash(tint: Aero.leaf).body
        _ = AeroWell(tint: Aero.coral) { Text("Blocked") }.body
    }

    @Test("sky painter draws at degenerate and large sizes without trapping", arguments: AeroVariant.allCases)
    func skyPainterSizes(variant: AeroVariant) {
        let sizes = [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 3000, height: 200), CGSize(width: 200, height: 3000)]
        for size in sizes {
            let renderer = ImageRenderer(content: SkyBackground()
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, variant == .night ? .dark : .light))
            _ = renderer.cgImage
        }
    }

    @Test("sky surface keeps the image's size, rows, colours and opacity")
    func skySurface() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawing = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        drawing.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        drawing.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        drawing.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        drawing.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        let image = try #require(drawing.makeImage())

        let surface = try #require(SkySurface.rasterize(image))
        #expect(surface.width == 4 && surface.height == 4)
        #expect(surface.attachment(forKey: kIOSurfaceColorSpace as String) != nil)
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        func pixel(row: Int) -> [UInt8] {
            let start = surface.baseAddress.advanced(by: row * surface.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: start, count: 4))
        }
        #expect(pixel(row: 0) == [0, 0, 255, 255])
        #expect(pixel(row: 3) == [255, 0, 0, 255])
    }
}
