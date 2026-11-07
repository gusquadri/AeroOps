import CoreGraphics
import Foundation

/// A small parser for SVG path data (the `d` attribute, SVG 1.1 §8.3), enough for the bundled
/// ``SystemLogo`` artwork: every command (`M L H V C S Q T A Z`, absolute and relative), implicit
/// repeats, compact numbers (`-.5.5`, `1e-3`) and packed arc flags (`a1 1 0 011 1`). Elliptical
/// arcs are converted to their centre form (SVG 1.1 §F.6.5) and drawn as transformed unit-circle
/// arcs.
enum SVGPath {
    /// Path data that is not valid SVG.
    struct ParseError: Error, Equatable {
        /// Byte offset of the problem.
        let offset: Int
    }

    /// Parses `data` into a path in the SVG's user space (y grows downwards, as in SwiftUI).
    static func parse(_ data: String) throws -> CGPath {
        var builder = Builder(cursor: Cursor(bytes: Array(data.utf8)))
        while !builder.cursor.atEnd {
            try builder.step()
        }
        return builder.path
    }

    private typealias Handler = @Sendable (inout Builder, Bool) throws -> Void

    private static let handlers: [UInt8: Handler] = [
        UInt8(ascii: "m"): { try $0.move($1) },
        UInt8(ascii: "l"): { try $0.line($1) },
        UInt8(ascii: "h"): { try $0.horizontal($1) },
        UInt8(ascii: "v"): { try $0.vertical($1) },
        UInt8(ascii: "c"): { try $0.cubic($1) },
        UInt8(ascii: "s"): { try $0.smoothCubic($1) },
        UInt8(ascii: "q"): { try $0.quad($1) },
        UInt8(ascii: "t"): { try $0.smoothQuad($1) },
        UInt8(ascii: "a"): { try $0.arc($1) },
        UInt8(ascii: "z"): { $0.close($1) },
    ]

    private struct Builder {
        var cursor: Cursor
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var cubicControl: CGPoint?
        var quadControl: CGPoint?
        var command: UInt8?
        var needsMove = false
        var base = CGPoint.zero

        mutating func step() throws {
            let op = try nextCommand()
            let relative = op >= UInt8(ascii: "a")
            base = relative ? current : .zero
            if needsMove, op | 0x20 != UInt8(ascii: "m") {
                path.move(to: current)
                needsMove = false
            }
            guard let handler = SVGPath.handlers[op | 0x20] else { throw ParseError(offset: cursor.index) }
            cubicControl = nil
            quadControl = nil
            try handler(&self, relative)
            lastCubicControl = cubicControl
            lastQuadControl = quadControl
        }

        private mutating func nextCommand() throws -> UInt8 {
            if let letter = cursor.commandLetter() {
                command = letter
                return letter
            }
            guard let op = command, op | 0x20 != UInt8(ascii: "z") else { throw ParseError(offset: cursor.index) }
            return op
        }

        private mutating func point() throws -> CGPoint {
            let x = try cursor.number(), y = try cursor.number()
            return CGPoint(x: base.x + x, y: base.y + y)
        }

        mutating func move(_ relative: Bool) throws {
            let p = try point()
            path.move(to: p)
            current = p
            subpathStart = p
            needsMove = false
            command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
        }

        mutating func line(_ relative: Bool) throws {
            current = try point()
            path.addLine(to: current)
        }

        mutating func horizontal(_ relative: Bool) throws {
            let x = try cursor.number()
            current = CGPoint(x: relative ? current.x + x : x, y: current.y)
            path.addLine(to: current)
        }

        mutating func vertical(_ relative: Bool) throws {
            let y = try cursor.number()
            current = CGPoint(x: current.x, y: relative ? current.y + y : y)
            path.addLine(to: current)
        }

        mutating func cubic(_ relative: Bool) throws {
            let c1 = try point(), c2 = try point(), end = try point()
            addCubic(to: end, c1, c2)
        }

