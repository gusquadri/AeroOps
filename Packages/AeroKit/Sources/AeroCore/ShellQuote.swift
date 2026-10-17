/// POSIX shell quoting for every value interpolated into a remote command (AGENTS.md rule).
///
/// ```swift
/// let cmd = "docker logs --tail 500 " + ShellQuote.quote(containerName)
/// ```
public enum ShellQuote {
    /// Wraps `value` in single quotes so a POSIX `sh` reads it back as exactly one literal word.
    ///
    /// Inside single quotes nothing is special except `'` itself, which is written as `'\''`
    /// (close quote, escaped quote, reopen). The result is always quoted, even for safe or empty
    /// input (`''`), so callers never need to decide. Note that a NUL byte cannot be represented
    /// in a shell word at all; callers should reject such input before quoting.
    public static func quote(_ value: String) -> String {
        "'" + value.replacing("'", with: #"'\''"#) + "'"
    }

    /// Quotes each value and joins them with single spaces.
    public static func join(_ values: [String]) -> String {
        values.map(quote).joined(separator: " ")
    }

    /// `true` when `name` is a safe container, pod, namespace or container name: one or more of
    /// `[A-Za-z0-9_.-]` (ASCII only) and not starting with `-`.
    ///
    /// This is the plan's `^[A-Za-z0-9_.-]+$`, tightened to reject a leading `-` so a name can
    /// never be read as a command-line option (Docker and Kubernetes names start with an
    /// alphanumeric anyway). Names must pass this check *and* go through ``quote(_:)``.
    public static func isSafeName(_ name: String) -> Bool {
        guard let first = name.utf8.first, first != UInt8(ascii: "-") else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}
