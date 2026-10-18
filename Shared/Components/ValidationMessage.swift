import AeroTheme
import SwiftUI

/// An inline validation or error message: coral warning icon and readable text.
struct ValidationMessage: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Aero.coral)
        }
        .font(Aero.font(.caption))
        .foregroundStyle(Aero.text.secondary)
    }
}
