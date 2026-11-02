import SwiftUI

/// The accessibility settings every Aero component honours, read from the environment:
/// Reduce Transparency (solid fills), Increase Contrast (stronger rims and text) and
/// Reduce Motion (no animated transitions).
///
/// SwiftUI's environment values for these are read-only, so previews and the showcase render
/// test force them through the internal ``EnvironmentValues/aeroAccessibilityOverride``.
struct AeroAccessibility: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.aeroAccessibilityOverride) private var override

    /// Solid fills instead of glass.
    var reduceTransparency: Bool { override?.reduceTransparency ?? systemReduceTransparency }
    /// Stronger rims, primary-colour secondary text, calmer background.
    var increaseContrast: Bool { override?.increaseContrast ?? (systemContrast == .increased) }
    /// No animated transitions.
    var reduceMotion: Bool { override?.reduceMotion ?? systemReduceMotion }

    /// `animation`, or `nil` with Reduce Motion.
    func animation(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Forced accessibility settings for previews and render tests.
struct AeroAccessibilityOverride: Sendable, Equatable {
    var reduceTransparency = false
    var increaseContrast = false
    var reduceMotion = false

    /// Everything on.
    static let all = AeroAccessibilityOverride(
        reduceTransparency: true, increaseContrast: true, reduceMotion: true
    )
}

private struct AeroAccessibilityOverrideKey: EnvironmentKey {
    static let defaultValue: AeroAccessibilityOverride? = nil
}

private struct AeroLiquidGlassKey: EnvironmentKey {
    static let defaultValue = true
}

private struct AeroAnimatedWaterKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Forces Aero accessibility settings regardless of the system (previews and tests only).
    var aeroAccessibilityOverride: AeroAccessibilityOverride? {
        get { self[AeroAccessibilityOverrideKey.self] }
        set { self[AeroAccessibilityOverrideKey.self] = newValue }
    }

    /// Whether glass surfaces use `.glassEffect`. `ImageRenderer` drops any view inside a
    /// `.glassEffect` (even `.identity`), so the showcase render test turns it off and the
    /// surfaces fall back to their own fill, gloss and rim layers.
    var aeroLiquidGlass: Bool {
        get { self[AeroLiquidGlassKey.self] }
        set { self[AeroLiquidGlassKey.self] = newValue }
    }

    /// Whether the gauge water moves. The live water is a platform view, which `ImageRenderer`
    /// cannot draw, so the showcase render test turns it off and the gauges show still water.
    var aeroAnimatedWater: Bool {
        get { self[AeroAnimatedWaterKey.self] }
        set { self[AeroAnimatedWaterKey.self] = newValue }
    }
}
