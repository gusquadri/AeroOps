import AppKit
import SwiftUI
import Testing
@testable import AeroTheme

/// Renders ``AeroThemeShowcase`` with `ImageRenderer` to `build/theme-showcase.png`,
/// `build/theme-showcase-night.png` (Nightly Frutiger Aero) and an all-accessibility-settings
/// render of each, at the repo root, for visual review. `build/` is git-ignored.
///
/// `ImageRenderer` drops every view inside a `.glassEffect` (even `.identity`), so the render
/// turns Liquid Glass off (`aeroLiquidGlass = false`): cards show their `glass.fill`, gloss
/// and rim directly over the sky, without the glass's backdrop blur and refraction. It cannot
/// draw AppKit views either, so the gauges show still water (`aeroAnimatedWater = false`).
@Suite("Showcase render")
@MainActor
struct ShowcaseRenderTests {
    @Test("renders the showcase to build/theme-showcase.png")
    func showcase() throws {
        let image = try render(AeroThemeShowcase(), to: "theme-showcase.png")
        #expect(image.width == Int(AeroThemeShowcase.size.width * 2))
        let corner = try #require(pixel(of: image, x: 4, y: 4))
        #expect(corner.b > corner.r)
    }

    @Test("renders the accessibility variant to build/theme-showcase-accessibility.png")
    func accessibilityShowcase() throws {
        let view = AeroThemeShowcase().environment(\.aeroAccessibilityOverride, .all)
        let image = try render(view, to: "theme-showcase-accessibility.png")
        #expect(image.width == Int(AeroThemeShowcase.size.width * 2))
    }

    @Test("renders Nightly Frutiger Aero to build/theme-showcase-night.png")
    func nightShowcase() throws {
        let image = try render(AeroThemeShowcase(variant: .night), to: "theme-showcase-night.png")
        #expect(image.width == Int(AeroThemeShowcase.size.width * 2))
        let corner = try #require(pixel(of: image, x: 4, y: 4))
        #expect(corner.b > corner.r)
        #expect(Int(corner.r) + Int(corner.g) + Int(corner.b) < 3 * 110)
    }

    @Test("renders the night accessibility variant to build/theme-showcase-night-accessibility.png")
    func nightAccessibilityShowcase() throws {
        let view = AeroThemeShowcase(variant: .night).environment(\.aeroAccessibilityOverride, .all)
        let image = try render(view, to: "theme-showcase-night-accessibility.png")
        #expect(image.width == Int(AeroThemeShowcase.size.width * 2))
    }

    private func render(_ view: some View, to name: String) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view.environment(\.aeroLiquidGlass, false).environment(\.aeroAnimatedWater, false)
        )
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(AeroThemeShowcase.size)
        let image = try #require(renderer.cgImage, "ImageRenderer produced no image")
        let png = try #require(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        )
        let directory = Self.repoRoot.appending(path: "build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appending(path: name))
        return image
    }

    /// Repo root: …/Packages/AeroKit/Tests/AeroThemeTests/<this file>.
    private static let repoRoot: URL = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    private func pixel(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (UInt8(color.redComponent * 255), UInt8(color.greenComponent * 255), UInt8(color.blueComponent * 255))
    }
}
