import Foundation

/// Follows the terminal state a byte stream leaves behind, so that a later part of the stream
/// can be replayed onto a fresh terminal as if the whole stream had been (see
/// ``TerminalHistory``).
///
/// It parses escape sequences just far enough to follow the modes a program sets and keeps
/// for a long time: DEC private modes (cursor keys, mouse reporting, bracketed paste, the
/// alternate screen, ...), the scroll region, keypad mode, the kitty keyboard flags,
/// modifyOtherKeys, the G0/G1 character sets and the current SGR attributes. Cursor position,
/// tab stops and screen contents are not followed; the replayed bytes rebuild those.
struct TerminalModeTracker: Sendable {
    // MARK: - Parser

    private enum ParseState: Sendable {
        case ground
        case escape
        case escapeIntermediate
        case controlSequence
        /// OSC, DCS, SOS, PM or APC, up to its terminator.
        case string
        /// An ESC inside a string: `\` ends it, anything else starts a new escape sequence.
        case stringEscape
    }

    private static let maxParameterBytes = 64

    private var parseState = ParseState.ground
    private var parameters: [UInt8] = []
    private var intermediates: [UInt8] = []
    private var parametersOverflowed = false
    private var stringIsOSC = false

    // MARK: - Followed state

    /// DEC private modes whose value differs from a fresh terminal's.
    private var privateModes: [Int: Bool] = [:]
    /// 47, 1047 or 1049 while the alternate screen is active.
    private(set) var alternateScreenMode: Int?
    /// 9, 1000, 1002 or 1003 while mouse reporting is on.
    private var mouseEventMode: Int?
    /// 1005, 1006, 1015 or 1016 while a mouse report format other than X10 is set.
    private var mouseFormatMode: Int?
    /// DECSTBM parameters while a scroll region is set.
    private var scrollRegion: [UInt8]?
    private var keypadApplicationMode = false
    /// Kitty keyboard flags, bottom first, for the main and the alternate screen.
    private var mainKeyboardFlags: [Int] = [0]
    private var alternateKeyboardFlags: [Int] = [0]
    /// xterm modifyOtherKeys level (`CSI > 4 ; n m`), 0 when off.
    private var modifyOtherKeys = 0
    private var characterSetG0 = UInt8(ascii: "B")
    private var characterSetG1 = UInt8(ascii: "B")
    private var shiftedOut = false
    /// SGR parameter lists since the attributes were last reset.
    private var graphicRendition: [[UInt8]] = []

    /// Modes that are on in a fresh terminal: autowrap (7) and the visible cursor (25).
    private static let defaultOnModes: Set<Int> = [7, 25]
    private static let followedModes: Set<Int> = [1, 5, 6, 7, 25, 1004, 2004]
    private static let alternateScreenModes: Set<Int> = [47, 1047, 1049]
    private static let mouseEventModes: Set<Int> = [9, 1000, 1002, 1003]
    private static let mouseFormatModes: Set<Int> = [1005, 1006, 1015, 1016]
    private static let maxKeyboardFlagsDepth = 8
    private static let maxGraphicRenditions = 32

    // MARK: - Input

    /// Whether a replay may start at `next`: outside any escape sequence and not inside a
    /// UTF-8 character.
    func isAtBoundary(next: UInt8) -> Bool {
        parseState == .ground && !(0x80...0xBF).contains(next)
    }

    mutating func consume(_ data: some DataProtocol) {
        for region in data.regions {
            region.withUnsafeBytes { buffer in
                for byte in buffer {
                    consume(byte)
                }
            }
        }
    }

    mutating func consume(_ byte: UInt8) {
        // CAN and SUB abort any sequence; ESC starts a new one (except as a string terminator).
        switch byte {
        case 0x18, 0x1A:
            parseState = .ground
            return
        case 0x1B where parseState != .string && parseState != .stringEscape:
            parseState = .escape
            intermediates.removeAll(keepingCapacity: true)
            return
        default:
            break
        }

        switch parseState {
        case .ground:
            if byte == 0x0E {
                shiftedOut = true
            } else if byte == 0x0F {
                shiftedOut = false
            }
        case .escape:
            escape(byte)
        case .escapeIntermediate:
            if (0x20...0x2F).contains(byte) {
                intermediates.append(byte)
            } else if (0x30...0x7E).contains(byte) {
                escapeDispatch(byte)
                parseState = .ground
            }
        case .controlSequence:
            controlSequence(byte)
        case .string:
            if byte == 0x1B {
                parseState = .stringEscape
            } else if byte == 0x07, stringIsOSC {
                parseState = .ground
            }
        case .stringEscape:
            if byte == UInt8(ascii: "\\") {
                parseState = .ground
            } else {
                parseState = .escape
                intermediates.removeAll(keepingCapacity: true)
                escape(byte)
            }
        }
    }

