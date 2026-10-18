#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Frutiger Aero design tokens.
///
/// Views use these instead of literal colours, radii, shadows or fonts, so a second theme later
/// is a token swap. Names mirror the plan's token table: `Aero.sky.top`, `Aero.aqua`,
/// `Aero.glass.fill`, `Aero.radius.card`, `Aero.shadow.card`, `Aero.font(.body)`.
///
/// Every colour token follows the macOS appearance (``AeroVariant``): Frutiger Aero, a sunlit
/// sky, in light mode, and Nightly Frutiger Aero, a starry indigo sky over violet clouds with
/// smoked glass and moonlit rims, in dark mode.
/// The token resolves when it is drawn, so views never branch on the colour scheme. Text on Aero
/// surfaces uses ``Aero/text`` (not the system `.primary` / `.secondary` styles), whose colours
/// are checked by unit tests to reach WCAG AA (4.5:1) on every sky and glass surface of both.
public enum Aero {
    /// Window background gradient colours (`sky.top` / `sky.bottom`).
    public static let sky = SkyTokens(
        top: Color(day: 0x5BC8F5, night: 0x0E1236),
        bottom: Color(day: 0xE9F8FF, night: 0x3B2C7E)
    )
    /// Primary buttons and the selected tab.
    public static let aqua = Color(day: 0x1BA6E8, night: 0x38C4F2)
    /// Deep aqua: icons and links on glass. By day also the label-bearing band of primary
    /// buttons: white text on it and it on white both reach 4.5:1. By night a light aqua that
    /// reaches 4.5:1 on smoked glass; the buttons keep their own deep band (``AquaFill``).
    public static let aquaDeep = Color(day: 0x0B6FB5, night: 0x8AD8FF)
    /// Healthy status and gauge fill.
    public static let leaf = Color(day: 0x6CCB4F, night: 0x72D957)
    /// Warning status.
    public static let sun = Color(day: 0xFFC83D, night: 0xFFCD4A)
    /// Error and offline status.
    public static let coral = Color(day: 0xF2605A, night: 0xFF6B66)
    /// Neutral status (e.g. a Succeeded pod, a host still loading). Not in the plan's table.
    public static let neutral = Color(day: 0x9AA8B4, night: 0x8F9AC4)
    /// Text colours for Aero surfaces (sky, glass, tags, buttons).
    public static let text = TextTokens(
        primary: Color(day: 0x0D2B45, night: 0xF1F3FF),
        secondary: Color(day: 0x2C4A66, night: 0xCED4F5),
        onAccent: .white,
        onBright: Color(hex: 0x0D2B45)
    )
    /// Card glass: fill, rim highlight and the solid fill used with Reduce Transparency.
    public static let glass = GlassTokens(
        fill: Color(day: .white.opacity(0.55), night: Color(hex: 0x14173F, opacity: 0.78)),
        rimTop: Color(day: .white.opacity(0.8), night: .white.opacity(0.38)),
        rimBottom: Color(day: .white.opacity(0.2), night: Color(hex: 0x9C8CFF, opacity: 0.14)),
        solidFill: Color(day: 0xF4FBFF, night: 0x181B45),
        rimStrong: Color(day: Color(hex: 0x0D2B45, opacity: 0.45), night: Color(hex: 0xD6D9FF, opacity: 0.6))
    )
    /// Corner radii.
    public static let radius = RadiusTokens(card: 18, inner: 12)
    /// Shadows.
    public static let shadow = ShadowTokens(
        card: AeroShadow(
            color: Color(day: Color(hex: 0x0A4A7A, opacity: 0.18), night: Color(hex: 0x02031A, opacity: 0.55)),
            blur: 18, x: 0, y: 6
        ),
        control: AeroShadow(
            color: Color(day: Color(hex: 0x0A4A7A, opacity: 0.28), night: Color(hex: 0x02031A, opacity: 0.6)),
            blur: 4, x: 0, y: 1.5
        )
    )

