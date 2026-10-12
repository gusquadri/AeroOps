import SwiftUI
import Testing
@testable import AeroTheme

@Suite("AeroTheme")
@MainActor
struct AeroThemeTests {
    @Test("tokens match the plan's starting values")
    func tokens() {
        #expect(Aero.radius.card == 18)
        #expect(Aero.shadow.card.y == 6)
        #expect(Aero.shadow.card.blur == 18)
        #expect(Aero.aqua == Color(hex: 0x1BA6E8))
        #expect(Aero.leaf == Color(hex: 0x6CCB4F))
        #expect(Aero.sun == Color(hex: 0xFFC83D))
        #expect(Aero.coral == Color(hex: 0xF2605A))
        #expect(Aero.sky.top == Color(hex: 0x5BC8F5))
        #expect(Aero.sky.bottom == Color(hex: 0xE9F8FF))
        #expect(Aero.glass.fill == .white.opacity(0.55))
        #expect(Aero.glass.rimTop == .white.opacity(0.8))
        #expect(Aero.glass.rimBottom == .white.opacity(0.2))
        #expect(Aero.shadow.card.color == Color(hex: 0x0A4A7A).opacity(0.18))
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
        _ = Button("Go") {}.buttonStyle(.aqua)
        _ = Button("Go") {}.buttonStyle(.aquaSecondary)
        _ = AeroTag("prod").body
        _ = AeroTag("Running", tone: .healthy).body
        _ = GlassSection("Hosts") { Text("x") }.body
        _ = GlassSection("Hosts", systemImage: "server.rack") { Text("x") } accessory: { AeroTag("3") }.body
        _ = Text("x").aeroGlass(in: Capsule())
    }

    @Test("sky painter draws at degenerate and large sizes without trapping")
    func skyPainterSizes() {
        for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 3000, height: 200)] {
            let renderer = ImageRenderer(content: SkyBackground().frame(width: size.width, height: size.height))
            _ = renderer.cgImage
        }
    }
}
