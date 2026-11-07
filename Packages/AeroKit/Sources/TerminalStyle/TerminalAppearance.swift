import Foundation

/// An sRGB colour as plain bytes, so the app can map its own design tokens onto the terminal.
public struct TerminalRGB: Sendable, Hashable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(
            red: UInt8((hex >> 16) & 0xFF),
            green: UInt8((hex >> 8) & 0xFF),
            blue: UInt8(hex & 0xFF)
        )
    }

    /// `"RRGGBB"` or `"#RRGGBB"`; `nil` for anything else.
    public init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        self.init(hex: value)
    }

    /// Lower-case `rrggbb`, the form written into the libghostty config.
    public var hexString: String {
        String(format: "%02x%02x%02x", red, green, blue)
    }

    public var description: String { "#" + hexString }
}

/// Font and colours of a terminal surface. Plain values only; the app decides the look.
///
/// ``aero`` is a ready-made dark-water preset in the Frutiger Aero palette the app can use
/// as-is or override field by field.
public struct TerminalAppearance: Sendable, Hashable {
    /// Font family name as Core Text knows it (e.g. `"SF Mono"`); `nil` uses libghostty's default.
    public var fontFamily: String?
    /// Font size in points; also the size a font-size reset returns to.
    public var fontSize: Float
    public var foreground: TerminalRGB
    public var background: TerminalRGB
    public var cursor: TerminalRGB
    public var selectionForeground: TerminalRGB
    public var selectionBackground: TerminalRGB
    /// ANSI colours 0-15 (8 normal, then 8 bright). Exactly 16 entries are used; missing
    /// entries keep libghostty's default and extra entries are ignored.
    public var palette: [TerminalRGB]

    public init(
        fontFamily: String?,
        fontSize: Float,
        foreground: TerminalRGB,
        background: TerminalRGB,
        cursor: TerminalRGB,
        selectionForeground: TerminalRGB,
        selectionBackground: TerminalRGB,
        palette: [TerminalRGB]
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selectionForeground = selectionForeground
        self.selectionBackground = selectionBackground
        self.palette = palette
    }

    /// Deep "aqua glass" preset: navy water background, sky foreground, Aero accent hues
    /// (coral, leaf, sun, aqua, sky) for the ANSI colours.
    public static let aero = TerminalAppearance(
        fontFamily: "SF Mono",
        fontSize: 13,
        foreground: TerminalRGB(hex: 0xE6F4FF),
        background: TerminalRGB(hex: 0x0B3D5C),
        cursor: TerminalRGB(hex: 0x7FDBFF),
        selectionForeground: TerminalRGB(hex: 0xFFFFFF),
        selectionBackground: TerminalRGB(hex: 0x1F6E9C),
        palette: ansiColors(
            black: 0x082B42, red: 0xF2605A, green: 0x6CCB4F, yellow: 0xFFC83D,
            blue: 0x1BA6E8, magenta: 0xC48BE8, cyan: 0x5BC8F5, white: 0xD6E6F0
        ) + ansiColors(
            black: 0x5E7F94, red: 0xFF8C86, green: 0x97E07C, yellow: 0xFFDC7A,
            blue: 0x62C3F5, magenta: 0xDDB1F5, cyan: 0xA6E6FB, white: 0xFFFFFF
        )
    )

    private static func ansiColors(
        black: UInt32, red: UInt32, green: UInt32, yellow: UInt32,
        blue: UInt32, magenta: UInt32, cyan: UInt32, white: UInt32
    ) -> [TerminalRGB] {
        [black, red, green, yellow, blue, magenta, cyan, white].map { TerminalRGB(hex: $0) }
    }

    /// Config lines for the colours (`key = value`), in libghostty config syntax.
    package var colorSettings: [(key: String, value: String)] {
        var settings: [(String, String)] = [
            ("foreground", foreground.hexString),
            ("background", background.hexString),
            ("cursor-color", cursor.hexString),
            ("selection-foreground", selectionForeground.hexString),
            ("selection-background", selectionBackground.hexString),
        ]
        for (index, color) in palette.prefix(16).enumerated() {
            settings.append(("palette", "\(index)=\(color.hexString)"))
        }
        return settings
    }

    /// Font family with characters that would break a config line removed.
    package var sanitizedFontFamily: String? {
        guard let fontFamily else { return nil }
        let cleaned = String(fontFamily.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Font size clamped to a range libghostty renders sensibly.
    package var clampedFontSize: Float {
        guard fontSize.isFinite else { return 13 }
        return min(max(fontSize, 6), 72)
    }
}