    /// SF Pro Rounded for a text style, e.g. `Aero.font(.headline, weight: .semibold)`.
    /// All app text uses the rounded design (Frutiger itself is a licensed font).
    public static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    /// SF Pro Rounded at a fixed point size, for numerals in gauges and similar.
    public static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// SF Mono at a text style's size, e.g. `Aero.monospacedFont(.callout)`: commands, paths,
    /// fingerprints, JSON and describe output, whose characters must stay distinct and line up.
    ///
    /// Built from the AppKit font: the app-wide `.fontDesign(.rounded)` replaces the design of
    /// system fonts, so `.system(style, design: .monospaced)` and `Font.monospaced()` come out
    /// proportional.
    public static func monospacedFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        #if os(macOS)
        Font(monospacedNSFont(style.appKit, weight: weight.appKit) as CTFont)
        #else
        Font(UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: style.appKit).pointSize, weight: weight.appKit) as CTFont)
        #endif
    }

    #if os(macOS)
    /// ``monospacedFont(_:weight:)`` for AppKit text views (the log viewer).
    public static func monospacedNSFont(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }
    #endif
}

#if os(macOS)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif

extension Font.TextStyle {
    /// The AppKit (UIKit on iOS) text style of the same size.
    var appKit: PlatformFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}

extension Font.Weight {
    /// The AppKit (UIKit on iOS) font weight of the same name.
    var appKit: PlatformFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

// MARK: - Internal palette

/// Shades the components derive from the public tokens. Internal so the public token surface
/// stays the plan's table; views outside AeroTheme use components or public tokens.
extension Aero {
    /// Light aqua for glows and the top of gradients.
    static let aquaLight = Color(day: 0x7DD8FF, night: 0x9FE6FF)
    /// Deep shades used for rims, the label band of buttons and orb edges. The gels they shade
    /// (buttons, orbs, bubbles) glow the same by day and by night.
    static let leafDeep = Color(hex: 0x3E8E2A)
    static let sunDeep = Color(hex: 0xD69500)
    static let coralDeep = Color(hex: 0xC93A36)
    static let neutralDeep = Color(hex: 0x66778A)
    /// Ink for hairlines and groove shading (same hue as the shadow token).
    static let ink = Color(day: 0x0A4A7A, night: 0x03041C)
    /// The base of glass parts that carry text (tags, the gauge bubble, secondary buttons):
    /// white by day, deep indigo by night.
    static let base = Color(day: 0xFFFFFF, night: 0x1B1E4C)
    /// The light that glosses glass (gloss, rims, groove lips): sunlight by day, a fainter
    /// moonlight by night. Gels keep a white gloss in both.
    static let sheen = Color(day: .white, night: .white.opacity(0.2))
}

// MARK: - Token groups

/// The `sky.*` tokens.
public struct SkyTokens: Sendable {
    /// `sky.top`: #5BC8F5 by day, midnight #0E1236 by night.
    public let top: Color
    /// `sky.bottom`: #E9F8FF by day, violet #3B2C7E by night. The lighter end of both.
    public let bottom: Color
    /// Top-to-bottom gradient of ``top`` and ``bottom``.
    public var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Text colours for Aero surfaces. Both ``primary`` and ``secondary`` reach WCAG AA (4.5:1)
/// over `sky.top`, `sky.bottom`, and glass over either end of the sky, the hills or the clouds,
/// by day and by night (unit-tested).
public struct TextTokens: Sendable {
    /// Titles, values and body text: deep navy #0D2B45 by day, moonlit white #F1F3FF by night.
    public let primary: Color
    /// Captions, labels and metadata: slate navy #2C4A66 by day, lavender #CED4F5 by night.
    /// Use ``primary`` with Increase Contrast.
    public let secondary: Color
    /// Labels on filled accent surfaces (primary buttons): white.
    public let onAccent: Color
    /// Labels on bright status fills (`leaf`, `sun`), which stay bright by night: deep navy
    /// #0D2B45 in both variants.
    public let onBright: Color
}

/// The `glass.*` tokens.
public struct GlassTokens: Sendable {
    /// `glass.fill`, drawn over the system material: white at 55% by day, smoked indigo at 78%
    /// by night.
    public let fill: Color
    /// Top colour of `glass.rim` (white 80% by day, 38% by night).
    public let rimTop: Color
    /// Bottom colour of `glass.rim` (white 20% by day, lavender 14% by night).
    public let rimBottom: Color
    /// Opaque card fill used when Reduce Transparency is on.
    public let solidFill: Color
    /// Rim colour used with Increase Contrast: navy at 45% by day, lavender at 60% by night, so
    /// edges stay visible on either sky.
    public let rimStrong: Color
    /// `glass.rim`: card edge highlight fading from ``rimTop`` to ``rimBottom``.
    public var rim: LinearGradient {
        LinearGradient(colors: [rimTop, rimBottom], startPoint: .top, endPoint: .bottom)
    }
    /// Opacity of ``gloss`` at its top edge, times `Aero.sheen` (read by the contrast tests).
    static let glossPeak = 0.72

