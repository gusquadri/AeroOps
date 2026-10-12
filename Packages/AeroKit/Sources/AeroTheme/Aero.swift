import AppKit
import SwiftUI

/// Frutiger Aero design tokens.
///
/// Views use these instead of literal colours, radii, shadows or fonts, so a second theme later
/// is a token swap. Names mirror the plan's token table: `Aero.sky.top`, `Aero.aqua`,
/// `Aero.glass.fill`, `Aero.radius.card`, `Aero.shadow.card`, `Aero.font(.body)`.
///
/// The theme is light-only until "Aero Night" lands. Text on Aero surfaces uses ``Aero/text``
/// (not the system `.primary` / `.secondary` styles), whose colours are checked by unit tests
/// to reach WCAG AA (4.5:1) on every sky and glass surface.
public enum Aero {
    /// Window background gradient colours (`sky.top` / `sky.bottom`).
    public static let sky = SkyTokens(top: Color(hex: 0x5BC8F5), bottom: Color(hex: 0xE9F8FF))
    /// Primary buttons and the selected tab.
    public static let aqua = Color(hex: 0x1BA6E8)
    /// Deep aqua: the label-bearing band of primary buttons, icons and links on glass.
    /// White text on it and it on white both reach 4.5:1.
    public static let aquaDeep = Color(hex: 0x0B6FB5)
    /// Healthy status and gauge fill.
    public static let leaf = Color(hex: 0x6CCB4F)
    /// Warning status.
    public static let sun = Color(hex: 0xFFC83D)
    /// Error and offline status.
    public static let coral = Color(hex: 0xF2605A)
    /// Neutral status (e.g. a Succeeded pod, a host still loading). Not in the plan's table.
    public static let neutral = Color(hex: 0x9AA8B4)
    /// Text colours for Aero surfaces (sky, glass, tags, buttons).
    public static let text = TextTokens(
        primary: Color(hex: 0x0D2B45),
        secondary: Color(hex: 0x2C4A66),
        onAccent: .white
    )
    /// Card glass: fill, rim highlight and the solid fill used with Reduce Transparency.
    public static let glass = GlassTokens(
        fill: .white.opacity(0.55),
        rimTop: .white.opacity(0.8),
        rimBottom: .white.opacity(0.2),
        solidFill: Color(hex: 0xF4FBFF),
        rimStrong: Color(hex: 0x0D2B45).opacity(0.45)
    )
    /// Corner radii.
    public static let radius = RadiusTokens(card: 18, inner: 12)
    /// Shadows.
    public static let shadow = ShadowTokens(
        card: AeroShadow(color: Color(hex: 0x0A4A7A).opacity(0.18), blur: 18, x: 0, y: 6),
        control: AeroShadow(color: Color(hex: 0x0A4A7A).opacity(0.28), blur: 4, x: 0, y: 1.5)
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
        Font(monospacedNSFont(style.appKit, weight: weight.appKit) as CTFont)
    }

    /// ``monospacedFont(_:weight:)`` for AppKit text views (the log viewer).
    public static func monospacedNSFont(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }
}

extension Font.TextStyle {
    /// The AppKit text style of the same size.
    var appKit: NSFont.TextStyle {
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
    /// The AppKit font weight of the same name.
    var appKit: NSFont.Weight {
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
    static let aquaLight = Color(hex: 0x7DD8FF)
    /// Deep shades used for rims, the label band of buttons and orb edges.
    static let leafDeep = Color(hex: 0x3E8E2A)
    static let sunDeep = Color(hex: 0xD69500)
    static let coralDeep = Color(hex: 0xC93A36)
    static let neutralDeep = Color(hex: 0x66778A)
    /// Ink for hairlines and groove shading (same hue as the shadow token).
    static let ink = Color(hex: 0x0A4A7A)
}

// MARK: - Token groups

/// The `sky.*` tokens.
public struct SkyTokens: Sendable {
    /// `sky.top`, #5BC8F5.
    public let top: Color
    /// `sky.bottom`, #E9F8FF.
    public let bottom: Color
    /// Top-to-bottom gradient of ``top`` and ``bottom``.
    public var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Text colours for Aero surfaces. Both ``primary`` and ``secondary`` reach WCAG AA (4.5:1)
/// over `sky.top`, `sky.bottom`, white and glass over either end of the sky (unit-tested).
public struct TextTokens: Sendable {
    /// Titles, values and body text: deep navy, #0D2B45.
    public let primary: Color
    /// Captions, labels and metadata: slate navy, #2C4A66. Use ``primary`` with Increase Contrast.
    public let secondary: Color
    /// Labels on filled accent surfaces (primary buttons): white.
    public let onAccent: Color
}

/// The `glass.*` tokens.
public struct GlassTokens: Sendable {
    /// `glass.fill`: white at 55%, drawn over the system material.
    public let fill: Color
    /// Top colour of `glass.rim` (white 80%).
    public let rimTop: Color
    /// Bottom colour of `glass.rim` (white 20%).
    public let rimBottom: Color
    /// Opaque card fill used when Reduce Transparency is on.
    public let solidFill: Color
    /// Rim colour used with Increase Contrast: navy at 45%, so edges stay visible on light sky.
    public let rimStrong: Color
    /// `glass.rim`: card edge highlight fading from ``rimTop`` to ``rimBottom``.
    public var rim: LinearGradient {
        LinearGradient(colors: [rimTop, rimBottom], startPoint: .top, endPoint: .bottom)
    }
    /// Opacity of ``gloss`` at its top edge (read by the contrast tests).
    static let glossPeak = 0.72

    /// The white gloss over the top 45% of a glass surface. Fill the surface's shape with it.
    public var gloss: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(Self.glossPeak), location: 0),
                .init(color: .white.opacity(0.38), location: 0.12),
                .init(color: .white.opacity(0.12), location: 0.36),
                .init(color: .white.opacity(0), location: 0.45),
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
    /// `shadow.card`: y 6, blur 18, #0A4A7A at 18%.
    public let card: AeroShadow
    /// Small controls (buttons, tags): y 1.5, blur 4, #0A4A7A at 28%.
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
}
