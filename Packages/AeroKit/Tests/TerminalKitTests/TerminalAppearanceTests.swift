import Testing
@testable import TerminalKit
import TerminalStyle

@Suite("TerminalAppearance")
struct TerminalAppearanceTests {
    @Test("hex parsing and formatting")
    func hex() {
        #expect(TerminalRGB(hexString: "#0B3D5C") == TerminalRGB(red: 0x0B, green: 0x3D, blue: 0x5C))
        #expect(TerminalRGB(hexString: "e6f4ff")?.hexString == "e6f4ff")
        #expect(TerminalRGB(hexString: "12345") == nil)
        #expect(TerminalRGB(hexString: "zzzzzz") == nil)
        #expect(TerminalRGB(hex: 0x7FDBFF).description == "#7fdbff")
    }

    @Test("aero preset has a full palette")
    func aeroPreset() {
        #expect(TerminalAppearance.aero.palette.count == 16)
        #expect(TerminalAppearance.aero.colorSettings.filter { $0.key == "palette" }.count == 16)
    }

    @Test("colours become ghostty settings")
    func colorSettings() {
        let settings = TerminalAppearance.aero.colorSettings
        #expect(settings.contains { $0.key == "background" && $0.value == "0b3d5c" })
        #expect(settings.contains { $0.key == "palette" && $0.value == "1=f2605a" })
    }

    @Test("ghostty config carries the exit-reporting settings and no command")
    func configSettings() {
        var appearance = TerminalAppearance.aero
        appearance.fontSize = 13.5
        appearance.fontFamily = "Menlo\nfont-size = 99"
        let settings = GhosttyConfig.settings(appearance: appearance)
        let dict = Dictionary(settings.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(dict["command"] == nil)
        #expect(dict["wait-after-command"] == "false")
        #expect(dict["abnormal-command-exit-runtime"] == "0")
        #expect(dict["clipboard-read"] == "deny")
        #expect(dict["font-size"] == "13.50")
        #expect(dict["font-family"] == "Menlofont-size = 99")
        #expect(settings.allSatisfy { !$0.value.contains("\n") })
    }

    @Test("font size literal ignores locale and clamps")
    func fontSize() {
        #expect(GhosttyConfig.fontSizeLiteral(13) == "13")
        #expect(GhosttyConfig.fontSizeLiteral(12.25) == "12.25")
        var appearance = TerminalAppearance.aero
        appearance.fontSize = 500
        #expect(appearance.clampedFontSize == 72)
        appearance.fontSize = .nan
        #expect(appearance.clampedFontSize == 13)
    }
}
