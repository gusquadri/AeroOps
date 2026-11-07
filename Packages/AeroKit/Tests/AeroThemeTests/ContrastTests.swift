import SwiftUI
import Testing
@testable import AeroTheme

/// WCAG 2.x contrast of the text tokens against every surface they sit on, by day and by night
/// (target: text contrast of at least 4.5:1 over the brightest part of the gradient).
///
/// Colours are resolved from the real tokens in each variant's colour scheme and composited in
/// gamma-encoded sRGB, the way the window server blends translucent layers.
///
/// By day the text is dark: Liquid Glass and the decorative bubbles/rays only lighten the
/// surface, which raises the contrast, so the darkest surface (`sky.top`) is the binding case.
/// The hills are darker than the sky, but text only sits on glass over them, so glass over solid
/// leaf green (their darkest possible colour) is checked instead of the hills themselves.
///
/// By night the text is light, so the binding cases are the brightest surfaces: glass over the
/// lit cloud crests and over the moon bloom at the top edge of the window.
@Suite("Text contrast (WCAG AA)")
@MainActor
struct ContrastTests {
    /// WCAG AA for normal-size text.
    static let minimum = 4.5

    /// Opaque surfaces text can sit on.
    static func surfaces(_ variant: AeroVariant) -> [(String, RGB)] {
        let skyTop = RGB(Aero.sky.top, variant)
        let skyBottom = RGB(Aero.sky.bottom, variant)
        let skyMid = RGB(Aero.sky.top.mix(with: Aero.sky.bottom, by: 0.5), variant)
        var list: [(String, RGB)] = [
            ("sky.top", skyTop),
            ("sky.middle", skyMid),
            ("sky.bottom", skyBottom),
            ("glass.solidFill", RGB(Aero.glass.solidFill, variant)),
        ]
        if variant == .day {
            list.append(("white (brightest possible)", RGB(.white, variant)))
        }
        let solid = RGB(Aero.glass.solidFill, variant)
        for (tint, color) in Self.tints {
            let well = RGB(color.opacity(AeroWellFill.tintOpacity), over: solid, variant)
            list.append(("\(tint) well", well))
            list.append(("\(tint) well top edge",
                         RGB(Aero.ink.opacity(AeroWellFill.shadeOpacity), over: well, variant)))
        }
        for (name, sky) in Self.backdrops(variant) {
            let glass = RGB(Aero.glass.fill, over: sky, variant)
            list.append(("glass.fill over \(name)", glass))
            list.append(("glass gloss peak over \(name)",
                         RGB(Aero.sheen.opacity(GlassTokens.glossPeak), over: glass, variant)))
            let tagBase = RGB(AeroTagFill.base, over: sky, variant)
            for (tint, color) in Self.tints {
                list.append(("\(tint) tag over \(name)",
                             RGB(color.opacity(AeroTagFill.tintOpacity), over: tagBase, variant)))
                list.append(("\(tint) header wash over glass over \(name)",
                             RGB(color.opacity(AeroHeaderWash.peak), over: glass, variant)))
            }
            list.append(("gauge bubble over glass over \(name)",
                         RGB(Aero.base.opacity(GaugeBubble.edgeOpacity), over: glass, variant)))
        }
        return list
    }

    /// What glass, tags and buttons can sit over: both ends of the sky, plus the hills by day
    /// (their darkest colour) and the cloud crests and moon bloom by night (the brightest).
    static func backdrops(_ variant: AeroVariant) -> [(String, RGB)] {
        let skyTop = RGB(Aero.sky.top, variant)
        var list = [("sky.top", skyTop), ("sky.bottom", RGB(Aero.sky.bottom, variant))]
        switch variant {
        case .day:
            list.append(("leaf hill", RGB(Aero.leaf, variant)))
        case .night:
            list.append(("cloud crest", RGB(NightSky.cloudCrest, variant)))
            list.append(("moon bloom", RGB(NightSky.moonlight.opacity(NightSky.moonPeak), over: skyTop, variant)))
        }
        return list
    }

