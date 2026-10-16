import CoreGraphics
import Foundation
import SwiftUI

/// The logo of an operating system or distribution, drawn from the single-path SVGs in
/// `Logos/` (Simple Icons 16.35.0, unmodified, CC0-1.0). Each case's raw value is its file name.
/// The logos are trademarks of their owners; AeroOps shows them only to identify the operating
/// system a server runs. To add one, put the Simple Icons SVG in `Logos/`, add a case named
/// after the file and map its os-release `ID` in ``match(id:idLike:kernel:)``.
///
/// ``match(id:idLike:kernel:)`` picks the logo for a host from its os-release `ID` and `ID_LIKE`
/// and its `uname -srm` line; ``StatusBubble`` draws it inside the status orb.
///
/// ```swift
/// let logo = SystemLogo.match(id: "rocky", idLike: ["rhel", "centos", "fedora"], kernel: "Linux 5.14.0 x86_64")
/// StatusBubble(tone: .healthy, logo: logo)
/// ```
public enum SystemLogo: String, CaseIterable, Sendable, Hashable {
    case almaLinux = "almalinux"
    case alpine = "alpinelinux"
    case apple
    case archLinux = "archlinux"
    case centOS = "centos"
    case debian
    case deepin
    case elementary
    case endeavourOS = "endeavouros"
    case fedora
    case freeBSD = "freebsd"
    case garuda = "garudalinux"
    case gentoo
    case kali = "kalilinux"
    case kdeNeon = "kdeneon"
    /// Tux: any Linux without a more specific logo.
    case linux
    case linuxMint = "linuxmint"
    case manjaro
    case mxLinux = "mxlinux"
    case netBSD = "netbsd"
    case nixOS = "nixos"
    case openBSD = "openbsd"
    case openSUSE = "opensuse"
    case openWrt = "openwrt"
    case oracleLinux = "oracle"
    case popOS = "popos"
    case proxmox
    case raspberryPi = "raspberrypi"
    case redHat = "redhat"
    case rocky = "rockylinux"
    case slackware
    case suse
    case trueNAS = "truenas"
    case ubuntu
    case unraid
    case void = "voidlinux"
    case zorin

    /// The brand's name from the SVG's `<title>`, e.g. "Alpine Linux"; the raw value if the
    /// artwork is missing.
    public var title: String {
        Self.artwork[self]?.title ?? rawValue
    }

    /// The logo in its 24 × 24 design space; `nil` if the artwork is missing from the bundle.
    var designPath: Path? {
        Self.artwork[self]?.path
    }

    // MARK: - Matching

    /// The logo for a host, or `nil` for a system without one (the bubble then shows a generic
    /// server glyph).
    ///
    /// - Parameters:
    ///   - id: os-release `ID`, e.g. `ubuntu`, `rhel`, `opensuse-leap`.
    ///   - idLike: os-release `ID_LIKE`, closest first; used when `id` has no logo.
    ///   - kernel: `uname -srm`, e.g. `Linux 6.8.12-4-pve x86_64` or `FreeBSD 14.1-RELEASE amd64`.
    ///     Picks the logo for systems without os-release (macOS, the BSDs), for appliances that
    ///     keep Debian's `ID` (Proxmox VE, Raspberry Pi OS, TrueNAS SCALE), and Tux for any
    ///     other Linux.
    public static func match(id: String?, idLike: [String] = [], kernel: String? = nil) -> SystemLogo? {
        let id = id?.lowercased() ?? ""
        let kernel = kernel?.lowercased() ?? ""
        let release = kernel.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        if release.contains("unraid") { return .unraid }
        if id.isEmpty || id == "debian" {
            if release.hasSuffix("-pve") || release.contains("-pve-") { return .proxmox }
            if release.contains("truenas") { return .trueNAS }
            if release.contains("rpi") { return .raspberryPi }
        }
        for candidate in [id] + idLike.map({ $0.lowercased() }) {
            if let logo = byID(candidate) { return logo }
        }
        switch kernel.split(separator: " ").first.map(String.init) ?? "" {
        case "darwin": return .apple
        case "freebsd": return .freeBSD
        case "openbsd": return .openBSD
        case "netbsd": return .netBSD
        case "linux": return .linux
        default: return nil
        }
    }

