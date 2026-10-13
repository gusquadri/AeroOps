import SwiftUI
import Testing
@testable import AeroTheme

/// WCAG 2.x contrast of the text tokens against every surface they sit on
/// (target: text contrast of at least 4.5:1 over the brightest part of the gradient).
///
/// Colours are resolved from the real tokens and composited in gamma-encoded sRGB, the way the
/// window server blends translucent layers. Liquid Glass and the decorative bubbles/rays only
/// lighten the surface further, which raises the contrast of the dark text tokens; the darkest
/// surface (`sky.top`) is therefore the binding case and is included. The hills are darker
/// than the sky, but text only sits on glass over them, so glass over solid leaf green (their
/// darkest possible colour) is checked instead of the hills themselves.
@Suite("Text contrast (WCAG AA)")
struct ContrastTests {
    /// WCAG AA for normal-size text.
    static let minimum = 4.5

    /// Opaque surfaces text can sit on.
    static let surfaces: [(String, RGB)] = {
        let skyTop = RGB(Aero.sky.top)
        let skyBottom = RGB(Aero.sky.bottom)
        let skyMid = RGB(Aero.sky.top.mix(with: Aero.sky.bottom, by: 0.5))
        let white = RGB(.white)
        var list: [(String, RGB)] = [
            ("sky.top", skyTop),
            ("sky.middle", skyMid),
            ("sky.bottom", skyBottom),
            ("white (brightest possible)", white),
            ("glass.solidFill", RGB(Aero.glass.solidFill)),
        ]
        // Wells: opaque, so the backdrop does not matter; the top edge carries the inner shade.
        let solid = RGB(Aero.glass.solidFill)
        for (tint, color) in Self.tints {
            let well = RGB(color.opacity(AeroWellFill.tintOpacity), over: solid)
            list.append(("\(tint) well", well))
            list.append(("\(tint) well top edge", RGB(Aero.ink.opacity(AeroWellFill.shadeOpacity), over: well)))
        }
        for (name, sky) in Self.backdrops {
            let glass = RGB(Aero.glass.fill, over: sky)
            list.append(("glass.fill over \(name)", glass))
            list.append(("glass gloss peak over \(name)",
                         RGB(.white.opacity(GlassTokens.glossPeak), over: glass)))
            // Tags: light base plus a tint wash, for every tint the app uses.
            let tagBase = RGB(AeroTagFill.base, over: sky)
            for (tint, color) in Self.tints {
                list.append(("\(tint) tag over \(name)",
                             RGB(color.opacity(AeroTagFill.tintOpacity), over: tagBase)))
                // Card and section headers: the tint wash at its peak over plain glass.
                list.append(("\(tint) header wash over glass over \(name)",
                             RGB(color.opacity(AeroHeaderWash.peak), over: glass)))
            }
            // Gauge centre bubble at its most transparent.
            list.append(("gauge bubble over glass over \(name)", RGB(.white.opacity(0.62), over: glass)))
        }
        return list
    }()

    /// What glass, tags and buttons can sit over: both ends of the sky and the hills.
    static let backdrops: [(String, RGB)] = [
        ("sky.top", RGB(Aero.sky.top)),
        ("sky.bottom", RGB(Aero.sky.bottom)),
        ("leaf hill", RGB(Aero.leaf)),
    ]

    /// Every tint the app puts behind text: aqua and the orb tones.
    static let tints: [(String, Color)] = [
        ("aqua", Aero.aqua), ("leaf", Aero.leaf), ("sun", Aero.sun),
        ("coral", Aero.coral), ("neutral", Aero.neutral),
    ]

    @Test("color resolution yields gamma-encoded sRGB")
    func resolutionSanity() {
        let aqua = RGB(Aero.aqua)
        #expect(abs(aqua.r * 255 - 0x1B) < 0.6)
        #expect(abs(aqua.g * 255 - 0xA6) < 0.6)
        #expect(abs(aqua.b * 255 - 0xE8) < 0.6)
        #expect(abs(RGB.contrast(RGB(.white), RGB(.black)) - 21) < 0.01)
    }

    @Test("sky.bottom is the brightest part of the sky gradient")
    func skyBottomIsBrightest() {
        #expect(RGB(Aero.sky.bottom).luminance > RGB(Aero.sky.top).luminance)
    }

    @Test("Aero.text.primary reaches 4.5:1 on every surface")
    func primaryText() {
        let text = RGB(Aero.text.primary)
        for (name, surface) in Self.surfaces {
            let ratio = RGB.contrast(text, surface)
            #expect(ratio >= Self.minimum, "primary on \(name): \(ratio.formatted2):1")
        }
    }

    @Test("Aero.text.secondary reaches 4.5:1 on every surface")
    func secondaryText() {
        let text = RGB(Aero.text.secondary)
        for (name, surface) in Self.surfaces {
            let ratio = RGB.contrast(text, surface)
            #expect(ratio >= Self.minimum, "secondary on \(name): \(ratio.formatted2):1")
        }
    }

    @Test("white labels on primary and destructive buttons reach 4.5:1")
    func primaryButtonLabel() {
        let label = RGB(Aero.text.onAccent)
        for (name, fill) in [("primary", AquaFill.primary), ("destructive", AquaFill.destructive)] {
            let ratio = RGB.contrast(label, RGB(fill.band))
            #expect(ratio >= Self.minimum, "white on \(name) band: \(ratio.formatted2):1")
        }
        #expect(RGB.contrast(label, RGB(Aero.aquaDeep)) >= Self.minimum)
    }

    @Test("secondary button label reaches 4.5:1 on its fill over the sky and the hills")
    func secondaryButtonLabel() {
        let label = RGB(AquaGlassFill.label)
        for (name, backdrop) in Self.backdrops {
            let fill = RGB(AquaGlassFill.bottom, over: backdrop)
            let ratio = RGB.contrast(label, fill)
            #expect(ratio >= Self.minimum, "secondary label over \(name): \(ratio.formatted2):1")
        }
    }

    @Test("print the contrast table")
    func report() {
        let primary = RGB(Aero.text.primary), secondary = RGB(Aero.text.secondary)
        for (name, surface) in Self.surfaces {
            print("contrast  \(name): primary \(RGB.contrast(primary, surface).formatted2), "
                + "secondary \(RGB.contrast(secondary, surface).formatted2)")
        }
        print("contrast  white on aqua band: \(RGB.contrast(RGB(.white), RGB(AquaFill.primary.band)).formatted2)")
        print("contrast  white on coral band: \(RGB.contrast(RGB(.white), RGB(AquaFill.destructive.band)).formatted2)")
        print("contrast  aquaDeep on secondary button over sky.top: "
            + "\(RGB.contrast(RGB(AquaGlassFill.label), RGB(AquaGlassFill.bottom, over: RGB(Aero.sky.top))).formatted2)")
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

    /// An opaque colour (alpha is ignored; use ``init(_:over:)`` for translucent colours).
    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue))
    }

    /// `color` (with its opacity) composited over an opaque `background`.
    init(_ color: Color, over background: RGB) {
        let resolved = color.resolve(in: EnvironmentValues())
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