    /// Every tint the app puts behind text: aqua and the orb tones.
    static let tints: [(String, Color)] = [
        ("aqua", Aero.aqua), ("leaf", Aero.leaf), ("sun", Aero.sun),
        ("coral", Aero.coral), ("neutral", Aero.neutral),
    ]

    @Test("color resolution yields gamma-encoded sRGB, per variant")
    func resolutionSanity() {
        let aqua = RGB(Aero.aqua, .day)
        #expect(abs(aqua.r * 255 - 0x1B) < 0.6)
        #expect(abs(aqua.g * 255 - 0xA6) < 0.6)
        #expect(abs(aqua.b * 255 - 0xE8) < 0.6)
        let night = RGB(Aero.aqua, .night)
        #expect(abs(night.r * 255 - 0x38) < 0.6)
        #expect(abs(night.g * 255 - 0xC4) < 0.6)
        #expect(abs(night.b * 255 - 0xF2) < 0.6)
        #expect(abs(RGB.contrast(RGB(.white, .day), RGB(.black, .day)) - 21) < 0.01)
    }

    @Test("sky.bottom is the lighter end of the sky", arguments: AeroVariant.allCases)
    func skyBottomIsBrightest(variant: AeroVariant) {
        #expect(RGB(Aero.sky.bottom, variant).luminance > RGB(Aero.sky.top, variant).luminance)
    }

    @Test("Aero.text.primary reaches 4.5:1 on every surface", arguments: AeroVariant.allCases)
    func primaryText(variant: AeroVariant) {
        let text = RGB(Aero.text.primary, variant)
        for (name, surface) in Self.surfaces(variant) {
            let ratio = RGB.contrast(text, surface)
            #expect(ratio >= Self.minimum, "\(variant) primary on \(name): \(ratio.formatted2):1")
        }
    }

    @Test("Aero.text.secondary reaches 4.5:1 on every surface", arguments: AeroVariant.allCases)
    func secondaryText(variant: AeroVariant) {
        let text = RGB(Aero.text.secondary, variant)
        for (name, surface) in Self.surfaces(variant) {
            let ratio = RGB.contrast(text, surface)
            #expect(ratio >= Self.minimum, "\(variant) secondary on \(name): \(ratio.formatted2):1")
        }
    }

    /// By night 4.5:1, as text. By day the original deep aqua, used mostly for icons, keeps 3:1
    /// (WCAG non-text contrast) on glass over the sky, 4.5:1 on solid glass.
    @Test("Aero.aquaDeep (icons and links) reaches its minimum on glass", arguments: AeroVariant.allCases)
    func aquaDeepOnGlass(variant: AeroVariant) {
        let link = RGB(Aero.aquaDeep, variant)
        let minimum = variant == .night ? Self.minimum : 3
        for (name, sky) in Self.backdrops(variant) {
            let glass = RGB(Aero.glass.fill, over: sky, variant)
            let ratio = RGB.contrast(link, glass)
            #expect(ratio >= minimum, "\(variant) aquaDeep on glass over \(name): \(ratio.formatted2):1")
        }
        let ratio = RGB.contrast(link, RGB(Aero.glass.solidFill, variant))
        #expect(ratio >= Self.minimum, "\(variant) aquaDeep on glass.solidFill: \(ratio.formatted2):1")
    }

    @Test("white labels on primary and destructive buttons reach 4.5:1", arguments: AeroVariant.allCases)
    func primaryButtonLabel(variant: AeroVariant) {
        let label = RGB(Aero.text.onAccent, variant)
        for (name, fill) in [("primary", AquaFill.primary), ("destructive", AquaFill.destructive)] {
            let ratio = RGB.contrast(label, RGB(fill.band, variant))
            #expect(ratio >= Self.minimum, "\(variant) white on \(name) band: \(ratio.formatted2):1")
        }
    }

