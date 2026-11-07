import Foundation

/// One meaningful line of an OpenSSH client config: a keyword and its arguments.
struct SSHConfigDirective: Sendable, Hashable {
    /// The keyword, lowercased (keywords are case-insensitive).
    var keyword: String
    /// The arguments after OpenSSH's quote and escape handling, with any trailing comment removed.
    var arguments: [String]
    /// Everything after the keyword and its separator, unprocessed. OpenSSH reads `ProxyCommand`
    /// and `ProxyJump` from this raw text rather than from the split arguments.
    var rawValue: String
}

/// Why a line could not be read. Carries the lowercased keyword when there is one.
enum SSHConfigLineError: Error, Sendable, Hashable {
    /// A keyword with nothing after it (or only a comment).
    case missingValue(keyword: String)
    /// A `"` or `'` that is never closed.
    case unterminatedQuote(keyword: String)
    /// A `"` inside the keyword itself.
    case malformedKeyword

    var keyword: String? {
        switch self {
        case .missingValue(let keyword), .unterminatedQuote(let keyword): keyword
        case .malformedKeyword: nil
        }
    }
}

/// Splits ssh_config lines the way OpenSSH's `readconf.c` does (`strdelim` for the keyword,
/// `argv_split` for the arguments).
///
/// - Leading and trailing whitespace is ignored; blank lines and lines starting with `#` are
///   skipped.
/// - The keyword ends at whitespace or `=`: `Port 22`, `Port=22` and `Port = 22` are the same.
/// - Arguments are split on spaces and tabs. `"…"` and `'…'` quote, and a backslash escapes a
///   quote, a backslash, or (outside quotes) a space.
/// - A `#` at the start of an argument ends the line; inside a word (`a#b`) it is kept.
enum SSHConfigLexer {
    /// Parses one line (without its `\n`). Returns `nil` for blank and comment lines.
    ///
    /// A NUL byte ends the line, as it does for OpenSSH's C strings; the caller reports it.
    static func directive(in line: some Sequence<Unicode.Scalar>) throws(SSHConfigLineError) -> SSHConfigDirective? {
        var scalars = Array(line)
        if let nul = scalars.firstIndex(of: "\0") {
            scalars.removeSubrange(nul...)
        }
        while let last = scalars.last, isWhitespace(last) || last == "\u{0C}" {
            scalars.removeLast()
        }
        var index = 0
        while index < scalars.count, isWhitespace(scalars[index]) { index += 1 }
        guard index < scalars.count, scalars[index] != "#" else { return nil }

        let keywordStart = index
        while index < scalars.count, !isWhitespace(scalars[index]), scalars[index] != "=", scalars[index] != "\"" {
            index += 1
        }
        if index < scalars.count, scalars[index] == "\"" { throw .malformedKeyword }
        let keyword = string(scalars[keywordStart..<index]).lowercased()

        if index < scalars.count, scalars[index] == "=" {
            index += 1
        } else {
            while index < scalars.count, isWhitespace(scalars[index]) { index += 1 }
            if index < scalars.count, scalars[index] == "=" { index += 1 }
        }
        while index < scalars.count, isWhitespace(scalars[index]) { index += 1 }

        let raw = scalars[index...]
        guard !raw.isEmpty else { throw .missingValue(keyword: keyword) }
        let arguments: [String]
        do {
            arguments = try split(raw)
        } catch {
            throw .unterminatedQuote(keyword: keyword)
        }
        guard !arguments.isEmpty else { throw .missingValue(keyword: keyword) }
        return SSHConfigDirective(keyword: keyword, arguments: arguments, rawValue: string(raw))
    }

    private struct UnterminatedQuote: Error {}

    /// OpenSSH's `argv_split(s, …, terminate_on_comment = 1)`.
    private static func split(_ text: ArraySlice<Unicode.Scalar>) throws(UnterminatedQuote) -> [String] {
        var arguments: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let scalar = text[index]
            if scalar == " " || scalar == "\t" {
                index += 1
                continue
            }
            if scalar == "#" { break }
            var quote: Unicode.Scalar?
            var argument = String.UnicodeScalarView()
            while index < text.endIndex {
                let scalar = text[index]
                if scalar == "\\" {
                    let next = index + 1 < text.endIndex ? text[index + 1] : nil
                    if let next, next == "'" || next == "\"" || next == "\\" || (quote == nil && next == " ") {
                        index += 1
                        argument.append(next)
                    } else {
                        argument.append(scalar)
                    }
                } else if quote == nil, scalar == " " || scalar == "\t" {
                    break
                } else if quote == nil, scalar == "\"" || scalar == "'" {
                    quote = scalar
                } else if let open = quote, scalar == open {
                    quote = nil
                } else {
                    argument.append(scalar)
                }
                index += 1
            }
            if quote != nil { throw UnterminatedQuote() }
            arguments.append(String(argument))
        }
        return arguments
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
