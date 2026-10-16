import Foundation

/// Something in a program's output that the session acts on, read by the
/// ``TerminalModeTracker`` that follows the live output.
enum TerminalOutputEvent: Sendable, Hashable {
    /// BEL.
    case bell
    /// OSC 9 (iTerm2) or OSC 777 (`notify`) desktop notification, as sent.
    case notification(title: String, body: String)
    /// OSC 9;4 progress report; `nil` removes it.
    case progress(TerminalProgress?)
    /// OSC 133;C: the shell started running a command.
    case commandStarted
    /// OSC 133;D: the command ended, with its exit status when the shell sent one.
    case commandFinished(exitCode: Int?)
}

/// Follows the terminal state a byte stream leaves behind, so that a later part of the stream
/// can be replayed onto a fresh terminal as if the whole stream had been (see
/// ``TerminalHistory``).
///
/// It parses escape sequences just far enough to follow the modes a program sets and keeps
/// for a long time: DEC private modes (cursor keys, mouse reporting, bracketed paste, the
/// alternate screen, ...), the scroll region, keypad mode, the kitty keyboard flags,
/// modifyOtherKeys, the G0/G1 character sets, the current SGR attributes, the cursor shape,
/// and the palette and default colours a program set (OSC 4, 10, 11, 12). The cursor that
/// DECSC, mode 1048 and mode 1049 save is followed for what restoring it brings back (SGR,
/// character sets, origin mode). Cursor position, tab stops and screen contents are not
/// followed; the replayed bytes rebuild those. It follows libghostty's model: each screen has
/// its own kitty keyboard flags, cursor shape and saved cursor; the other state is shared.
///
/// It also counts the bytes of kitty graphics commands (the history budgets images apart from
/// text) and reads the working directory a shell reports with OSC 7. libghostty ignores OSC 7
/// from a host other than this Mac, which every ssh session is.
///
/// With ``collectsEvents`` on it also collects ``TerminalOutputEvent``s (bell, notifications,
/// progress, command start and end). Only the tracker that follows the live output does: it
/// sees every byte once, also while the session has no surface, and never a replay.
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
    /// OSC strings are kept up to this length to read OSC 4 (a whole palette is about 5 KB)
    /// and OSC 7; longer ones (OSC 52) are skipped.
    private static let maxOSCBytes = 16 << 10
    /// Longest colour spec kept from OSC 4, 10, 11 and 12.
    private static let maxColorSpecBytes = 64

    private var parseState = ParseState.ground
    private var parameters: [UInt8] = []
    private var intermediates: [UInt8] = []
    private var parametersOverflowed = false
    private var stringIsOSC = false
    private var stringIsApplicationCommand = false
    /// Bytes of the current string so far.
    private var stringLength = 0
    /// The current string is a kitty graphics command (APC starting with `G`).
    private var stringIsGraphics = false
    /// The current OSC string, while short enough to be read.
    private var oscBytes: [UInt8] = []
    private var oscOverflowed = false

    /// Bytes inside kitty graphics commands so far. Not reset by RIS.
    private(set) var graphicsByteCount = 0
    /// The working directory from the last OSC 7 (`file://host/path`), as a path on that host;
    /// `nil` before one came. Not reset by RIS.
    private(set) var workingDirectory: String?
    /// Collect ``TerminalOutputEvent``s for ``takeEvents()``.
    var collectsEvents = false
    private var events: [TerminalOutputEvent] = []
    /// How many times the active screen changed: the alternate screen was entered or left
    /// (also by RIS). Not reset by RIS.
    private(set) var screenSwitches = 0
    /// The mode of the last screen change: 47, 1047 or 1049; `nil` for RIS.
    private(set) var lastScreenSwitchMode: Int?

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
    /// DECSCUSR shape (0 for the configured default) on the main and the alternate screen.
    private var mainCursorStyle = 0
    private var alternateCursorStyle = 0
    /// What DECSC (or mode 1048, or entering mode 1049) saved on the main and the alternate
    /// screen; `nil` before anything was.
    private var mainSavedCursor: SavedCursor?
    private var alternateSavedCursor: SavedCursor?
    /// OSC 4 colour specs by palette index, as sent.
    private var palette: [Int: [UInt8]] = [:]
    /// OSC 10, 11 and 12 colour specs (foreground, background, cursor) by OSC number, as sent.
    private var dynamicColors: [Int: [UInt8]] = [:]

    /// The state DECRC restores.
    private struct SavedCursor: Sendable, Equatable {
        var graphicRendition: [[UInt8]]
        var characterSetG0: UInt8
        var characterSetG1: UInt8
        var shiftedOut: Bool
        var originMode: Bool
    }

    /// Modes that are on in a fresh terminal: autowrap (7) and the visible cursor (25).
    private static let defaultOnModes: Set<Int> = [7, 25]
    /// Modes whose fresh value comes from the configuration: cursor blinking (12) and grapheme
    /// clustering (2027). Kept as last set; a replay sets them only when the output did.
    private static let configuredModes: Set<Int> = [12, 2027]
    private static let followedModes: Set<Int> = [1, 5, 6, 7, 12, 25, 1004, 2004, 2027, 2031, 2048]
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

    /// The events since the last call (only with ``collectsEvents``).
    mutating func takeEvents() -> [TerminalOutputEvent] {
        defer { events.removeAll() }
        return events
    }

    mutating func consume(_ data: some DataProtocol) {
        for region in data.regions {
            region.withUnsafeBytes { buffer in
                _ = consume(buffer, stoppingAtScreenSwitch: false)
            }
        }
    }

    /// Consumes `data` up to and including the byte that changes the active screen (see
    /// ``screenSwitches``), or all of it when none does, and returns how many bytes it consumed.
    mutating func consumeUntilScreenSwitch(_ data: Data) -> Int {
        data.withUnsafeBytes { buffer in
            consume(buffer, stoppingAtScreenSwitch: true)
        }
    }

    private mutating func consume(_ buffer: UnsafeRawBufferPointer, stoppingAtScreenSwitch: Bool) -> Int {
        let switches = screenSwitches
        var index = 0
        while index < buffer.count {
            // Fast paths for text and for the payload of strings that are not read (images):
            // their bytes change nothing that is followed.
            switch parseState {
            case .ground:
                while index < buffer.count, !Self.actsInGround(buffer[index]) {
                    index += 1
                }
            case .string where !stringIsOSC && stringLength > 0:
                let start = index
                while index < buffer.count, !Self.endsString(buffer[index]) {
                    index += 1
                }
                stringLength += index - start
                if stringIsGraphics {
                    graphicsByteCount += index - start
                }
            default:
                break
            }
            guard index < buffer.count else { break }
            consume(buffer[index])
            index += 1
            if stoppingAtScreenSwitch, screenSwitches != switches { break }
        }
        return index
    }

    /// The bytes ``consume(_:)-(UInt8)`` acts on in the ground state.
    private static func actsInGround(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x07, 0x0E, 0x0F, 0x18, 0x1A, 0x1B: true
        default: false
        }
    }

    /// The bytes that end (or abort) a string other than OSC.
    private static func endsString(_ byte: UInt8) -> Bool {
        byte == 0x1B || byte == 0x18 || byte == 0x1A
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
            } else if byte == 0x07, collectsEvents, events.last != .bell {
                events.append(.bell)
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
                endString()
                parseState = .ground
            } else {
                stringByte(byte)
            }
        case .stringEscape:
            if byte == UInt8(ascii: "\\") {
                endString()
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
            startString(osc: true, applicationCommand: false)
        case UInt8(ascii: "_"):
            startString(osc: false, applicationCommand: true)
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"):
            startString(osc: false, applicationCommand: false)
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
            var fresh = TerminalModeTracker()
            fresh.graphicsByteCount = graphicsByteCount
            fresh.workingDirectory = workingDirectory
            fresh.collectsEvents = collectsEvents
            fresh.events = events
            fresh.screenSwitches = screenSwitches
            fresh.lastScreenSwitchMode = lastScreenSwitchMode
            if alternateScreenMode != nil {
                fresh.screenSwitches += 1
                fresh.lastScreenSwitchMode = nil
            }
            self = fresh
        case (nil, UInt8(ascii: "7")):
            saveCursor()
        case (nil, UInt8(ascii: "8")):
            restoreCursor()
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

    // MARK: - Strings

    private mutating func startString(osc: Bool, applicationCommand: Bool) {
        stringIsOSC = osc
        stringIsApplicationCommand = applicationCommand
        stringIsGraphics = false
        stringLength = 0
        oscBytes.removeAll(keepingCapacity: true)
        oscOverflowed = false
        parseState = .string
    }

    private mutating func stringByte(_ byte: UInt8) {
        if stringIsApplicationCommand {
            if stringLength == 0 {
                stringIsGraphics = byte == UInt8(ascii: "G")
            }
            if stringIsGraphics {
                graphicsByteCount += 1
            }
        } else if stringIsOSC, !oscOverflowed {
            if oscBytes.count < Self.maxOSCBytes {
                oscBytes.append(byte)
            } else {
                oscOverflowed = true
                oscBytes.removeAll()
            }
        }
        stringLength += 1
    }

    /// A string ended with its terminator.
    private mutating func endString() {
        guard stringIsOSC, !oscOverflowed else { return }
        let separator = oscBytes.firstIndex(of: UInt8(ascii: ";"))
        let command = oscBytes[..<(separator ?? oscBytes.endIndex)]
        let value = separator.map { oscBytes[($0 + 1)...] } ?? []
        let number = command.count <= 3 ? Int(String(decoding: command, as: UTF8.self)) : nil
        switch number {
        case 7:
            if let path = Self.workingDirectory(osc7: value) {
                workingDirectory = path
            }
        case 4:
            setPalette(value)
        case 104:
            resetPalette(value)
        case 10, 11, 12:
            setDynamicColors(value, from: number ?? 10)
        case 110, 111, 112:
            dynamicColors[(number ?? 110) - 100] = nil
        default:
            if collectsEvents, let event = Self.event(osc: String(decoding: command, as: UTF8.self), String(decoding: value, as: UTF8.self)) {
                events.append(event)
            }
        }
    }

    /// OSC 4: `index;spec` pairs. A `?` spec asks for the colour and changes nothing.
    private mutating func setPalette(_ value: ArraySlice<UInt8>) {
        let fields = value.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        for pair in stride(from: 0, to: fields.count - 1, by: 2) {
            guard let index = Self.number(fields[pair]), index <= 255, Self.isColorSpec(fields[pair + 1]) else { continue }
            palette[index] = Array(fields[pair + 1])
        }
    }

    /// OSC 104: resets the listed palette indexes, or all of them.
    private mutating func resetPalette(_ value: ArraySlice<UInt8>) {
        let indexes = value.split(separator: UInt8(ascii: ";")).compactMap { Self.number($0) }
        if indexes.isEmpty {
            palette.removeAll()
        } else {
            indexes.forEach { palette[$0] = nil }
        }
    }

    /// OSC 10, 11 or 12: each spec sets the next of the three, like xterm's `OSC 10;fg;bg`.
    private mutating func setDynamicColors(_ value: ArraySlice<UInt8>, from first: Int) {
        for (offset, spec) in value.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false).enumerated() {
            let number = first + offset
            guard number <= 12 else { break }
            if Self.isColorSpec(spec) {
                dynamicColors[number] = Array(spec)
            }
        }
    }

    private static func isColorSpec(_ spec: ArraySlice<UInt8>) -> Bool {
        !spec.isEmpty && spec.count <= maxColorSpecBytes && !spec.elementsEqual("?".utf8)
            && spec.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private static func number(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty, bytes.count <= 5, bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: bytes, as: UTF8.self))
    }

    /// The event an OSC 9, 777 or 133 string stands for.
    static func event(osc command: String, _ value: String) -> TerminalOutputEvent? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        switch command {
        case "9":
            if fields.first == "4" {
                return progressEvent(fields.dropFirst())
            }
            // ConEmu's other OSC 9 commands (9;1 sleep, 9;9 working directory, ...) are numbers.
            if let first = fields.first, !first.isEmpty, first.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return nil
            }
            return value.isEmpty ? nil : .notification(title: "", body: value)
        case "777":
            guard fields.count >= 2, fields[0] == "notify" else { return nil }
            let body = fields.count > 2 ? fields[2...].joined(separator: ";") : ""
            return .notification(title: String(fields[1]), body: body)
        case "133":
            switch fields.first {
            case "C": return .commandStarted
            case "D": return .commandFinished(exitCode: fields.count > 1 ? Int(fields[1]) : nil)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `OSC 9;4;<state>;<percent>`: 0 removes, 1 sets, 2 error, 3 indeterminate, 4 paused.
    private static func progressEvent(_ fields: ArraySlice<Substring>) -> TerminalOutputEvent? {
        let state = fields.first.flatMap { Int($0) } ?? 0
        let percent = fields.count > 1 ? Int(fields[fields.startIndex + 1]).map { min(100, max(0, $0)) } : nil
        switch state {
        case 0: return .progress(nil)
        case 1: return .progress(TerminalProgress(state: .running, percent: percent ?? 0))
        case 2: return .progress(TerminalProgress(state: .failed, percent: percent))
        case 3: return .progress(TerminalProgress(state: .indeterminate, percent: nil))
        case 4: return .progress(TerminalProgress(state: .paused, percent: percent))
        default: return nil
        }
    }

    /// The path in an OSC 7 value: `file://host/path` (percent-encoded) or
    /// `kitty-shell-cwd://host/path` (as written). `nil` for an empty or unusable value.
    static func workingDirectory(osc7 value: ArraySlice<UInt8>) -> String? {
        let text = String(decoding: value, as: UTF8.self)
        for (scheme, percentEncoded) in [("file://", true), ("kitty-shell-cwd://", false)] where text.hasPrefix(scheme) {
            let rest = text.dropFirst(scheme.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let raw = String(rest[slash...])
            let path = percentEncoded ? (raw.removingPercentEncoding ?? raw) : raw
            guard path.utf8.count <= 4096,
                  !path.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) })
            else { return nil }
            return path
        }
        return nil
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
        case (nil, UInt8(ascii: " "), UInt8(ascii: "q")):
            setCursorStyle(values.first.flatMap(\.self) ?? 0)
        case (nil, nil, UInt8(ascii: "s")) where body.isEmpty:
            saveCursor()
        case (nil, nil, UInt8(ascii: "u")) where body.isEmpty:
            restoreCursor()
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
            let isDefault = !Self.configuredModes.contains(mode) && on == Self.defaultOnModes.contains(mode)
            privateModes[mode] = isDefault ? nil : on
        } else if Self.alternateScreenModes.contains(mode) {
            switchScreen(mode, alternate: on)
        } else if mode == 1048 {
            if on {
                saveCursor()
            } else {
                restoreCursor()
            }
        } else if Self.mouseEventModes.contains(mode) {
            mouseEventMode = on ? mode : nil
        } else if Self.mouseFormatModes.contains(mode) {
            mouseFormatMode = on ? mode : nil
        }
    }

    /// Modes 47, 1047 and 1049, as libghostty implements them after xterm: 1049 saves the
    /// cursor before entering and restores it after leaving; entering copies the cursor (its
    /// pen and shape) to the alternate screen, and leaving with 47 or 1047 copies it back.
    private mutating func switchScreen(_ mode: Int, alternate: Bool) {
        if alternate {
            if mode == 1049 {
                saveCursor()
            }
            if alternateScreenMode == nil {
                alternateKeyboardFlags = [0]
                alternateCursorStyle = mainCursorStyle
                screenSwitches += 1
                lastScreenSwitchMode = mode
            }
            alternateScreenMode = mode
        } else {
            if alternateScreenMode != nil {
                if mode != 1049 {
                    mainCursorStyle = alternateCursorStyle
                }
                alternateScreenMode = nil
                screenSwitches += 1
                lastScreenSwitchMode = mode
            }
            if mode == 1049 {
                restoreCursor()
            }
        }
    }

    private mutating func saveCursor() {
        let saved = SavedCursor(
            graphicRendition: graphicRendition,
            characterSetG0: characterSetG0,
            characterSetG1: characterSetG1,
            shiftedOut: shiftedOut,
            originMode: privateModes[6] == true
        )
        if alternateScreenMode == nil {
            mainSavedCursor = saved
        } else {
            alternateSavedCursor = saved
        }
    }

    /// Without a saved cursor, DECRC restores a fresh terminal's.
    private mutating func restoreCursor() {
        let saved = (alternateScreenMode == nil ? mainSavedCursor : alternateSavedCursor) ?? SavedCursor(
            graphicRendition: [],
            characterSetG0: UInt8(ascii: "B"),
            characterSetG1: UInt8(ascii: "B"),
            shiftedOut: false,
            originMode: false
        )
        graphicRendition = saved.graphicRendition
        characterSetG0 = saved.characterSetG0
        characterSetG1 = saved.characterSetG1
        shiftedOut = saved.shiftedOut
        privateModes[6] = saved.originMode ? true : nil
    }

    /// DECSCUSR: 1 to 6 pick a shape and whether it blinks (odd ones do), 0 the configured ones.
    private mutating func setCursorStyle(_ style: Int) {
        guard (0...6).contains(style) else { return }
        if alternateScreenMode == nil {
            mainCursorStyle = style
        } else {
            alternateCursorStyle = style
        }
        privateModes[12] = style == 0 ? nil : style % 2 == 1
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

    /// The kitty keyboard flags in effect on the active screen; 0 when the program set none.
    var activeKeyboardFlags: Int {
        keyboardFlags.last ?? 0
    }

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

    /// A copy that collects no events, to follow part of the output from here on.
    var withoutEvents: TerminalModeTracker {
        var copy = self
        copy.collectsEvents = false
        copy.events.removeAll()
        return copy
    }

    /// Bytes that put a fresh terminal into the followed state.
    var baseline: Data {
        changes(since: TerminalModeTracker())
    }

    /// Bytes that take a terminal in the `earlier` state to this one (as far as followed).
    func changes(since earlier: TerminalModeTracker) -> Data {
        var out = Data()
        // What the terminal is in so far: each sequence written goes through it too, so what
        // one sequence changes as a side effect (DECSCUSR sets blinking, leaving 1049 restores
        // the cursor) is seen by the comparisons after it.
        var terminal = earlier.withoutEvents
        func write(_ bytes: [UInt8]) {
            out.append(contentsOf: bytes)
            terminal.consume(bytes)
        }
        func csi(_ text: String) {
            write([0x1B, UInt8(ascii: "[")] + Array(text.utf8))
        }
        func osc(_ text: [UInt8]) {
            write([0x1B, UInt8(ascii: "]")] + text + [0x1B, UInt8(ascii: "\\")])
        }
        /// The kitty keyboard flags and cursor shape of the terminal's active screen.
        func keyboardAndCursor(_ stack: [Int], _ cursorStyle: Int) {
            if stack != terminal.keyboardFlags {
                if terminal.keyboardFlags != [0] {
                    csi("<\(Self.maxKeyboardFlagsDepth)u")
                }
                if stack[0] != 0 {
                    csi("=\(stack[0]);1u")
                }
                for flags in stack.dropFirst() {
                    csi(">\(flags)u")
                }
            }
            if cursorStyle != terminal.activeCursorStyle {
                csi("\(cursorStyle) q")
            }
        }

        // Each screen has its own keyboard flags and cursor shape: set the main screen's before
        // entering the alternate one.
        if alternateScreenMode != nil, terminal.alternateScreenMode == nil {
            keyboardAndCursor(mainKeyboardFlags, mainCursorStyle)
        }
        if alternateScreenMode != terminal.alternateScreenMode {
            if let alternateScreenMode {
                csi("?\(alternateScreenMode)h")
            } else if let mode = terminal.alternateScreenMode {
                csi("?\(mode)l")
            }
        }
        keyboardAndCursor(keyboardFlags, activeCursorStyle)
        if scrollRegion != terminal.scrollRegion {
            write([0x1B, UInt8(ascii: "[")] + (scrollRegion ?? []) + [UInt8(ascii: "r")])
        }
        for mode in Set(privateModes.keys).union(terminal.privateModes.keys).sorted() {
            if let on = modeValue(mode), on != terminal.modeValue(mode) {
                csi("?\(mode)\(on ? "h" : "l")")
            }
        }
        if mouseEventMode != terminal.mouseEventMode {
            if let mouseEventMode {
                csi("?\(mouseEventMode)h")
            } else if let mode = terminal.mouseEventMode {
                csi("?\(mode)l")
            }
        }
        if mouseFormatMode != terminal.mouseFormatMode {
            if let mouseFormatMode {
                csi("?\(mouseFormatMode)h")
            } else if let mode = terminal.mouseFormatMode {
                csi("?\(mode)l")
            }
        }
        if keypadApplicationMode != terminal.keypadApplicationMode {
            write([0x1B, UInt8(ascii: keypadApplicationMode ? "=" : ">")])
        }
        if modifyOtherKeys != terminal.modifyOtherKeys {
            csi(modifyOtherKeys == 0 ? ">4m" : ">4;\(modifyOtherKeys)m")
        }
        if characterSetG0 != terminal.characterSetG0 {
            write([0x1B, UInt8(ascii: "("), characterSetG0])
        }
        if characterSetG1 != terminal.characterSetG1 {
            write([0x1B, UInt8(ascii: ")"), characterSetG1])
        }
        if shiftedOut != terminal.shiftedOut {
            write([shiftedOut ? 0x0E : 0x0F])
        }
        if graphicRendition != terminal.graphicRendition {
            if !terminal.graphicRendition.isEmpty {
                csi("m")
            }
            for rendition in graphicRendition {
                write([0x1B, UInt8(ascii: "[")] + rendition + [UInt8(ascii: "m")])
            }
        }
        for index in Set(palette.keys).union(terminal.palette.keys).sorted() where palette[index] != terminal.palette[index] {
            if let spec = palette[index] {
                osc(Array("4;\(index);".utf8) + spec)
            } else {
                osc(Array("104;\(index)".utf8))
            }
        }
        for number in Set(dynamicColors.keys).union(terminal.dynamicColors.keys).sorted() where dynamicColors[number] != terminal.dynamicColors[number] {
            if let spec = dynamicColors[number] {
                osc(Array("\(number);".utf8) + spec)
            } else {
                osc(Array("\(number + 100)".utf8))
            }
        }
        return out
    }

    /// Bytes for the end of a program's time on the alternate screen, which started in the
    /// `entry` state (right after entering it with mode 1049): leave it the way the program
    /// did, then make the changes it left behind. Together with the entering sequence they
    /// stand in for everything the program wrote there, which no longer shows. `nil` when it
    /// left with RIS, which wiped the main screen too.
    func alternateScreenStandIn(since entry: TerminalModeTracker) -> Data? {
        guard alternateScreenMode == nil, let mode = lastScreenSwitchMode else { return nil }
        var out = Data()
        var terminal = entry.withoutEvents
        // DECSTBM moves the cursor home: set the scroll region while the main screen's cursor
        // is still put away.
        if scrollRegion != terminal.scrollRegion {
            let region = [0x1B, UInt8(ascii: "[")] + (scrollRegion ?? []) + [UInt8(ascii: "r")]
            out.append(contentsOf: region)
            terminal.consume(region)
        }
        let exit = Array("\u{1B}[?\(mode)l".utf8)
        out.append(contentsOf: exit)
        terminal.consume(exit)
        return out + changes(since: terminal)
    }

    private var activeCursorStyle: Int {
        alternateScreenMode == nil ? mainCursorStyle : alternateCursorStyle
    }

    /// A private mode's value, `nil` for a configured mode the output never set.
    private func modeValue(_ mode: Int) -> Bool? {
        privateModes[mode] ?? (Self.configuredModes.contains(mode) ? nil : Self.defaultOnModes.contains(mode))
    }
}
