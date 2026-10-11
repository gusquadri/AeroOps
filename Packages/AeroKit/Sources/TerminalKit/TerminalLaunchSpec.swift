import Foundation

/// What a terminal tab runs: one local executable with its arguments.
///
/// TerminalKit knows nothing about SSH. The app builds the spec, for example
/// `/usr/bin/ssh -F ~/.aeroops/ssh_config aero-<id>` with `SSH_AUTH_SOCK` pointing at the
/// in-app agent, and TerminalKit runs it in a libghostty surface.
public struct TerminalLaunchSpec: Sendable, Hashable {
    /// Absolute path of the program to run, e.g. `/usr/bin/ssh`.
    public var executable: String
    /// Arguments after the executable. Each one reaches the program as exactly one argv entry.
    public var arguments: [String]
    /// Variables added to (or overriding) the inherited environment, e.g. `SSH_AUTH_SOCK`.
    public var environment: [String: String]
    /// Directory the program starts in; `nil` keeps libghostty's default (the user's home).
    public var workingDirectory: String?
    /// Initial tab title until the program sets one (OSC 0/2).
    public var title: String

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        title: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.title = title
    }
}

/// Why a ``TerminalLaunchSpec`` cannot be launched.
public enum TerminalLaunchError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The executable is not an absolute path.
    case relativeExecutable(String)
    /// A value contains a NUL, newline or other control character. libghostty reads the
    /// command from a line-based config file and argv cannot carry NUL, so such values are
    /// rejected instead of being mangled.
    case controlCharacter(field: String)
    /// An environment variable name is not a portable shell name (`[A-Za-z_][A-Za-z0-9_]*`).
    case invalidEnvironmentName(String)

    public var description: String {
        switch self {
        case let .relativeExecutable(path):
            "executable must be an absolute path: \(path)"
        case let .controlCharacter(field):
            "\(field) contains a control character"
        case let .invalidEnvironmentName(name):
            "invalid environment variable name: \(name)"
        }
    }
}

extension TerminalLaunchSpec {
    /// Throws when the spec cannot be passed safely to libghostty.
    public func validate() throws(TerminalLaunchError) {
        guard executable.hasPrefix("/") else { throw .relativeExecutable(executable) }
        if Self.hasControlCharacter(executable) { throw .controlCharacter(field: "executable") }
        for (index, argument) in arguments.enumerated() where Self.hasControlCharacter(argument) {
            throw .controlCharacter(field: "argument \(index)")
        }
        for (name, value) in environment {
            guard Self.isPortableName(name) else { throw .invalidEnvironmentName(name) }
            if Self.hasControlCharacter(value) { throw .controlCharacter(field: "environment \(name)") }
        }
        if let workingDirectory, Self.hasControlCharacter(workingDirectory) {
            throw .controlCharacter(field: "workingDirectory")
        }
    }

    static func hasControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    static func isPortableName(_ name: String) -> Bool {
        guard let first = name.utf8.first, !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
            return false
        }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"):
                true
            default:
                false
            }
        }
    }
}