    /// The gloss over the top 45% of a glass surface: white by day, faint moonlight by night.
    /// Fill the surface's shape with it.
    public var gloss: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Aero.sheen.opacity(Self.glossPeak), location: 0),
                .init(color: Aero.sheen.opacity(0.38), location: 0.12),
                .init(color: Aero.sheen.opacity(0.12), location: 0.36),
                .init(color: Aero.sheen.opacity(0), location: 0.45),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// The `radius.*` tokens, in points.
public struct RadiusTokens: Sendable {
    /// `radius.card`: cards and sheets (18 pt).
    public let card: CGFloat
    /// Panels nested inside a card, e.g. a log view or a text field well (12 pt).
    public let inner: CGFloat
}

/// The `shadow.*` tokens.
public struct ShadowTokens: Sendable {
    /// `shadow.card`: y 6, blur 18, #0A4A7A at 18% by day, near-black indigo at 55% by night.
    public let card: AeroShadow
    /// Small controls (buttons, tags): y 1.5, blur 4, #0A4A7A at 28% by day, indigo at 60% by night.
    public let control: AeroShadow
}

/// A drop shadow in design-tool terms. Apply with ``SwiftUICore/View/aeroShadow(_:)``.
public struct AeroShadow: Sendable, Hashable {
    /// Shadow colour, including opacity.
    public let color: Color
    /// Blur as specified in the design (SwiftUI's shadow radius is half of this).
    public let blur: CGFloat
    /// Horizontal offset.
    public let x: CGFloat
    /// Vertical offset.
    public let y: CGFloat
}

extension View {
    /// Applies an ``AeroShadow`` (default: `Aero.shadow.card`).
    public func aeroShadow(_ shadow: AeroShadow = Aero.shadow.card) -> some View {
        self.shadow(color: shadow.color, radius: shadow.blur / 2, x: shadow.x, y: shadow.y)
    }
}

extension Color {
    /// sRGB colour from a 0xRRGGBB literal. Internal: views outside AeroTheme use tokens.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A colour that follows the appearance: `day` in light mode, `night` in dark mode.
    ///
    /// Backed by a dynamic `NSColor`, so SwiftUI resolves it against the environment's colour
    /// scheme wherever it is drawn (views, `Canvas`, `Color.resolve(in:)`) and AppKit against the
    /// view's effective appearance (the log text view).
    init(day: Color, night: Color) {
        #if os(macOS)
        let day = NSColor(day), night = NSColor(night)
        self.init(nsColor: NSColor(name: nil) { appearance in
            AeroVariant(appearance) == .night ? night : day
        })
        #else
        let day = UIColor(day), night = UIColor(night)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? night : day
        })
        #endif
    }

    /// ``init(day:night:)`` from two 0xRRGGBB literals.
    init(day: UInt32, night: UInt32) {
        self.init(day: Color(hex: day), night: Color(hex: night))
    }
}

// MARK: - Variants

/// The two looks of the Aero theme. AeroOps follows the macOS appearance, so there is nothing
/// to pick: light mode shows ``day``, dark mode shows ``night``.
public enum AeroVariant: String, Sendable, Hashable, CaseIterable {
    /// Frutiger Aero: sunlit sky, rolling green hills, white glass.
    case day
    /// Nightly Frutiger Aero: midnight-to-violet sky with stars, glowing clouds, aurora ribbons,
    /// smoked glass and moonlit rims.
    case night

    /// The variant for a SwiftUI colour scheme.
    public init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .night : .day
    }

    #if os(macOS)
    /// The variant for an AppKit appearance (any dark or vibrant-dark appearance is night).
    public init(_ appearance: NSAppearance) {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        self = match == .darkAqua || match == .vibrantDark ? .night : .day
    }
    #endif

    /// The theme's name, e.g. for Settings › Appearance.
    public var title: String {
        switch self {
        case .day: "Frutiger Aero"
        case .night: "Nightly Frutiger Aero"
        }
    }
}