    /// The logo for one os-release identifier.
    private static func byID(_ id: String) -> SystemLogo? {
        if id.hasPrefix("opensuse") { return .openSUSE }
        if id.hasPrefix("sle") { return .suse }
        return idTable[id]
    }

    private static let idTable: [String: SystemLogo] = [
        "almalinux": .almaLinux,
        "alpine": .alpine,
        "amzn": .linux, // Amazon Linux's ID_LIKE (centos rhel fedora) would show someone else's logo.
        "arch": .archLinux, "archarm": .archLinux, "archlinux": .archLinux,
        "centos": .centOS,
        "debian": .debian,
        "deepin": .deepin,
        "elementary": .elementary,
        "endeavouros": .endeavourOS,
        "fedora": .fedora,
        "freebsd": .freeBSD,
        "garuda": .garuda,
        "gentoo": .gentoo,
        "kali": .kali,
        "neon": .kdeNeon,
        "linuxmint": .linuxMint,
        "macos": .apple,
        "manjaro": .manjaro, "manjaro-arm": .manjaro,
        "mx": .mxLinux,
        "netbsd": .netBSD,
        "nixos": .nixOS,
        "ol": .oracleLinux,
        "openbsd": .openBSD,
        "openwrt": .openWrt,
        "pop": .popOS,
        "raspbian": .raspberryPi,
        "rhel": .redHat,
        "rocky": .rocky,
        "slackware": .slackware,
        "suse": .suse,
        "truenas": .trueNAS,
        "ubuntu": .ubuntu,
        "unraid": .unraid,
        "void": .void,
        "zorin": .zorin,
    ]

    // MARK: - Artwork

    struct Artwork: Sendable {
        let title: String
        let path: Path
    }

    /// Every logo, parsed once on first use.
    static let artwork: [SystemLogo: Artwork] = {
        var result: [SystemLogo: Artwork] = [:]
        for logo in allCases {
            if let artwork = try? loadArtwork(logo) { result[logo] = artwork }
        }
        return result
    }()

    /// Reads `Logos/<rawValue>.svg`: its `<title>` and the `d` of its single `<path>`, in a
    /// 24 × 24 `viewBox`.
    static func loadArtwork(_ logo: SystemLogo) throws -> Artwork {
        guard let url = Bundle.module.url(forResource: logo.rawValue, withExtension: "svg", subdirectory: "Logos") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let svg = try String(contentsOf: url, encoding: .utf8)
        guard svg.contains(#"viewBox="0 0 24 24""#), let data = attribute("d", in: svg) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let title = text(between: "<title>", and: "</title>", in: svg) ?? logo.rawValue
        return Artwork(title: unescapeXML(title), path: Path(try SVGPath.parse(data)))
    }

    private static func attribute(_ name: String, in svg: String) -> String? {
        text(between: " \(name)=\"", and: "\"", in: svg)
    }

    private static func text(between open: String, and close: String, in string: String) -> String? {
        guard let start = string.range(of: open),
              let end = string.range(of: close, range: start.upperBound..<string.endIndex)
        else { return nil }
        return String(string[start.upperBound..<end.lowerBound])
    }

    private static func unescapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// A ``SystemLogo`` as a shape, scaled to fit the proposed rectangle and centred; fill it with any
/// style. Empty if the artwork is missing.
///
/// ```swift
/// SystemLogoShape(logo: .ubuntu)
///     .fill(.white)
///     .frame(width: 20, height: 20)
/// ```
public struct SystemLogoShape: Shape {
    /// The logo to draw.
    public let logo: SystemLogo

    /// Creates the shape.
    public init(logo: SystemLogo) {
        self.logo = logo
    }

    /// The logo fitted into `rect`.
    public func path(in rect: CGRect) -> Path {
        guard let path = logo.designPath else { return Path() }
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
            .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}
