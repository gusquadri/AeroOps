import Foundation

/// Takes kitty graphics commands that would make the terminal read local files or shared memory
/// out of a program's output, before libghostty or the history sees them.
///
/// The kitty graphics protocol (`ESC _ G <control> ; <payload> ESC \`) lets a program name
/// where the terminal reads an image from (`t=`): the payload itself (`d`, direct), a file
/// (`f`), a temporary file the terminal deletes after reading (`t`), or a POSIX shared memory
/// object the terminal unlinks after reading (`s`). In a standalone terminal the program runs
/// on the same Mac. Here it runs on a remote host, so the last three would let it make this Mac
/// read (and probe for, through the error replies) local files, delete temporary files and
/// unlink other apps' shared memory. Only direct transmission passes.
///
/// A blocked command is answered the way the terminal answers a failed one, so a program that
/// asked for a reply (`i=` or `I=`, unless `q=2`) falls back to direct transmission instead of
/// waiting. Its later chunks (`m=1` ... `m=0`) are dropped too.
///
/// Streaming: a command may be split across reads; its control data is held back (at most
/// ``maxControlBytes``) until it is known whether it passes.
struct KittyGraphicsFilter: Sendable {
    /// What one call returns.
    struct Result: Sendable {
        /// The output to hand on.
        var output: Data
        /// Answers for blocked commands, to write to the program's input.
        var replies: Data
    }

    /// Control data longer than this is not a real command; it is dropped.
    static let maxControlBytes = 512
    static let blockedMessage = "EPERM:only direct transmission is allowed"

    private enum State: Sendable {
        case ground
        /// After ESC.
        case escape
        /// After ESC _.
        case applicationCommand
        /// In a graphics command's control data, after ESC _ G.
        case control
        /// In a blocked command, up to its terminator.
        case dropping
        /// ESC inside a blocked command: `\` ends it, anything else starts a new sequence.
        case droppingEscape
    }

    private static let escape: UInt8 = 0x1B
    private static let cancel: UInt8 = 0x18
    private static let substitute: UInt8 = 0x1A

    private var state = State.ground
    private var control: [UInt8] = []
    /// A blocked command announced more chunks (`m=1`).
    private var droppingChunks = false

    mutating func filter(_ input: Data) -> Result {
        var output = Data()
        output.reserveCapacity(input.count + 3 + control.count)
        var replies = Data()
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                switch state {
                case .ground:
                    // Copy everything up to the next ESC in one go.
                    var end = index
                    while end < bytes.count, bytes[end] != Self.escape {
                        end += 1
                    }
                    output.append(UnsafeBufferPointer(rebasing: bytes[index..<end]))
                    index = end
                    if index < bytes.count {
                        state = .escape
                        index += 1
                    }
                    continue
                case .escape:
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "_") {
                        state = .applicationCommand
                    } else if byte == Self.escape {
                        output.append(Self.escape)
                    } else {
                        output.append(contentsOf: [Self.escape, byte])
                        state = .ground
                    }
                case .applicationCommand:
                    if bytes[index] == UInt8(ascii: "G") {
                        control.removeAll(keepingCapacity: true)
                        state = .control
                    } else {
                        // Some other APC: hand it on and look at this byte again.
                        output.append(contentsOf: [Self.escape, UInt8(ascii: "_")])
                        state = .ground
                        continue
                    }
                case .control:
                    let byte = bytes[index]
                    switch byte {
                    case UInt8(ascii: ";"), Self.escape:
                        let passes = decide(&replies)
                        if passes {
                            output.append(contentsOf: [Self.escape, UInt8(ascii: "_"), UInt8(ascii: "G")])
                            output.append(contentsOf: control)
                            if byte == Self.escape {
                                state = .escape
                            } else {
                                output.append(byte)
                                state = .ground
                            }
                        } else {
                            state = byte == Self.escape ? .droppingEscape : .dropping
                        }
                    case Self.cancel, Self.substitute:
                        // Aborted: there is nothing for the terminal to run.
                        output.append(byte)
                        state = .ground
                    default:
                        if control.count < Self.maxControlBytes {
                            control.append(byte)
                        } else {
                            state = .dropping
                        }
                    }
                case .dropping:
                    var end = index
                    while end < bytes.count, bytes[end] != Self.escape, bytes[end] != Self.cancel,
                          bytes[end] != Self.substitute {
                        end += 1
                    }
                    index = end
                    if index < bytes.count {
                        state = bytes[index] == Self.escape ? .droppingEscape : .ground
                        index += 1
                    }
                    continue
                case .droppingEscape:
                    if bytes[index] == UInt8(ascii: "\\") {
                        state = .ground
                    } else {
                        // The command ended without a terminator; this ESC starts a sequence.
                        state = .escape
                        continue
                    }
                }
                index += 1
            }
        }
        return Result(output: output, replies: replies)
    }

    /// Whether the command whose control data was just read passes; adds the answer for a
    /// blocked one to `replies`.
    private mutating func decide(_ replies: inout Data) -> Bool {
        let keys = Self.keys(control)
        if droppingChunks {
            // A later chunk of a blocked transmission.
            if keys[UInt8(ascii: "m")] != "1" {
                droppingChunks = false
            }
            return false
        }
        let medium = keys[UInt8(ascii: "t")] ?? "d"
        guard ["f", "t", "s"].contains(medium) else { return true }
        if keys[UInt8(ascii: "m")] == "1" {
            droppingChunks = true
        }
        replies.append(Self.reply(keys))
        return false
    }

    /// The error answer for a blocked command, empty when it asked for none. Only numbers are
    /// copied from the command into it.
    private static func reply(_ keys: [UInt8: String]) -> Data {
        guard keys[UInt8(ascii: "q")] != "2" else { return Data() }
        func number(_ key: Character) -> UInt32? {
            keys[key.asciiValue!].flatMap { UInt32($0) }.flatMap { $0 == 0 ? nil : $0 }
        }
        let id = number("i")
        let imageNumber = number("I")
        guard id != nil || imageNumber != nil else { return Data() }
        var fields: [String] = []
        if let id { fields.append("i=\(id)") }
        if let imageNumber { fields.append("I=\(imageNumber)") }
        if let placement = number("p") { fields.append("p=\(placement)") }
        return Data("\u{1B}_G\(fields.joined(separator: ","));\(blockedMessage)\u{1B}\\".utf8)
    }

    /// `k=v,k=v` control data: one-character keys, values as written.
    static func keys(_ control: [UInt8]) -> [UInt8: String] {
        var keys: [UInt8: String] = [:]
        for pair in control.split(separator: UInt8(ascii: ",")) {
            guard pair.count >= 2, pair[pair.startIndex + 1] == UInt8(ascii: "=") else { continue }
            keys[pair[pair.startIndex]] = String(decoding: pair.dropFirst(2), as: UTF8.self)
        }
        return keys
    }
}