    @Test("by day, white on aquaDeep reaches 4.5:1")
    func whiteOnAquaDeep() {
        #expect(RGB.contrast(RGB(Aero.text.onAccent, .day), RGB(Aero.aquaDeep, .day)) >= Self.minimum)
    }

    @Test("onBright labels reach 4.5:1 on leaf and sun", arguments: AeroVariant.allCases)
    func onBrightLabel(variant: AeroVariant) {
        let label = RGB(Aero.text.onBright, variant)
        for (name, fill) in [("leaf", Aero.leaf), ("sun", Aero.sun)] {
            let ratio = RGB.contrast(label, RGB(fill, variant))
            #expect(ratio >= Self.minimum, "\(variant) onBright on \(name): \(ratio.formatted2):1")
        }
    }

    @Test("secondary button label reaches 4.5:1 on its fill over every backdrop", arguments: AeroVariant.allCases)
    func secondaryButtonLabel(variant: AeroVariant) {
        let label = RGB(AquaGlassFill.label, variant)
        for (name, backdrop) in Self.backdrops(variant) {
            let fill = RGB(AquaGlassFill.bottom, over: backdrop, variant)
            let ratio = RGB.contrast(label, fill)
            #expect(ratio >= Self.minimum, "\(variant) secondary label over \(name): \(ratio.formatted2):1")
        }
    }

    @Test("print the contrast table", arguments: AeroVariant.allCases)
    func report(variant: AeroVariant) {
        let primary = RGB(Aero.text.primary, variant), secondary = RGB(Aero.text.secondary, variant)
        for (name, surface) in Self.surfaces(variant) {
            print("contrast \(variant)  \(name): primary \(RGB.contrast(primary, surface).formatted2), "
                + "secondary \(RGB.contrast(secondary, surface).formatted2)")
        }
        let white = RGB(.white, variant)
        print("contrast \(variant)  white on aqua band: \(RGB.contrast(white, RGB(AquaFill.primary.band, variant)).formatted2)")
        print("contrast \(variant)  white on coral band: \(RGB.contrast(white, RGB(AquaFill.destructive.band, variant)).formatted2)")
        print("contrast \(variant)  aquaDeep on secondary button over sky.top: "
            + "\(RGB.contrast(RGB(AquaGlassFill.label, variant), RGB(AquaGlassFill.bottom, over: RGB(Aero.sky.top, variant), variant)).formatted2)")
    }
}

/// A gamma-encoded sRGB colour with WCAG luminance and alpha compositing.
struct RGB: Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// An opaque colour as `variant` shows it (alpha is ignored; use ``init(_:over:_:)`` for
    /// translucent colours).
    ///
    /// Main actor: the tokens are dynamic `NSColor`s, and SwiftUI resolves those off the main
    /// thread by waiting on it (`UpdateGroup.syncMain`), which deadlocks parallel tests.
    @MainActor
    init(_ color: Color, _ variant: AeroVariant) {
        let resolved = color.resolve(in: .aero(variant))
        self.init(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue))
    }

    /// `color` (with its opacity) as `variant` shows it, composited over an opaque `background`.
    @MainActor
    init(_ color: Color, over background: RGB, _ variant: AeroVariant) {
        let resolved = color.resolve(in: .aero(variant))
        let a = Double(resolved.opacity)
        self.init(
            r: Double(resolved.red) * a + background.r * (1 - a),
            g: Double(resolved.green) * a + background.g * (1 - a),
            b: Double(resolved.blue) * a + background.b * (1 - a)
        )
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double {
            let c = min(max(c, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (a.luminance, b.luminance)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

extension Double {
    var formatted2: String { String(format: "%.2f", self) }
}

extension EnvironmentValues {
    /// An environment in the colour scheme of `variant`.
    static func aero(_ variant: AeroVariant) -> EnvironmentValues {
        var environment = EnvironmentValues()
        environment.colorScheme = variant == .night ? .dark : .light
        return environment
    }
}
