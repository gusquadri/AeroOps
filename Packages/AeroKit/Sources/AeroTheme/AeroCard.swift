import SwiftUI

/// A glass card: Liquid Glass (`.glassEffect`) under the `glass.fill` tint (55% white by day,
/// smoked indigo by night), a gloss over the top 45%, a rim highlight and a soft shadow, at
/// `radius.card`.
///
/// Content defaults to `Aero.text.primary`. With Reduce Transparency the card is a solid fill;
/// with Increase Contrast the rim becomes a navy (by night lavender) hairline.
///
/// ```swift
/// AeroCard {
///     Text("web-01")
/// }
/// ```
public struct AeroCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    /// Creates a card around `content`, inset by `padding` points (default 16).
    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    /// The card.
    public var body: some View {
        content
            .foregroundStyle(Aero.text.primary)
            .padding(padding)
            .aeroGlass(in: RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous))
    }
}

extension View {
    /// Puts Aero glass behind this view in `shape`: the same surface as ``AeroCard`` (Liquid
    /// Glass, `glass.fill`, top gloss, rim, `shadow`), for custom shapes such as sheets,
    /// popovers or a toolbar pill. Honours Reduce Transparency and Increase Contrast.
    ///
    /// ```swift
    /// HStack { … }
    ///     .padding(8)
    ///     .aeroGlass(in: Capsule())
    /// ```
    public func aeroGlass<S: InsettableShape>(
        in shape: S, shadow: AeroShadow? = Aero.shadow.card
    ) -> some View {
        modifier(AeroGlassModifier(shape: shape, shadow: shadow))
    }
}

/// The glass surface behind ``AeroCard`` and ``SwiftUICore/View/aeroGlass(in:shadow:)``.
struct AeroGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let shadow: AeroShadow?
    private var accessibility = AeroAccessibility()
    @Environment(\.aeroLiquidGlass) private var liquidGlass

    init(shape: S, shadow: AeroShadow?) {
        self.shape = shape
        self.shadow = shadow
    }

    func body(content: Content) -> some View {
        let surface = content
            .background {
                ZStack {
                    if let shadow {
                        OuterShadow(shape: shape, shadow: shadow)
                    }
                    shape.fill(accessibility.reduceTransparency ? Aero.glass.solidFill : Aero.glass.fill)
                    shape.fill(Aero.glass.gloss)
                }
            }
        Group {
            if liquidGlass && !accessibility.reduceTransparency {
                surface.glassEffect(.regular, in: shape)
            } else {
                surface
            }
        }
        .overlay {
            if accessibility.increaseContrast {
                shape.strokeBorder(Aero.glass.rimStrong, lineWidth: 1.5)
            } else {
                ZStack {
                    shape.strokeBorder(Aero.ink.opacity(0.10), lineWidth: 0.5)
                    Aero.glass.rim.mask { shape.inset(by: 0.5).strokeBorder(lineWidth: 1) }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// A drop shadow cast only outside `shape`, so translucent glass is not darkened from within
/// and the card's text does not cast a shadow of its own.
struct OuterShadow<S: Shape>: View {
    let shape: S
    let shadow: AeroShadow

    var body: some View {
        let reach = shadow.blur * 2 + abs(shadow.x) + abs(shadow.y)
        shape
            .fill(.white)
            .aeroShadow(shadow)
            .mask {
                Rectangle()
                    .padding(-reach)
                    .overlay { shape.fill(.black).blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview("AeroCard") {
    AeroCard {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusOrb(tone: .healthy)
                Text("web-01").font(Aero.font(.title3, weight: .semibold))
            }
            Text("Ubuntu 24.04 · up 12 days")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
        }
    }
    .padding(40)
    .background { SkyBackground() }
}

#Preview("AeroCard: Reduce Transparency + Increase Contrast") {
    AeroCard {
        Text("Solid fill, strong rim").font(Aero.font(.headline))
    }
    .padding(40)
    .background { SkyBackground() }
    .environment(\.aeroAccessibilityOverride, .all)
}

#Preview("aeroGlass(in: Capsule())") {
    Text("Glass capsule")
        .font(Aero.font(.body, weight: .medium))
        .foregroundStyle(Aero.text.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .aeroGlass(in: Capsule())
        .padding(40)
        .background { SkyBackground() }
}
