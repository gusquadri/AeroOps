import AeroTheme
import SwiftUI

/// The opaque, tinted inner well used for command text and config snippets.
struct Well: View {
    var tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
        shape.fill(Aero.glass.solidFill)
        shape.fill(tint.opacity(0.12))
        shape.strokeBorder(tint.opacity(0.45), lineWidth: 1)
    }
}

/// Makes text from agents and hosts safe to read: control, format (bidi overrides, zero-width
/// characters), separator and private-use characters become `⟨U+XXXX⟩`, so what is shown is
/// what runs. Newlines and tabs stay.
enum VisibleText {
    static func escape(_ text: String) -> (text: String, hadHidden: Bool) {
        var output = String.UnicodeScalarView()
        var hidden = false
        for scalar in text.unicodeScalars {
            if isHidden(scalar) {
                hidden = true
                output.append(contentsOf: "⟨U+\(String(scalar.value, radix: 16, uppercase: true).leftPadded(to: 4))⟩".unicodeScalars)
            } else {
                output.append(scalar)
            }
        }
        return (String(output), hidden)
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
            return true
        case .spaceSeparator:
            return scalar != " "
        default:
            // Combining marks on nothing visible and variation selectors can hide or alter text.
            return scalar.properties.isVariationSelector || scalar.properties.isDefaultIgnorableCodePoint
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