        mutating func smoothCubic(_ relative: Bool) throws {
            let c1 = lastCubicControl.map { SVGPath.reflect($0, about: current) } ?? current
            let c2 = try point(), end = try point()
            addCubic(to: end, c1, c2)
        }

        mutating func quad(_ relative: Bool) throws {
            let c = try point(), end = try point()
            addQuad(to: end, c)
        }

        mutating func smoothQuad(_ relative: Bool) throws {
            let c = lastQuadControl.map { SVGPath.reflect($0, about: current) } ?? current
            let end = try point()
            addQuad(to: end, c)
        }

        mutating func arc(_ relative: Bool) throws {
            let rx = try cursor.number(), ry = try cursor.number(), rotation = try cursor.number()
            let largeArc = try cursor.flag(), sweep = try cursor.flag()
            let end = try point()
            SVGPath.addArc(to: path, from: current, to: end, radii: CGSize(width: rx, height: ry),
                           rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
            current = end
        }

        mutating func close(_ relative: Bool) {
            path.closeSubpath()
            current = subpathStart
            needsMove = true
        }

        private mutating func addCubic(to end: CGPoint, _ c1: CGPoint, _ c2: CGPoint) {
            path.addCurve(to: end, control1: c1, control2: c2)
            cubicControl = c2
            current = end
        }

        private mutating func addQuad(to end: CGPoint, _ control: CGPoint) {
            path.addQuadCurve(to: end, control: control)
            quadControl = control
            current = end
        }
    }

    private static func reflect(_ point: CGPoint, about center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// Appends the SVG arc from `start` to `end` (SVG 1.1 §F.6.5, endpoint to centre form).
    private static func addArc(
        to path: CGMutablePath, from start: CGPoint, to end: CGPoint, radii: CGSize,
        rotationDegrees: CGFloat, largeArc: Bool, sweep: Bool
    ) {
        guard start != end else { return }
        var rx = abs(radii.width), ry = abs(radii.height)
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (max(0, numerator / denominator)).squareRoot() * (largeArc == sweep ? -1 : 1)
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let center = CGPoint(
            x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
            y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2
        )
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry
        let vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry
        let startAngle = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: phi)
            .scaledBy(x: rx, y: ry)
        path.addRelativeArc(center: .zero, radius: 1, startAngle: startAngle, delta: delta, transform: transform)
    }

    /// Reads numbers, flags and command letters from ASCII path data.
    private struct Cursor {
        let bytes: [UInt8]
        var index = 0

        var atEnd: Bool {
            mutating get {
                skipSeparators()
                return index >= bytes.count
            }
        }

        mutating func skipSeparators() {
            while index < bytes.count, Self.isSeparator(bytes[index]) { index += 1 }
        }

        /// The next byte if it is a command letter (consumed), else `nil`.
        mutating func commandLetter() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            let isLetter = (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            guard isLetter else { return nil }
            index += 1
            return byte
        }

        mutating func number() throws -> CGFloat {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var digits = skipDigits()
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                digits = skipDigits() || digits
            }
            guard digits else { throw ParseError(offset: start) }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                var lookahead = index + 1
                if lookahead < bytes.count, bytes[lookahead] == UInt8(ascii: "-") || bytes[lookahead] == UInt8(ascii: "+") {
                    lookahead += 1
                }
                if lookahead < bytes.count, Self.isDigit(bytes[lookahead]) {
                    index = lookahead
                    _ = skipDigits()
                }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
                throw ParseError(offset: start)
            }
            return CGFloat(value)
        }

        /// An arc flag: a single `0` or `1`, which may be followed directly by the next number.
        mutating func flag() throws -> Bool {
            skipSeparators()
            guard index < bytes.count else { throw ParseError(offset: index) }
            defer { index += 1 }
            switch bytes[index] {
            case UInt8(ascii: "0"): return false
            case UInt8(ascii: "1"): return true
            default: throw ParseError(offset: index)
            }
        }

        private mutating func skipDigits() -> Bool {
            let start = index
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
            return index > start
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        private static func isSeparator(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || byte == 0x0C
        }
    }
}