    private mutating func escape(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            break
        case UInt8(ascii: "["):
            parameters.removeAll(keepingCapacity: true)
            intermediates.removeAll(keepingCapacity: true)
            parametersOverflowed = false
            parseState = .controlSequence
        case UInt8(ascii: "]"):
            stringIsOSC = true
            parseState = .string
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            stringIsOSC = false
            parseState = .string
        case 0x20...0x2F:
            intermediates.append(byte)
            parseState = .escapeIntermediate
        case 0x30...0x7E:
            escapeDispatch(byte)
            parseState = .ground
        default:
            // C0 controls execute inside an escape sequence without ending it.
            break
        }
    }

    private mutating func escapeDispatch(_ final: UInt8) {
        switch (intermediates.first, final) {
        case (nil, UInt8(ascii: "c")):
            self = TerminalModeTracker()
        case (nil, UInt8(ascii: "=")):
            keypadApplicationMode = true
        case (nil, UInt8(ascii: ">")):
            keypadApplicationMode = false
        case (UInt8(ascii: "("), _):
            characterSetG0 = final
        case (UInt8(ascii: ")"), _):
            characterSetG1 = final
        default:
            break
        }
    }

    private mutating func controlSequence(_ byte: UInt8) {
        switch byte {
        case 0x30...0x3F:
            if parameters.count < Self.maxParameterBytes {
                parameters.append(byte)
            } else {
                parametersOverflowed = true
            }
        case 0x20...0x2F:
            intermediates.append(byte)
        case 0x40...0x7E:
            if !parametersOverflowed {
                controlSequenceDispatch(byte)
            }
            parseState = .ground
        default:
            break
        }
    }

    // MARK: - Control sequences

    private mutating func controlSequenceDispatch(_ final: UInt8) {
        let marker = parameters.first.flatMap { (0x3C...0x3F).contains($0) ? $0 : nil }
        let body = marker == nil ? parameters[...] : parameters.dropFirst()
        let values = Self.numbers(body)

        switch (marker, intermediates.first, final) {
        case (UInt8(ascii: "?"), nil, UInt8(ascii: "h")):
            values.compactMap(\.self).forEach { setPrivateMode($0, on: true) }
        case (UInt8(ascii: "?"), nil, UInt8(ascii: "l")):
            values.compactMap(\.self).forEach { setPrivateMode($0, on: false) }
        case (nil, nil, UInt8(ascii: "r")):
            scrollRegion = body.isEmpty ? nil : Array(body)
        case (nil, nil, UInt8(ascii: "m")):
            selectGraphicRendition(Array(body), values: values)
        case (UInt8(ascii: ">"), nil, UInt8(ascii: "m")):
            if values.first == 4 {
                modifyOtherKeys = values.count > 1 ? (values[1] ?? 0) : 0
            }
        case (UInt8(ascii: ">"), nil, UInt8(ascii: "u")):
            pushKeyboardFlags(values.first.flatMap(\.self) ?? 0)
        case (UInt8(ascii: "<"), nil, UInt8(ascii: "u")):
            popKeyboardFlags(max(1, values.first.flatMap(\.self) ?? 1))
        case (UInt8(ascii: "="), nil, UInt8(ascii: "u")):
            let flags = values.first.flatMap(\.self) ?? 0
            let mode = values.count > 1 ? (values[1] ?? 1) : 1
            setKeyboardFlags(flags, mode: mode)
        case (nil, UInt8(ascii: "!"), UInt8(ascii: "p")):
            softReset()
        default:
            break
        }
    }

    /// `;`-separated decimal parameters; `nil` for an empty one. Colon sub-parameters are
    /// kept with their parameter's digits ignored after the colon.
    private static func numbers(_ bytes: ArraySlice<UInt8>) -> [Int?] {
        guard !bytes.isEmpty else { return [] }
        var result: [Int?] = []
        var current: Int?
        var inSubparameter = false
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                guard !inSubparameter else { continue }
                current = min(99_999, (current ?? 0) * 10 + Int(byte - UInt8(ascii: "0")))
            case UInt8(ascii: ";"):
                result.append(current)
                current = nil
                inSubparameter = false
            case UInt8(ascii: ":"):
                inSubparameter = true
            default:
                break
            }
        }
        result.append(current)
        return result
    }

    private mutating func setPrivateMode(_ mode: Int, on: Bool) {
        if Self.followedModes.contains(mode) {
            privateModes[mode] = on == Self.defaultOnModes.contains(mode) ? nil : on
        } else if Self.alternateScreenModes.contains(mode) {
            if on {
                if alternateScreenMode == nil {
                    alternateKeyboardFlags = [0]
                }
                alternateScreenMode = mode
            } else {
                alternateScreenMode = nil
            }
        } else if Self.mouseEventModes.contains(mode) {
            mouseEventMode = on ? mode : nil
        } else if Self.mouseFormatModes.contains(mode) {
            mouseFormatMode = on ? mode : nil
        }
    }

    private mutating func selectGraphicRendition(_ body: [UInt8], values: [Int?]) {
        // `CSI m`, `CSI 0 m` and lists that start with 0 reset everything before them.
        if values.isEmpty || (values.first.flatMap(\.self) ?? 0) == 0 {
            graphicRendition.removeAll()
            guard values.count > 1 else { return }
        }
        if graphicRendition.count == Self.maxGraphicRenditions {
            graphicRendition.removeFirst()
        }
        graphicRendition.append(body)
    }

    private mutating func softReset() {
        privateModes[1] = nil
        privateModes[6] = nil
        privateModes[25] = nil
        keypadApplicationMode = false
        scrollRegion = nil
        characterSetG0 = UInt8(ascii: "B")
        characterSetG1 = UInt8(ascii: "B")
        shiftedOut = false
        graphicRendition.removeAll()
    }

    // MARK: - Kitty keyboard flags

    private var keyboardFlags: [Int] {
        get { alternateScreenMode == nil ? mainKeyboardFlags : alternateKeyboardFlags }
        set {
            if alternateScreenMode == nil {
                mainKeyboardFlags = newValue
            } else {
                alternateKeyboardFlags = newValue
            }
        }
    }

    private mutating func pushKeyboardFlags(_ flags: Int) {
        var stack = keyboardFlags
        stack.append(flags)
        if stack.count > Self.maxKeyboardFlagsDepth {
            stack.removeFirst()
        }
        keyboardFlags = stack
    }

    private mutating func popKeyboardFlags(_ count: Int) {
        var stack = keyboardFlags
        if count >= stack.count {
            stack = [0]
        } else {
            stack.removeLast(count)
        }
        keyboardFlags = stack
    }

    private mutating func setKeyboardFlags(_ flags: Int, mode: Int) {
        var stack = keyboardFlags
        let current = stack[stack.count - 1]
        switch mode {
        case 2: stack[stack.count - 1] = current | flags
        case 3: stack[stack.count - 1] = current & ~flags
        default: stack[stack.count - 1] = flags
        }
        keyboardFlags = stack
    }

    // MARK: - Output

    /// Bytes that put a fresh terminal into the followed state.
    var baseline: Data {
        var out = Data()
        func csi(_ text: String) {
            out.append(contentsOf: [0x1B, UInt8(ascii: "[")])
            out.append(contentsOf: Array(text.utf8))
        }
        func keyboard(_ stack: [Int]) {
            if stack[0] != 0 {
                csi("=\(stack[0]);1u")
            }
            for flags in stack.dropFirst() {
                csi(">\(flags)u")
            }
        }

        keyboard(mainKeyboardFlags)
        if let alternateScreenMode {
            csi("?\(alternateScreenMode)h")
            keyboard(alternateKeyboardFlags)
        }
        if let scrollRegion {
            out.append(contentsOf: [0x1B, UInt8(ascii: "[")] + scrollRegion + [UInt8(ascii: "r")])
        }
        for (mode, on) in privateModes.sorted(by: { $0.key < $1.key }) {
            csi("?\(mode)\(on ? "h" : "l")")
        }
        if let mouseEventMode {
            csi("?\(mouseEventMode)h")
        }
        if let mouseFormatMode {
            csi("?\(mouseFormatMode)h")
        }
        if keypadApplicationMode {
            out.append(contentsOf: [0x1B, UInt8(ascii: "=")])
        }
        if modifyOtherKeys != 0 {
            csi(">4;\(modifyOtherKeys)m")
        }
        if characterSetG0 != UInt8(ascii: "B") {
            out.append(contentsOf: [0x1B, UInt8(ascii: "("), characterSetG0])
        }
        if characterSetG1 != UInt8(ascii: "B") {
            out.append(contentsOf: [0x1B, UInt8(ascii: ")"), characterSetG1])
        }
        if shiftedOut {
            out.append(0x0E)
        }
        for rendition in graphicRendition {
            out.append(contentsOf: [0x1B, UInt8(ascii: "[")] + rendition + [UInt8(ascii: "m")])
        }
        return out
    }
}
