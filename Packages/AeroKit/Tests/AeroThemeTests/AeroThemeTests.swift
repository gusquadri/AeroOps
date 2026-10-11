import SwiftUI
import Testing
@testable import AeroTheme

@Suite("AeroTheme")
struct AeroThemeTests {
    @Test("tokens match the plan's starting values")
    func tokens() {
        #expect(Aero.radius.card == 18)
        #expect(Aero.shadow.card.y == 6)
        #expect(Aero.shadow.card.blur == 18)
        #expect(Aero.aqua == Color(hex: 0x1BA6E8))
        #expect(Aero.sky.top == Color(hex: 0x5BC8F5))
        #expect(Aero.sky.bottom == Color(hex: 0xE9F8FF))
    }

    @Test("every orb tone has a distinct colour")
    func orbTones() {
        let colors = OrbTone.allCases.map(\.color)
        #expect(Set(colors.map(\.description)).count == OrbTone.allCases.count)
        #expect(OrbTone.healthy.color == Aero.leaf)
        #expect(OrbTone.error.color == Aero.coral)
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

    @Test("components build their bodies")
    @MainActor
    func componentsInstantiate() {
        _ = AeroCard { Text("x") }.body
        _ = GlossyGauge(value: nil, label: "CPU").body
        _ = StatusOrb(tone: .warning).body
        _ = SkyBackground().body
        _ = Button("Go") {}.buttonStyle(.aqua)
    }
}
