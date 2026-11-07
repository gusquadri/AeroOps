import CoreGraphics
import SwiftUI
import Testing
@testable import AeroTheme

@Suite("SVG path data")
struct SVGPathTests {
    private func bounds(_ data: String) throws -> CGRect {
        try SVGPath.parse(data).boundingBoxOfPath
    }

    private func approx(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test("lines: absolute, relative, H/V, implicit line-tos after M, close")
    func lines() throws {
        #expect(approx(try bounds("M1 2L5 2L5 6Z"), CGRect(x: 1, y: 2, width: 4, height: 4)))
        #expect(approx(try bounds("m1 2l4 0 0 4z"), CGRect(x: 1, y: 2, width: 4, height: 4)))
        #expect(approx(try bounds("M1,2 5,2 5,6z"), CGRect(x: 1, y: 2, width: 4, height: 4)))
        #expect(approx(try bounds("M0 0H10V3h-2v1"), CGRect(x: 0, y: 0, width: 10, height: 4)))
    }

    @Test("compact numbers: signs and dots as separators, exponents")
    func numbers() throws {
        #expect(approx(try bounds("M.5.5L-1.5-.5"), CGRect(x: -1.5, y: -0.5, width: 2, height: 1)))
        #expect(approx(try bounds("M1e1 0L2E-1 1e0"), CGRect(x: 0.2, y: 0, width: 9.8, height: 1)))
    }

    @Test("after Z, relative commands start from the subpath's first point")
    func closeResetsCurrentPoint() throws {
        #expect(approx(try bounds("M10 10l1 0 0 1z l3 0 0 3z"), CGRect(x: 10, y: 10, width: 3, height: 3)))
    }

    @Test("arcs: a full circle from two half arcs, packed flags, zero radius is a line")
    func arcs() throws {
        #expect(approx(try bounds("M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0"), CGRect(x: 2, y: 2, width: 20, height: 20)))
        #expect(approx(try bounds("M2 12a10 10 0 1020 0a10 10 0 10-20 0"), CGRect(x: 2, y: 2, width: 20, height: 20)))
        #expect(approx(try bounds("M0 5A1 1 0 0 1 10 5"), CGRect(x: 0, y: 0, width: 10, height: 5)))
        #expect(approx(try bounds("M0 0A0 4 0 0 1 4 4"), CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    @Test("curves: C, S reflects the last control point, Q and T")
    func curves() throws {
        let cubic = try bounds("M0 0C0 10 10 10 10 0S20-10 20 0")
        #expect(cubic.minY < -5 && cubic.maxY > 5 && approx(CGRect(x: cubic.minX, y: 0, width: cubic.width, height: 0), CGRect(x: 0, y: 0, width: 20, height: 0)))
        let quad = try bounds("M0 0Q5 10 10 0T20 0")
        #expect(quad.maxY > 4 && quad.minY < -4)
    }

    @Test("invalid data throws")
    func invalid() {
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("10 10") }
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("M1") }
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("M1 1A1 1 0 2 0 3 3") }
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("M1 1X") }
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("M1 1z 2 2") }
    }
}

@Suite("System logos")
struct SystemLogoTests {
    @Test("every logo loads from the bundle, has a title and fits the 24 × 24 box", arguments: SystemLogo.allCases)
    func artwork(_ logo: SystemLogo) throws {
        let artwork = try SystemLogo.loadArtwork(logo)
        #expect(!artwork.title.isEmpty)
        let box = artwork.path.boundingRect
        #expect(box.minX >= -0.05 && box.minY >= -0.05 && box.maxX <= 24.05 && box.maxY <= 24.05, "\(logo): \(box)")
        #expect(max(box.width, box.height) > 22, "\(logo): \(box)")
        #expect(SystemLogo.artwork[logo] != nil)
    }

    @Test("titles come from the SVG, XML entities decoded")
    func titles() {
        #expect(SystemLogo.alpine.title == "Alpine Linux")
        #expect(SystemLogo.popOS.title == "Pop!_OS")
        #expect(SystemLogo.linux.title == "Linux")
    }

