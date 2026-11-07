import SwiftUI

/// A glossy aqua gel tile with a white folder inside, the folder counterpart of
/// ``StatusBubble``. `isOpen` shows the folder open, for a drop target that is about to take a
/// host.
///
/// ```swift
/// FolderGel(size: 44)
/// FolderGel(size: 44, isOpen: isTargeted)
/// ```
public struct FolderGel: View {
    /// Width and height in points.
    public let size: CGFloat
    /// Shows the folder open (a drop target under a dragged host).
    public let isOpen: Bool

    /// Creates a gel of `size` points (default 40).
    public init(size: CGFloat = 40, isOpen: Bool = false) {
        self.size = size
        self.isOpen = isOpen
    }

    /// The gel.
    public var body: some View {
        SymbolGel(systemImage: isOpen ? "folder.fill.badge.plus" : "folder.fill", size: size)
    }
}

/// A glossy aqua gel tile with a white SF Symbol inside: the primary Aqua gel (light top, deep
/// band, caustic bottom) in a rounded square, a specular cap and a dark rim.
///
/// ```swift
/// SymbolGel(systemImage: "server.rack", size: 32)
/// ```
public struct SymbolGel: View {
    /// The SF Symbol drawn in white.
    public let systemImage: String
    /// Width and height in points.
    public let size: CGFloat

    private var accessibility = AeroAccessibility()

    /// Creates a gel of `size` points (default 40) showing `systemImage`.
    public init(systemImage: String, size: CGFloat = 40) {
        self.systemImage = systemImage
        self.size = size
    }

    /// The gel.
    public var body: some View {
        let fill = AquaFill.primary
        let strong = accessibility.increaseContrast
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(fill.gradient)
            if !strong {
                shape.fill(EllipticalGradient(
                    colors: [fill.glow.opacity(0.85), fill.glow.opacity(0)],
                    center: UnitPoint(x: 0.5, y: 1.05),
                    startRadiusFraction: 0, endRadiusFraction: 0.55
                ))
            }
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(Aero.text.onAccent)
                .shadow(color: Aero.ink.opacity(0.55), radius: 0.5, x: 0, y: 0.6)
                .frame(width: size * 0.56, height: size * 0.56)
                .offset(y: size * 0.03)
                .contentTransition(.symbolEffect(.replace))
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.8, height: size * 0.4)
                .offset(y: -size * 0.24)
                .opacity(strong ? 0.5 : 1)
            shape.strokeBorder(fill.rim.opacity(strong ? 1 : 0.75), lineWidth: strong ? 1.5 : 1)
            shape
                .inset(by: 1)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.3)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: fill.rim.opacity(0.35), radius: size * 0.08, x: 0, y: size * 0.05)
        .accessibilityHidden(true)
    }
}

#Preview("FolderGel") {
    HStack(spacing: 16) {
        FolderGel(size: 28)
        FolderGel(size: 44)
        FolderGel(size: 44, isOpen: true)
        FolderGel(size: 64)
        SymbolGel(systemImage: "server.rack", size: 44)
    }
    .padding(32)
    .background { SkyBackground() }
}