    @Test("the shape fits and centres the logo in its rect")
    func shape() {
        let rect = CGRect(x: 10, y: 20, width: 48, height: 24)
        let path = SystemLogoShape(logo: .ubuntu).path(in: rect)
        let box = path.boundingRect
        #expect(box.minX >= 22 - 0.1 && box.maxX <= 46 + 0.1)
        #expect(box.minY >= 20 - 0.1 && box.maxY <= 44 + 0.1)
    }

    @Test("os-release IDs pick their logo")
    func ids() {
        let cases: [(String, SystemLogo)] = [
            ("ubuntu", .ubuntu), ("debian", .debian), ("alpine", .alpine), ("fedora", .fedora),
            ("centos", .centOS), ("rhel", .redHat), ("rocky", .rocky), ("almalinux", .almaLinux),
            ("arch", .archLinux), ("opensuse-leap", .openSUSE), ("opensuse-tumbleweed", .openSUSE),
            ("sles", .suse), ("sle-micro", .suse), ("raspbian", .raspberryPi), ("nixos", .nixOS),
            ("pop", .popOS), ("linuxmint", .linuxMint), ("kali", .kali), ("ol", .oracleLinux),
            ("neon", .kdeNeon), ("void", .void), ("openwrt", .openWrt), ("amzn", .linux), ("Ubuntu", .ubuntu),
        ]
        for (id, logo) in cases {
            #expect(SystemLogo.match(id: id, kernel: "Linux 6.8.0 x86_64") == logo, "\(id)")
        }
    }

    @Test("ID_LIKE when the ID has no logo, closest first")
    func idLike() {
        #expect(SystemLogo.match(id: "tuxedo", idLike: ["ubuntu", "debian"]) == .ubuntu)
        #expect(SystemLogo.match(id: "navy", idLike: ["rhel", "centos", "fedora"]) == .redHat)
        #expect(SystemLogo.match(id: "nobara", idLike: ["fedora"]) == .fedora)
    }

    @Test("kernel: Debian-based appliances, systems without os-release, Tux and unknown")
    func kernels() {
        #expect(SystemLogo.match(id: "debian", kernel: "Linux 6.8.12-4-pve x86_64") == .proxmox)
        #expect(SystemLogo.match(id: "debian", kernel: "Linux 6.6.51+rpt-rpi-v8 aarch64") == .raspberryPi)
        #expect(SystemLogo.match(id: "debian", kernel: "Linux 6.6.44-production+truenas x86_64") == .trueNAS)
        #expect(SystemLogo.match(id: "slackware", kernel: "Linux 6.1.106-Unraid x86_64") == .unraid)
        #expect(SystemLogo.match(id: "ubuntu", kernel: "Linux 6.8.0-1012-raspi aarch64") == .ubuntu)
        #expect(SystemLogo.match(id: nil, kernel: "Darwin 27.0.0 arm64") == .apple)
        #expect(SystemLogo.match(id: nil, kernel: "FreeBSD 14.1-RELEASE amd64") == .freeBSD)
        #expect(SystemLogo.match(id: nil, kernel: "OpenBSD 7.6 amd64") == .openBSD)
        #expect(SystemLogo.match(id: nil, kernel: "NetBSD 10.0 amd64") == .netBSD)
        #expect(SystemLogo.match(id: "mystery", kernel: "Linux 5.10.0 x86_64") == .linux)
        #expect(SystemLogo.match(id: nil, kernel: "Linux 5.10.0 x86_64") == .linux)
        #expect(SystemLogo.match(id: nil, kernel: "SunOS 5.11 i86pc") == nil)
        #expect(SystemLogo.match(id: nil) == nil)
    }
}

@Suite("Status bubble contrast")
@MainActor
struct StatusBubbleContrastTests {
    @Test("white logos reach 3:1 on every bubble band (WCAG non-text contrast)",
          arguments: OrbTone.allCases, AeroVariant.allCases)
    func logoContrast(_ tone: OrbTone, _ variant: AeroVariant) {
        let ratio = RGB.contrast(RGB(Aero.text.onAccent, variant), RGB(AquaFill.bubble(tone).band, variant))
        #expect(ratio >= 3, "\(variant) white on \(tone) bubble: \(ratio.formatted2):1")
    }
}
